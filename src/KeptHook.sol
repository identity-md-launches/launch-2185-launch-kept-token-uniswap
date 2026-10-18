// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SpecifiedAmount} from "./libraries/SpecifiedAmount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IRefereeFund {
    function fundReferee(uint256 amount) external;
}

/// @notice Immutable IMD fee hook for the single KEPT/IMD launch pool. Every fee it collects goes to
/// the KEPT Referee Fund, which pays back the oracle check of every milestone a team keeps.
/// @dev Fee math is the accepted imdDRONE hook's (launch 909) with the fee rounded up:
/// ceil(gross IMD * feeNow / 10_000), charged on the IMD leg only, accrued as PoolManager ERC-6909
/// claims so swaps never need IMD on hand. Only the fee schedule and the sweep destination differ.
contract KeptHook is IUnlockCallback {
    /// @notice The steady fee on gross IMD, in basis points: 1%.
    uint256 public constant REFEREE_FEE = 100;
    /// @notice The opening fee, decaying linearly to `REFEREE_FEE` over `OPENING_SECONDS`.
    uint256 public constant OPENING_FEE = 2000;
    uint256 public constant OPENING_SECONDS = 1800;
    uint24 public constant LP_FEE = 12500;
    int24 public constant TICK_SPACING = 60;
    uint256 private constant BPS = 10_000;

    IPoolManager public immutable poolManager;
    Currency public immutable imd;
    address public immutable token;
    /// @notice The KeptVault whose Referee Fund receives every fee.
    address public immutable vault;
    /// @notice The IMD launch factory: the only account allowed to initialize the pool.
    address public immutable factory;
    /// @notice When trading opened: the first swap that moved IMD through the pool. Zero until then,
    /// so the opening window cannot elapse before the pool holds liquidity anyone can trade against;
    /// a swap the pool filled nothing of (an empty pool, or 1 wei whose whole amount is fee) is
    /// charged but does not open it.
    uint256 public openedAt;
    uint256 public collected;
    bool public initialized;
    bool private sweeping;

    error OnlyPoolManager();
    error InvalidConfiguration();
    error InvalidPool();
    error AlreadyInitialized();
    error UnexpectedUnlock();

    event Initialized();
    event Opened(uint256 timestamp);
    event FeeAccrued(uint256 amount);
    event Swept(uint256 amount);

    constructor(IPoolManager manager_, address imd_, address token_, address vault_, address factory_) {
        if (
            address(manager_) == address(0) || imd_ == address(0) || token_ == address(0)
                || vault_ == address(0) || factory_ == address(0) || imd_ == token_
        ) revert InvalidConfiguration();
        factory = factory_;
        poolManager = manager_;
        imd = Currency.wrap(imd_);
        token = token_;
        vault = vault_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (initialized) revert AlreadyInitialized();
        if (sender != factory) revert InvalidPool();
        address a = Currency.unwrap(key.currency0);
        address b = Currency.unwrap(key.currency1);
        address pair = Currency.unwrap(imd);
        if (
            !((a == pair && b == token) || (a == token && b == pair)) || key.fee != LP_FEE
                || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
        ) revert InvalidPool();
        initialized = true;
        emit Initialized();
        return IHooks.beforeInitialize.selector;
    }

    /// @notice The fee in basis points of gross IMD: `OPENING_FEE` until the first swap that moves
    /// IMD, then decaying linearly to `REFEREE_FEE` over `OPENING_SECONDS` from that swap.
    function feeNow() public view returns (uint256) {
        if (openedAt == 0 || block.timestamp <= openedAt) return OPENING_FEE;
        uint256 elapsed = block.timestamp - openedAt;
        if (elapsed >= OPENING_SECONDS) return REFEREE_FEE;
        return REFEREE_FEE + (OPENING_FEE - REFEREE_FEE) * (OPENING_SECONDS - elapsed) / OPENING_SECONDS;
    }

    /// @dev ceil(amount * numerator / denominator); the fee never rounds in the swapper's favour.
    function _feeOf(uint256 amount, uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return (amount * numerator + denominator - 1) / denominator;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactIn = params.amountSpecified < 0;
        bool imd0 = key.currency0 == imd;
        if ((exactIn == params.zeroForOne) != imd0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }
        uint256 rate = feeNow();
        uint256 requested;
        unchecked {
            requested = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        }
        uint256 budget =
            requested > uint256(uint128(type(int128).max)) ? uint256(uint128(type(int128).max)) : requested;
        uint256 reserve = exactIn ? _feeOf(budget, rate, BPS) : _feeOf(budget, rate, BPS - rate);
        SwapParams memory quote = params;
        quote.amountSpecified = exactIn ? -int256(budget - reserve) : int256(budget + reserve);
        uint256 fill = SpecifiedAmount.filled(poolManager, key, quote);
        uint256 fee;
        if (exactIn) {
            fee = requested == budget && fill == budget - reserve ? reserve : _feeOf(fill, rate, BPS - rate);
        } else {
            fee = _feeOf(fill, rate, BPS);
        }
        // A request so small that the fee is all of it (1 wei exact-in) fills nothing: the fee is
        // still owed, but a swap that moves no IMD through the pool does not open the window.
        _accrue(fee, fill != 0);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        bool imd0 = key.currency0 == imd;
        if (((params.amountSpecified < 0) == params.zeroForOne) == imd0) {
            return (IHooks.afterSwap.selector, 0);
        }
        int256 amount = imd0 ? int256(delta.amount0()) : int256(delta.amount1());
        uint256 rate = feeNow();
        uint256 fee =
            amount < 0 ? _feeOf(uint256(-amount), rate, BPS - rate) : _feeOf(uint256(amount), rate, BPS);
        _accrue(fee, amount != 0);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    /// @dev Books `fee` as an IMD claim. Only a swap that moved IMD through the pool (`moved`) opens
    /// the window: a charged swap the pool filled nothing of, as on an empty pool, never does.
    function _accrue(uint256 fee, bool moved) private {
        if (fee == 0) return;
        if (moved && openedAt == 0) {
            openedAt = block.timestamp;
            emit Opened(block.timestamp);
        }
        collected += fee;
        poolManager.mint(address(this), imd.toId(), fee);
        emit FeeAccrued(fee);
    }

    /// @notice Fee claims plus any IMD sent to this contract directly.
    function pending() external view returns (uint256) {
        return poolManager.balanceOf(address(this), imd.toId()) + imd.balanceOfSelf();
    }

    /// @notice Permissionless: redeems every fee claim and deposits the IMD into the Referee Fund.
    /// Calls made during an unlock or a sweep do nothing; retry after settlement.
    function sweep() external returns (uint256 amount) {
        if (sweeping || TransientStateLibrary.isUnlocked(poolManager)) return 0;
        sweeping = true;
        poolManager.unlock("");
        sweeping = false;
        amount = imd.balanceOfSelf();
        if (amount != 0) {
            address target = vault;
            SafeERC20.forceApprove(IERC20(Currency.unwrap(imd)), target, amount);
            IRefereeFund(target).fundReferee(amount);
        }
        emit Swept(amount);
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        if (!sweeping) revert UnexpectedUnlock();
        uint256 amount = poolManager.balanceOf(address(this), imd.toId());
        if (amount != 0) {
            poolManager.burn(address(this), imd.toId(), amount);
            poolManager.take(imd, address(this), amount);
        }
        return abi.encode(amount);
    }
}

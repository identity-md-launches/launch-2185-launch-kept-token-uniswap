// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {KeptToken} from "../../src/KeptToken.sol";
import {KeptHook} from "../../src/KeptHook.sol";
import {KeptVault} from "../../src/KeptVault.sol";
import {HookFlags} from "../../src/libraries/HookFlags.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockIntake} from "../mocks/MockIntake.sol";
import {TestRouter} from "./TestRouter.sol";

/// @dev Ported from the imdDRONE (launch 909) hook fixture: a real local PoolManager, the hook at a
/// permission-flagged address, and a router that settles exactly what the manager reports.
abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal manager;
    KeptToken internal kept;
    MockERC20 internal imd;
    KeptHook internal hook;
    KeptVault internal vault;
    TestRouter internal router;
    PoolKey internal key;
    uint160 internal constant ONE = 79228162514264337593543950336;
    uint256 internal constant OPEN = 10_000;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    /// @dev `openedAt` before the swap under check (storage keeps `_checkedSwap` within stack limits).
    uint256 private _openedBefore;

    function _imdFirst() internal pure virtual returns (bool) {
        return true;
    }

    function setUp() public virtual {
        vm.warp(OPEN);
        manager = IPoolManager(address(new PoolManager(address(this))));
        kept = new KeptToken();
        MockERC20 template = new MockERC20("IMD", "IMD", 0);
        address imdAt = _imdFirst() ? address(0x1000) : address(type(uint160).max - 1);
        vm.etch(imdAt, address(template).code);
        imd = MockERC20(imdAt);
        imd.mint(address(this), 1e30);
        MockIntake intake = new MockIntake(address(0x7EA));
        vault = new KeptVault(
            address(this),
            address(intake),
            address(imd),
            bytes32("oracle.request@oracle-1"),
            address(0x5157),
            9,
            7
        );
        _setupHook();
        router.seed(key, -600, 600, 1e27);
    }

    function _hookAddress() internal pure returns (address) {
        return address(uint160(0x4b4550540000000000000000000000000000) << 14 | HookFlags.KEPT);
    }

    function _setupHook() internal {
        deployCodeTo(
            "KeptHook.sol:KeptHook",
            abi.encode(manager, address(imd), address(kept), address(vault), address(this)),
            _hookAddress()
        );
        hook = KeptHook(_hookAddress());
        bool imd0 = address(imd) < address(kept);
        key = PoolKey(
            Currency.wrap(imd0 ? address(imd) : address(kept)),
            Currency.wrap(imd0 ? address(kept) : address(imd)),
            12500,
            60,
            IHooks(address(hook))
        );
        manager.initialize(key, ONE);
        router = new TestRouter(manager);
        imd.approve(address(router), type(uint256).max);
        kept.approve(address(router), type(uint256).max);
    }

    /// @dev ceil(gross * rate / 10_000): the fee the hook owes on a gross IMD amount.
    function _ceilFee(uint256 gross, uint256 rate) internal pure returns (uint256) {
        return (gross * rate + 9_999) / 10_000;
    }

    /// @dev Opens the window at OPEN with the first fee-bearing swap, as the launch's first trade does.
    function _open() internal returns (uint256 charged) {
        vm.warp(OPEN);
        assertEq(hook.openedAt(), 0, "clock not started");
        charged = _checkedSwap(true, true, 1e18, false);
        assertEq(hook.openedAt(), OPEN, "clock starts at the first swap");
    }

    function _params(bool buy, bool exactIn, uint256 amount, bool limited)
        internal
        view
        returns (SwapParams memory p)
    {
        p.zeroForOne = buy == (key.currency0 == Currency.wrap(address(imd)));
        p.amountSpecified = exactIn ? -int256(amount) : int256(amount);
        if (limited) {
            (, int24 current,,) = manager.getSlot0(key.toId());
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(current + (p.zeroForOne ? int24(-1) : int24(2)));
        } else {
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(p.zeroForOne ? int24(-1200) : int24(1200));
        }
    }

    function _checkedSwap(bool buy, bool exactIn, uint256 amount, bool limited)
        internal
        returns (uint256 charged)
    {
        SwapParams memory p = _params(buy, exactIn, amount, limited);
        uint256 beforeCollected = hook.collected();
        uint256 beforePending = hook.pending();
        uint256 beforeIMD = imd.balanceOf(address(this));
        uint256 beforeKept = kept.balanceOf(address(this));
        _openedBefore = hook.openedAt();
        vm.recordLogs();
        BalanceDelta result = router.swap(key, p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (int128 raw0, int128 raw1) = _rawSwap(logs);
        bool imd0 = key.currency0 == Currency.wrap(address(imd));
        int256 rawIMD = imd0 ? int256(raw0) : int256(raw1);
        int256 rawKept = imd0 ? int256(raw1) : int256(raw0);
        int256 netIMD = imd0 ? int256(result.amount0()) : int256(result.amount1());
        int256 netKept = imd0 ? int256(result.amount1()) : int256(result.amount0());
        charged = hook.collected() - beforeCollected;
        assertEq(netKept, rawKept, "KEPT is never charged");
        assertEq(netIMD, rawIMD - int256(charged), "only the IMD delta changes");
        uint256 gross = buy ? uint256(-netIMD) : uint256(rawIMD);
        assertEq(charged, _ceilFee(gross, hook.feeNow()), "exact scheduled fee on actual gross IMD");
        assertLe(charged, gross, "fee never exceeds the IMD leg");
        if (gross != 0) assertGt(charged, 0, "any IMD leg pays at least one wei");
        assertEq(hook.pending(), beforePending + charged, "claim conservation");
        assertEq(int256(imd.balanceOf(address(this))) - int256(beforeIMD), netIMD);
        assertEq(int256(kept.balanceOf(address(this))) - int256(beforeKept), netKept);
        assertLe(charged, _ceilFee(gross, hook.OPENING_FEE()));
        _assertClock(rawIMD);
        if (exactIn) assertLe(uint256(-(buy ? netIMD : netKept)), amount);
        else assertLe(uint256(buy ? netKept : netIMD), amount);
        if (!limited && amount <= 1e22) {
            if (exactIn) assertEq(uint256(-(buy ? netIMD : netKept)), amount, "full exact input");
            else assertEq(uint256(buy ? netKept : netIMD), amount, "full exact output");
        }
        (,,, uint24 lp) = manager.getSlot0(key.toId());
        assertEq(lp, 12500, "static LP fee unchanged");
    }

    /// @dev Only a swap the pool filled (nonzero IMD in the manager's Swap event) starts the clock.
    function _assertClock(int256 rawIMD) private view {
        if (rawIMD != 0) {
            assertGt(hook.openedAt(), 0, "a swap that moves IMD through the pool starts the clock");
        } else {
            assertEq(hook.openedAt(), _openedBefore, "a swap the pool fills nothing of never starts it");
        }
    }

    function _rawSwap(Vm.Log[] memory logs) internal view returns (int128 a, int128 b) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                uint24 fee;
                (a, b,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(fee, 12500, "manager's swap used the static LP fee");
                return (a, b);
            }
        }
        revert("missing swap event");
    }
}

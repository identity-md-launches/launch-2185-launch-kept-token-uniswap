// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {KeptHook} from "../src/KeptHook.sol";
import {KeptToken} from "../src/KeptToken.sol";
import {KeptVault} from "../src/KeptVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Drives the KEPT/IMD pool with several traders, liquidity changes, donations, sweeps and time.
/// Assertions that would revert inside a handler are swallowed by `fail_on_revert = false`, so every
/// per-call property is recorded in a ghost counter and checked by an invariant instead.
contract KeptHookHandler is Test {
    using StateLibrary for IPoolManager;

    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    IPoolManager public immutable manager;
    KeptHook public immutable hook;
    KeptToken public immutable kept;
    MockERC20 public immutable imd;
    KeptVault public immutable vault;
    TestRouter public immutable router;
    PoolKey internal key;
    bool internal immutable imd0;

    address[3] public actors;

    uint256 public ghostCharged;
    uint256 public ghostDonated;
    uint256 public ghostSwept;
    uint256 public ghostOpenedAt;
    uint256 public ghostLastFee;
    uint256 public swaps;
    uint256 public chargedSwaps;
    uint256 public movedSwaps;
    uint256 public dustCharged;
    uint256 public sweeps;
    uint256 public deferredSweeps;
    // Per-call property violations; every one must stay zero.
    uint256 public feeMismatches;
    uint256 public keptCharged;
    uint256 public feeAboveLeg;
    uint256 public sweepMismatches;
    uint256 public clockRestarts;
    uint256 public feeIncreases;
    uint256 public deferViolations;
    int256 public wideLiquidity;
    int256 public narrowLiquidity;

    constructor(
        IPoolManager manager_,
        KeptHook hook_,
        KeptToken kept_,
        MockERC20 imd_,
        KeptVault vault_,
        TestRouter router_,
        PoolKey memory key_
    ) {
        manager = manager_;
        hook = hook_;
        kept = kept_;
        imd = imd_;
        vault = vault_;
        router = router_;
        key = key_;
        imd0 = key_.currency0 == Currency.wrap(address(imd_));
        actors = [makeAddr("trader a"), makeAddr("trader b"), makeAddr("trader c")];
        imd.approve(address(router), type(uint256).max);
        kept.approve(address(router), type(uint256).max);
        ghostLastFee = hook_.feeNow();
    }

    function setUpActors() external {
        imd.mint(address(this), 1e28);
        for (uint256 i; i < actors.length; ++i) {
            imd.mint(actors[i], 1e27);
            vm.startPrank(actors[i]);
            imd.approve(address(router), type(uint256).max);
            kept.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function swap(uint256 actorSeed, bool buy, bool exactIn, uint256 amount, bool limited) external {
        _swap(actorSeed, buy, exactIn, bound(amount, 1, 5e24), limited);
    }

    /// @dev A 1-wei exact-input trade: on the IMD side the whole wei is fee and the pool fills
    /// nothing, so it is charged but must not open the window.
    function dustSwap(uint256 actorSeed, bool buy, bool limited) external {
        _swap(actorSeed, buy, true, 1, limited);
    }

    function _swap(uint256 actorSeed, bool buy, bool exactIn, uint256 amount, bool limited) internal {
        address actor = actors[actorSeed % actors.length];
        SwapParams memory p;
        p.zeroForOne = buy == imd0;
        p.amountSpecified = exactIn ? -int256(amount) : int256(amount);
        (, int24 current,,) = manager.getSlot0(key.toId());
        if (limited) {
            p.sqrtPriceLimitX96 =
                TickMath.getSqrtPriceAtTick(current + (p.zeroForOne ? int24(-30) : int24(30)));
        } else {
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(p.zeroForOne ? int24(-1800) : int24(1800));
        }
        // Sells need KEPT on hand; the handler hands out what a sell could need from its own stock.
        if (!buy) {
            uint256 want = exactIn ? amount : amount * 2;
            uint256 have = kept.balanceOf(actor);
            uint256 stock = kept.balanceOf(address(this));
            if (have < want && stock > 0) kept.transfer(actor, want - have > stock ? stock : want - have);
        }

        uint256 rate = hook.feeNow();
        uint256 collectedBefore = hook.collected();
        vm.recordLogs();
        vm.prank(actor);
        try router.swap(key, p) returns (BalanceDelta result) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            (bool found, int128 raw0, int128 raw1) = _rawSwap(logs);
            if (!found) return;
            ++swaps;
            int256 rawIMD = imd0 ? int256(raw0) : int256(raw1);
            int256 rawKept = imd0 ? int256(raw1) : int256(raw0);
            int256 netIMD = imd0 ? int256(result.amount0()) : int256(result.amount1());
            int256 netKept = imd0 ? int256(result.amount1()) : int256(result.amount0());
            uint256 charged = hook.collected() - collectedBefore;
            if (netKept != rawKept) ++keptCharged;
            if (netIMD != rawIMD - int256(charged)) ++feeMismatches;
            uint256 gross = buy ? uint256(-netIMD) : (rawIMD > 0 ? uint256(rawIMD) : 0);
            if (charged != (gross * rate + 9_999) / 10_000) ++feeMismatches;
            if (charged > gross) ++feeAboveLeg;
            if (charged != 0) {
                ++chargedSwaps;
                ghostCharged += charged;
                if (rawIMD == 0) ++dustCharged;
            }
            // Only a swap that moved IMD through the pool opens the window.
            if (rawIMD != 0) {
                ++movedSwaps;
                if (ghostOpenedAt == 0) ghostOpenedAt = block.timestamp;
            }
        } catch {
            vm.getRecordedLogs();
        }
        _trackClock();
    }

    function sweep(uint256 actorSeed) external {
        uint256 fundBefore = vault.refereeFund();
        uint256 vaultIMD = imd.balanceOf(address(vault));
        uint256 expected = hook.pending();
        vm.prank(actors[actorSeed % actors.length]);
        uint256 swept = hook.sweep();
        ++sweeps;
        ghostSwept += swept;
        if (swept != expected) ++sweepMismatches;
        if (vault.refereeFund() - fundBefore != swept) ++sweepMismatches;
        if (imd.balanceOf(address(vault)) - vaultIMD != swept) ++sweepMismatches;
        if (hook.pending() != 0) ++sweepMismatches;
        _trackClock();
    }

    function sweepDuringUnlock() external {
        uint256 pendingBefore = hook.pending();
        try router.sweepDuringUnlock(key) {
            ++deferredSweeps;
            if (hook.pending() != pendingBefore) ++deferViolations;
        } catch {
            ++deferViolations;
        }
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1e22);
        imd.transfer(address(hook), amount);
        ghostDonated += amount;
    }

    function wait(uint256 secondsAhead) external {
        vm.warp(block.timestamp + bound(secondsAhead, 0, 900));
        _trackClock();
    }

    function liquidity(bool wide, bool add, uint256 amount) external {
        int24 range = wide ? int24(1200) : int24(120);
        int256 current = wide ? wideLiquidity : narrowLiquidity;
        int256 change;
        if (add) {
            change = int256(bound(amount, 1e18, 1e25));
        } else {
            if (current == 0) return;
            change = -int256(bound(amount, 1, uint256(current)));
        }
        // The handler funds its own positions; it may run short of KEPT after removing liquidity.
        try router.seed(key, -range, range, change) {
            if (wide) wideLiquidity += change;
            else narrowLiquidity += change;
        } catch {}
    }

    function _trackClock() internal {
        uint256 openedAt = hook.openedAt();
        if (ghostOpenedAt != 0 && openedAt != ghostOpenedAt) ++clockRestarts;
        uint256 fee = hook.feeNow();
        if (fee > ghostLastFee) ++feeIncreases;
        ghostLastFee = fee;
    }

    function _rawSwap(Vm.Log[] memory logs) internal view returns (bool found, int128 a, int128 b) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                (a, b) = abi.decode(logs[i].data, (int128, int128));
                return (true, a, b);
            }
        }
    }
}

/// @notice The hook holds value (ERC-6909 IMD claims and donated IMD) and owes all of it to the
/// Referee Fund. Over random sequences of trades, liquidity changes, donations, sweeps and time:
/// what it holds equals what it charged plus what it was sent minus what it swept; every swept wei
/// reaches the Referee Fund; KEPT is never charged; the clock opens once and the fee never rises.
contract KeptHookInvariantTest is HookFixture {
    using StateLibrary for IPoolManager;

    KeptHookHandler internal handler;

    function setUp() public virtual override {
        super.setUp();
        handler = new KeptHookHandler(manager, hook, kept, imd, vault, router, key);
        handler.setUpActors();
        // Stock for sells and for the handler's own positions: half of what the fixture holds.
        kept.transfer(address(handler), kept.balanceOf(address(this)) / 2);
        imd.transfer(address(handler), 1e27);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = KeptHookHandler.swap.selector;
        selectors[1] = KeptHookHandler.swap.selector;
        selectors[2] = KeptHookHandler.swap.selector;
        selectors[3] = KeptHookHandler.sweep.selector;
        selectors[4] = KeptHookHandler.sweepDuringUnlock.selector;
        selectors[5] = KeptHookHandler.donate.selector;
        selectors[6] = KeptHookHandler.wait.selector;
        selectors[7] = KeptHookHandler.liquidity.selector;
        selectors[8] = KeptHookHandler.dustSwap.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_holdingsEqualChargedPlusDonatedMinusSwept() public view {
        assertEq(hook.collected(), handler.ghostCharged(), "collected is the sum of charged fees");
        assertEq(
            hook.pending(),
            handler.ghostCharged() + handler.ghostDonated() - handler.ghostSwept(),
            "the hook holds exactly what it is owed to the Referee Fund"
        );
        assertEq(
            manager.balanceOf(address(hook), hook.imd().toId()) + imd.balanceOf(address(hook)), hook.pending()
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_everySweptWeiReachesTheRefereeFund() public view {
        assertEq(vault.refereeFund(), handler.ghostSwept(), "Referee Fund is the sum of sweeps");
        assertGe(imd.balanceOf(address(vault)), vault.refereeFund(), "vault holds the fund it reports");
        assertEq(handler.sweepMismatches(), 0, "a sweep moved a different amount than pending");
        assertEq(handler.deferViolations(), 0, "a sweep inside an unlock moved claims");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_feeIsExactAndOnlyOnIMD() public view {
        assertEq(handler.feeMismatches(), 0, "fee differs from ceil(gross IMD * feeNow / 10_000)");
        assertEq(handler.keptCharged(), 0, "a KEPT leg was charged");
        assertEq(handler.feeAboveLeg(), 0, "a fee exceeded its IMD leg");
        assertEq(kept.balanceOf(address(hook)), 0, "hook never holds KEPT");
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(kept)).toId()), 0, "no KEPT claims");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_clockOpensOnceAndFeeNeverRises() public view {
        assertEq(handler.clockRestarts(), 0, "openedAt changed after it was set");
        assertEq(handler.feeIncreases(), 0, "feeNow rose over time");
        assertEq(hook.openedAt(), handler.ghostOpenedAt(), "the clock opened at the first swap that moved IMD");
        assertEq(hook.openedAt() == 0, handler.movedSwaps() == 0, "open iff a swap ever moved IMD");
        if (hook.openedAt() == 0) assertEq(hook.feeNow(), hook.OPENING_FEE(), "closed window charges 20%");
        uint256 fee = hook.feeNow();
        assertGe(fee, hook.REFEREE_FEE());
        assertLe(fee, hook.OPENING_FEE());
        assertTrue(hook.initialized(), "the single pool stays initialized");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyFixedAndManagerSolvent() public view {
        uint256 sum = kept.balanceOf(address(this)) + kept.balanceOf(address(handler))
            + kept.balanceOf(address(manager)) + kept.balanceOf(address(router))
            + kept.balanceOf(address(hook));
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += kept.balanceOf(handler.actors(i));
        }
        assertEq(kept.totalSupply(), 1e27, "fixed supply");
        assertEq(sum, 1e27, "every KEPT is accounted for");
        assertGe(
            imd.balanceOf(address(manager)),
            manager.balanceOf(address(hook), hook.imd().toId()),
            "the manager holds the IMD behind the hook's claims"
        );
    }

    /// @dev The dust path the clock invariant depends on is reachable from the handler: a 1-wei buy is
    /// charged its whole wei, moves nothing, and leaves the window closed until a filled trade.
    function test_handlerDustBuyIsChargedWithoutOpening() public {
        vm.warp(OPEN + 50);
        handler.dustSwap(0, true, false);
        assertEq(handler.dustCharged(), 1, "the wei was charged");
        assertEq(handler.movedSwaps(), 0);
        assertEq(hook.collected(), 1);
        assertEq(hook.openedAt(), 0, "window stays closed");
        handler.swap(1, true, true, 1_000e18, false);
        assertEq(handler.movedSwaps(), 1);
        assertEq(hook.openedAt(), OPEN + 50, "the first filled trade opens it");
        assertEq(handler.feeMismatches(), 0);
        assertEq(handler.clockRestarts(), 0);
    }

    /// @dev Guards against a vacuous run: the sequences must actually trade and be charged.
    function afterInvariant() public view {
        assertGt(handler.swaps(), 0, "no swap succeeded");
        assertGt(handler.chargedSwaps(), 0, "no swap was charged");
    }
}

contract KeptHookTokenFirstInvariantTest is KeptHookInvariantTest {
    function _imdFirst() internal pure override returns (bool) {
        return false;
    }
}

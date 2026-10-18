// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";
import {KeptHook} from "../src/KeptHook.sol";
import {KeptToken} from "../src/KeptToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract KeptHookTest is HookFixture {
    function test_feeSchedule() public {
        assertTrue(hook.initialized());
        assertEq(hook.openedAt(), 0, "initialization does not start the clock");
        vm.warp(OPEN + 86400);
        assertEq(hook.feeNow(), 2000, "opening fee holds until the first trade");
        _open();
        for (uint256 t; t <= 1800; t += 7) {
            vm.warp(OPEN + t);
            assertEq(hook.feeNow(), 100 + (1900 * (1800 - t)) / 1800);
        }
        vm.warp(OPEN + 1800);
        assertEq(hook.feeNow(), 100);
        vm.warp(type(uint64).max);
        assertEq(hook.feeNow(), 100);
    }

    /// @dev Audit 79f4aafb: the anti-snipe window is timed from the first swap that moves IMD, not from
    /// pool initialization, so a pool seeded after initialization still opens at 20%.
    function test_openingClockStartsAtFirstSwapNotInitialize() public {
        vm.warp(OPEN + 1800);
        assertEq(hook.openedAt(), 0);
        assertEq(hook.feeNow(), 2000);
        vm.expectEmit(true, true, true, true, address(hook));
        emit KeptHook.Opened(OPEN + 1800);
        uint256 charged = _checkedSwap(true, true, 100e18, false);
        assertEq(charged, 20e18, "first trade pays the opening fee however late it comes");
        assertEq(hook.openedAt(), OPEN + 1800);
        vm.warp(OPEN + 1800 + 900);
        assertEq(hook.feeNow(), 1050);
        _checkedSwap(false, true, 100e18, false);
        assertEq(hook.openedAt(), OPEN + 1800, "later trades do not restart the clock");
        vm.warp(OPEN + 1800 + 1800);
        assertEq(hook.feeNow(), 100);
        assertEq(_checkedSwap(true, true, 100e18, false), 1e18);
    }

    function test_openingClockNeedsAnIMDLeg() public {
        router.seed(key, -600, 600, -1e27);
        vm.warp(OPEN + 5);
        router.swap(key, _params(true, true, 1e18, false));
        assertEq(hook.collected(), 0);
        assertEq(hook.openedAt(), 0, "a swap that moves no IMD does not open the window");
        router.seed(key, -600, 600, 1e27);
        vm.warp(OPEN + 7200);
        assertEq(hook.feeNow(), 2000);
        // The empty-pool swap slid the price to the buy limit, so the first real trade is a sell.
        assertGt(_checkedSwap(false, true, 100e18, false), 0);
        assertEq(hook.openedAt(), OPEN + 7200);
    }

    function test_allModesAtOpeningMidpointAndAfter() public {
        uint256[5] memory times = [uint256(0), 1, 900, 1800, 86400];
        for (uint256 t; t < times.length; ++t) {
            vm.warp(OPEN + times[t]);
            _checkedSwap(true, true, 1e18, false);
            _checkedSwap(true, false, 1e18, false);
            _checkedSwap(false, true, 1e18, false);
            _checkedSwap(false, false, 1e18, false);
            assertEq(hook.openedAt(), OPEN);
        }
    }

    /// @dev Audit d96e756a: the fee rounds up, so an IMD leg below 10_000 / rate wei still pays one wei.
    /// Exact amounts are asserted where IMD is the specified side; the fixture checks the ceiling
    /// formula on the pool's own IMD leg for the other two modes.
    function test_dustSwapsRoundTheFeeUp() public {
        _open();
        assertEq(_checkedSwap(true, true, 4, false), 1, "4 wei in at 20%: ceil(0.8)");
        assertEq(_checkedSwap(true, true, 5, false), 1, "5 wei in at 20%: exactly 1");
        assertEq(_checkedSwap(true, true, 1, false), 1, "1 wei in at 20%: the whole wei is fee");
        assertEq(_checkedSwap(false, false, 4, false), 1, "4 wei IMD out at 20%: ceil(5 * 0.2)");
        assertGt(_checkedSwap(true, false, 4, false), 0, "4 wei KEPT out at 20%");
        assertGt(_checkedSwap(false, true, 40, false), 0, "40 wei KEPT in at 20%");
        vm.warp(OPEN + 1800);
        assertEq(hook.feeNow(), 100);
        assertEq(_checkedSwap(true, true, 99, false), 1, "99 wei in at 1%: ceil(0.99)");
        assertEq(_checkedSwap(true, true, 100, false), 1, "100 wei in at 1%: exactly 1");
        assertEq(_checkedSwap(true, true, 101, false), 2, "101 wei in at 1%: ceil(1.01)");
        assertEq(_checkedSwap(false, false, 98, false), 1, "98 wei IMD out at 1%: ceil(99 * 0.01)");
        assertGt(_checkedSwap(true, false, 90, false), 0, "90 wei KEPT out at 1%: IMD leg ~93 wei");
        assertGt(_checkedSwap(false, true, 90, false), 0, "90 wei KEPT in at 1%");
    }

    /// @dev Whenever IMD is the specified side, a nonzero request pays a nonzero fee; the other two
    /// modes pay whenever the pool moves any IMD at all (asserted by the fixture).
    function testFuzz_dustSwapsAlwaysPay(bool buy, bool exactIn, uint16 size, uint16 time) public {
        _open();
        vm.warp(OPEN + bound(time, 0, 3600));
        uint256 charged = _checkedSwap(buy, exactIn, bound(size, 1, 10_000), false);
        if (buy == exactIn) assertGt(charged, 0, "IMD-specified dust still pays");
    }

    function testFuzz_feeAndPartialFills(bool buy, bool exactIn, uint96 size, uint32 time, bool limited)
        public
    {
        _open();
        vm.warp(OPEN + bound(time, 0, 3600));
        _checkedSwap(buy, exactIn, bound(size, 1, 1e25), limited);
    }

    function testFuzz_crossTicks(bool buy, bool exactIn, uint96 size, uint16 time) public {
        _open();
        router.seed(key, -120, 120, 1e25);
        router.seed(key, -360, 360, 1e25);
        vm.warp(OPEN + bound(time, 0, 3600));
        _checkedSwap(buy, exactIn, bound(size, 1e24, 9e26), false);
    }

    function test_partialFillsAllModes() public {
        _open();
        for (uint256 t; t < 2; ++t) {
            vm.warp(OPEN + t * 1800);
            _checkedSwap(true, true, 1e25, true);
            _checkedSwap(true, false, 1e25, true);
            _checkedSwap(false, true, 1e25, true);
            _checkedSwap(false, false, 1e25, true);
        }
    }

    function test_sweepFundsTheReferee() public {
        uint256 o = _open();
        vm.warp(OPEN + 1800);
        uint256 a = _checkedSwap(true, true, 100e18, false);
        uint256 b = _checkedSwap(false, true, 100e18, false);
        assertGt(a + b, 0);
        vm.prank(address(0xCAFE));
        uint256 swept = hook.sweep();
        assertEq(swept, o + a + b);
        assertEq(vault.refereeFund(), o + a + b);
        assertEq(imd.balanceOf(address(vault)), o + a + b);
        assertEq(hook.pending(), 0);
        assertEq(hook.sweep(), 0, "nothing left");
    }

    function test_sweepIncludesDirectDonations() public {
        imd.transfer(address(hook), 3e18);
        assertEq(hook.sweep(), 3e18);
        assertEq(vault.refereeFund(), 3e18);
    }

    function test_sweepDuringUnlockDefers() public {
        _checkedSwap(true, true, 1e18, false);
        router.sweepDuringUnlock(key);
        assertGt(hook.pending(), 0);
        hook.sweep();
        assertEq(hook.pending(), 0);
    }

    function test_callbacksOnlyManager() public {
        SwapParams memory p = _params(true, true, 1e18, false);
        vm.expectRevert(KeptHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(KeptHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(KeptHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, ONE);
        vm.expectRevert(KeptHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_onlyOnePoolEver() public {
        PoolKey memory other = key;
        other.tickSpacing = 120;
        vm.expectRevert();
        manager.initialize(other, ONE);
    }

    function test_onlyFactoryInitializes() public {
        address at = address(uint160(0x4b455054000000000000000000000000000001) << 14 | HookFlags.KEPT);
        deployCodeTo(
            "KeptHook.sol:KeptHook",
            abi.encode(manager, address(imd), address(kept), address(vault), address(0xFAC)),
            at
        );
        PoolKey memory other = key;
        other.hooks = IHooks(at);
        vm.expectRevert();
        manager.initialize(other, ONE);
        assertFalse(KeptHook(at).initialized());
        vm.prank(address(0xFAC));
        vm.expectEmit(true, true, true, true, at);
        emit KeptHook.Initialized();
        manager.initialize(other, ONE);
        assertTrue(KeptHook(at).initialized());
        assertEq(KeptHook(at).openedAt(), 0);
        vm.prank(address(0xFAC));
        vm.expectRevert();
        manager.initialize(other, ONE);
    }

    function test_constructorArgumentsInLaunchOrder() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(Currency.unwrap(hook.imd()), address(imd));
        assertEq(hook.token(), address(kept));
        assertEq(hook.vault(), address(vault));
        assertEq(hook.factory(), address(this));
        assertEq(hook.LP_FEE(), 12500);
        assertEq(hook.TICK_SPACING(), 60);
    }

    function test_permissionBits() public view {
        assertTrue(HookFlags.matches(address(hook), HookFlags.KEPT));
        assertEq(uint160(address(hook)) & HookFlags.ALL, 0x20cc);
    }

    function test_constructorRejectsBadConfig() public {
        vm.expectRevert(KeptHook.InvalidConfiguration.selector);
        new KeptHook(manager, address(imd), address(imd), address(vault), address(this));
        vm.expectRevert(KeptHook.InvalidConfiguration.selector);
        new KeptHook(manager, address(imd), address(kept), address(0), address(this));
        vm.expectRevert(KeptHook.InvalidConfiguration.selector);
        new KeptHook(manager, address(imd), address(kept), address(vault), address(0));
    }

    function test_noLiquidityNoFee() public {
        router.seed(key, -600, 600, -1e27);
        SwapParams memory p = _params(true, true, 1e18, false);
        router.swap(key, p);
        assertEq(hook.collected(), 0);
    }
}

contract KeptHookTokenFirstTest is KeptHookTest {
    function _imdFirst() internal pure override returns (bool) {
        return false;
    }
}

/// @dev Finding 277d240e, in its own contract so the main suite stays within via-IR stack limits.
contract KeptHookOpeningTest is HookFixture {
    /// @dev Finding 277d240e: a 1-wei exact-input IMD swap is all fee, so the pool fills nothing of
    /// it. On the empty pool it used to start the opening window anyway; now it is charged (the fee
    /// rounds up and 1 wei cannot be split) but the window stays closed until a swap moves IMD.
    function test_oneWeiSwapOnEmptyPoolIsChargedButDoesNotOpenTheWindow() public {
        router.seed(key, -600, 600, -1e27);
        router.swap(key, _params(true, true, 1, false));
        assertEq(hook.collected(), 1, "the wei is still fee");
        assertEq(hook.openedAt(), 0, "no IMD moved: window stays closed");
        assertEq(hook.feeNow(), 2000);
        vm.warp(OPEN + 1800);
        router.seed(key, -600, 600, 1e27);
        assertEq(hook.feeNow(), 2000, "first real trade pays 20%");
        assertEq(_checkedSwap(true, true, 1_000e18, false), 200e18);
        assertEq(hook.openedAt(), OPEN + 1800);
        vm.warp(OPEN + 3600);
        assertEq(hook.feeNow(), 100);
    }

    /// @dev The same wei on a seeded pool is charged and leaves the window closed too: only a swap
    /// the pool fills opens it.
    function test_oneWeiSwapOnSeededPoolDoesNotOpenTheWindowEither() public {
        vm.warp(OPEN + 100);
        uint256 charged = _checkedSwap(true, true, 1, false);
        assertEq(charged, 1, "whole wei is fee");
        assertEq(hook.openedAt(), 0, "nothing moved through the pool");
        charged = _checkedSwap(true, true, 2, false);
        assertEq(charged, 1, "2 wei: one wei of fee, one wei swapped");
        assertEq(hook.openedAt(), OPEN + 100, "the first filled swap opens the window");
    }
}

contract KeptHookOpeningTokenFirstTest is KeptHookOpeningTest {
    function _imdFirst() internal pure override returns (bool) {
        return false;
    }
}

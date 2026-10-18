// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {KeptHook} from "../src/KeptHook.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Inputs the hook must refuse, and edges it must survive, beyond the fee-schedule suite.
contract KeptHookFailurePathsTest is HookFixture {
    uint160 internal nextSlot = 0x100;

    /// @dev A fresh, uninitialized hook at a new 0x20cc address, configured like the launch.
    function _freshHook(address factory_) internal returns (KeptHook fresh, PoolKey memory k) {
        address at =
            address(uint160(0x4b4550540000000000000000000000000000) + ++nextSlot << 14 | HookFlags.KEPT);
        deployCodeTo(
            "KeptHook.sol:KeptHook",
            abi.encode(manager, address(imd), address(kept), address(vault), factory_),
            at
        );
        fresh = KeptHook(at);
        k = key;
        k.hooks = IHooks(at);
    }

    function _expectInvalidPool(address at) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                at,
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(KeptHook.InvalidPool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_initializeRejectsWrongFee() public {
        (KeptHook fresh, PoolKey memory k) = _freshHook(address(this));
        k.fee = 3000;
        _expectInvalidPool(address(fresh));
        manager.initialize(k, ONE);
        assertFalse(fresh.initialized());
    }

    function test_initializeRejectsDynamicFee() public {
        (KeptHook fresh, PoolKey memory k) = _freshHook(address(this));
        k.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        _expectInvalidPool(address(fresh));
        manager.initialize(k, ONE);
        assertFalse(fresh.initialized());
    }

    function test_initializeRejectsWrongTickSpacing() public {
        (KeptHook fresh, PoolKey memory k) = _freshHook(address(this));
        k.tickSpacing = 10;
        _expectInvalidPool(address(fresh));
        manager.initialize(k, ONE);
        assertFalse(fresh.initialized());
    }

    function test_initializeRejectsAPairWithoutKept() public {
        (KeptHook fresh, PoolKey memory k) = _freshHook(address(this));
        MockERC20 other = new MockERC20("OTHER", "OTH", 0);
        bool imdLow = address(imd) < address(other);
        k.currency0 = Currency.wrap(imdLow ? address(imd) : address(other));
        k.currency1 = Currency.wrap(imdLow ? address(other) : address(imd));
        _expectInvalidPool(address(fresh));
        manager.initialize(k, ONE);
        assertFalse(fresh.initialized());
    }

    function test_initializeRejectsAPairWithoutIMD() public {
        (KeptHook fresh, PoolKey memory k) = _freshHook(address(this));
        MockERC20 other = new MockERC20("OTHER", "OTH", 0);
        bool keptLow = address(kept) < address(other);
        k.currency0 = Currency.wrap(keptLow ? address(kept) : address(other));
        k.currency1 = Currency.wrap(keptLow ? address(other) : address(kept));
        _expectInvalidPool(address(fresh));
        manager.initialize(k, ONE);
        assertFalse(fresh.initialized());
    }

    function test_initializeRejectsNativeAgainstKept() public {
        (KeptHook fresh, PoolKey memory k) = _freshHook(address(this));
        k.currency0 = Currency.wrap(address(0));
        k.currency1 = Currency.wrap(address(kept));
        _expectInvalidPool(address(fresh));
        manager.initialize(k, ONE);
        assertFalse(fresh.initialized());
    }

    /// @dev The hook check is direct: a call from the manager naming another hook in the key is refused.
    function test_beforeInitializeRejectsAKeyNamingAnotherHook() public {
        (KeptHook fresh, PoolKey memory k) = _freshHook(address(this));
        k.hooks = IHooks(address(hook));
        vm.prank(address(manager));
        vm.expectRevert(KeptHook.InvalidPool.selector);
        fresh.beforeInitialize(address(this), k, ONE);
    }

    /// @dev Front-running the factory's initialize with the correct key fails and does not block it.
    function test_strangerCannotFrontRunTheFactoryInitialize() public {
        address factory_ = makeAddr("factory");
        (KeptHook fresh, PoolKey memory k) = _freshHook(factory_);
        address stranger = makeAddr("stranger");
        for (uint256 i; i < 3; ++i) {
            vm.prank(i == 0 ? stranger : i == 1 ? address(this) : address(manager));
            _expectInvalidPool(address(fresh));
            manager.initialize(k, ONE);
        }
        assertFalse(fresh.initialized());
        vm.prank(factory_);
        manager.initialize(k, ONE);
        assertTrue(fresh.initialized());
    }

    /// @dev Once initialized, even the factory cannot open a second pool on the hook.
    function test_factoryCannotInitializeASecondPool() public {
        PoolKey memory k = key;
        k.tickSpacing = 120;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(KeptHook.AlreadyInitialized.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(k, ONE);
        vm.prank(address(manager));
        vm.expectRevert(KeptHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(this), key, ONE);
    }

    function test_constructorRejectsZeroManagerIMDOrToken() public {
        vm.expectRevert(KeptHook.InvalidConfiguration.selector);
        new KeptHook(IPoolManager(address(0)), address(imd), address(kept), address(vault), address(this));
        vm.expectRevert(KeptHook.InvalidConfiguration.selector);
        new KeptHook(manager, address(0), address(kept), address(vault), address(this));
        vm.expectRevert(KeptHook.InvalidConfiguration.selector);
        new KeptHook(manager, address(imd), address(0), address(vault), address(this));
    }

    /// @dev Valid arguments at an address without exactly the 0x20cc bits are refused by the permission check.
    function test_constructorRejectsAddressesWithOtherFlags() public {
        uint160[3] memory flags = [uint160(0x20c8), uint160(0x20cd), uint160(0x30cc)];
        for (uint256 i; i < flags.length; ++i) {
            address at = address(uint160(0x4b455054000000000000000000000000000077) << 14 | flags[i]);
            vm.expectRevert();
            this.deployAt(at);
        }
    }

    function deployAt(address at) external {
        deployCodeTo(
            "KeptHook.sol:KeptHook",
            abi.encode(manager, address(imd), address(kept), address(vault), address(this)),
            at
        );
    }

    /// @dev Only a sweep the hook started may enter its unlock callback, even from the manager.
    function test_unlockCallbackOutsideASweepReverts() public {
        vm.prank(address(manager));
        vm.expectRevert(KeptHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
    }

    /// @dev An empty sweep must not call fundReferee(0), which the vault refuses.
    function test_emptySweepIsANoOp() public {
        assertEq(hook.pending(), 0);
        vm.expectEmit(true, true, true, true, address(hook));
        emit KeptHook.Swept(0);
        assertEq(hook.sweep(), 0);
        assertEq(vault.refereeFund(), 0);
        assertEq(imd.allowance(address(hook), address(vault)), 0);
    }

    function test_repeatedSweepsNeverPayTwice() public {
        _open();
        uint256 owed = hook.pending();
        assertGt(owed, 0);
        assertEq(hook.sweep(), owed);
        for (uint256 i; i < 3; ++i) {
            assertEq(hook.sweep(), 0);
        }
        assertEq(vault.refereeFund(), owed);
        assertEq(imd.allowance(address(hook), address(vault)), 0, "no allowance left behind");
        assertEq(hook.collected(), owed, "sweeping does not touch the lifetime total");
    }

    function test_zeroAmountSwapReverts() public {
        SwapParams memory p = _params(true, true, 0, false);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        router.swap(key, p);
        assertEq(hook.collected(), 0);
        assertEq(hook.openedAt(), 0);
    }

    /// @dev A price limit on the wrong side is refused by the manager; the hook charges nothing.
    function test_wrongSidePriceLimitReverts() public {
        SwapParams memory p = _params(true, true, 1e18, false);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(p.zeroForOne ? int24(60) : int24(-60));
        vm.expectRevert();
        router.swap(key, p);
        assertEq(hook.collected(), 0);
        assertEq(hook.openedAt(), 0);
    }

    /// @dev Requests above int128 are clamped for the quote; the pool fills to the price limit
    /// and the fee is still the exact ceiling on the IMD that moved.
    function test_hugeRequestsAreChargedOnWhatFills() public {
        _open();
        imd.mint(address(this), 1e30);
        uint256 huge = uint256(type(uint128).max) + 1;
        assertGt(_checkedSwap(true, true, huge, false), 0, "exact in above int128");
        assertGt(_checkedSwap(false, false, huge, false), 0, "exact IMD out above int128");
    }

    /// @dev Sending native value to the hook is refused: it has no receive path to strand ETH.
    function test_hookRefusesNativeValue() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
        assertEq(address(hook).balance, 0);
    }

    /// @dev No owner, proxy or upgrade entry point exists.
    function test_noAdminOrUpgradeSurface() public {
        bytes[7] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(this), ""),
            abi.encodeWithSignature("setVault(address)", address(this)),
            abi.encodeWithSignature("setFee(uint256)", 0),
            abi.encodeWithSignature("withdraw(address,uint256)", address(this), 1),
            abi.encodeWithSignature("pause()")
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok, "no admin entry point");
        }
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(vm.load(address(hook), implSlot), bytes32(0), "not an ERC-1967 proxy");
    }

    /// @dev A KEPT-only donation cannot be swept into the fund and is not counted as pending IMD.
    function test_keptSentToTheHookIsNotCountedAsIMD() public {
        kept.transfer(address(hook), 1e18);
        assertEq(hook.pending(), 0);
        assertEq(hook.sweep(), 0);
        assertEq(vault.refereeFund(), 0);
    }

    /// @dev Fuzzed: the fee schedule is monotone non-increasing and bounded at every instant.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeNowMonotoneAndBounded(uint32 a, uint32 b) public {
        _open();
        uint256 t1 = bound(a, 0, 10_000);
        uint256 t2 = bound(b, t1, 20_000);
        vm.warp(OPEN + t1);
        uint256 f1 = hook.feeNow();
        vm.warp(OPEN + t2);
        uint256 f2 = hook.feeNow();
        assertLe(f2, f1);
        assertGe(f2, 100);
        assertLe(f1, 2000);
        if (t2 >= 1800) assertEq(f2, 100);
    }
}

contract KeptHookFailurePathsTokenFirstTest is KeptHookFailurePathsTest {
    function _imdFirst() internal pure override returns (bool) {
        return false;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {KeptToken} from "../src/KeptToken.sol";
import {KeptHook} from "../src/KeptHook.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";

/// @dev Local CREATE2 probe standing in for the launch factory. Never calls the live factory.
contract HookLaunchProbe {
    error DeploymentFailed();

    function deploy(bytes memory code, bytes32 salt) external payable returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(callvalue(), add(code, 32), mload(code), salt)
        }
        if (deployed == address(0)) revert DeploymentFailed();
    }
}

/// @notice The launch deploys KeptToken (no arguments) and then KeptHook with, in order,
/// $poolManager, IMD, $token, the deployed KeptVault and $factory, from a CREATE2 address carrying
/// the 0x20cc permission bits, on a chain where none of those addresses need code yet.
contract KeptHookLaunchTest is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant VAULT = 0x3152f9cbF64D0C1AC24EA7E101dB3E4d8da86896;

    HookLaunchProbe probe;
    KeptToken token;
    bytes hookInitCode;

    function setUp() public {
        vm.chainId(4663);
        probe = new HookLaunchProbe();
        token = KeptToken(probe.deploy(vm.getCode("KeptToken.sol:KeptToken"), keccak256("KEPT token")));
        hookInitCode = bytes.concat(
            vm.getCode("KeptHook.sol:KeptHook"),
            abi.encode(POOL_MANAGER, IMD, address(token), VAULT, address(probe))
        );
    }

    function _mine(bytes memory initCode) internal view returns (bytes32 salt, address predicted) {
        bytes32 codeHash = keccak256(initCode);
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(probe), salt, codeHash))))
            );
            if (HookFlags.matches(predicted, HookFlags.KEPT)) return (salt, predicted);
        }
        revert("no salt");
    }

    function test_tokenMintsTheWholeSupplyToItsDeployer() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(probe)), 1e27, "the factory holds the supply");
        assertEq(token.decimals(), 18);
    }

    function test_hookDeploysOnAnEmptyChainWithLaunchArguments() public {
        assertEq(POOL_MANAGER.code.length, 0, "no PoolManager code on the empty chain");
        assertEq(IMD.code.length, 0);
        assertEq(VAULT.code.length, 0);
        assertLe(hookInitCode.length, 49_152);
        (bytes32 salt, address predicted) = _mine(hookInitCode);
        address launchWallet = makeAddr("launch wallet");
        vm.prank(launchWallet, launchWallet);
        KeptHook hook = KeptHook(probe.deploy(hookInitCode, salt));
        assertEq(address(hook), predicted);
        assertEq(uint160(address(hook)) & HookFlags.ALL, 0x20cc);
        assertEq(address(hook).balance, 0);
        assertEq(address(hook.poolManager()), POOL_MANAGER);
        assertEq(Currency.unwrap(hook.imd()), IMD);
        assertEq(hook.token(), address(token));
        assertEq(hook.vault(), VAULT);
        assertEq(hook.factory(), address(probe), "only the deploying factory may initialize");
        assertFalse(hook.initialized());
        assertEq(hook.openedAt(), 0);
        assertEq(hook.collected(), 0);
        assertEq(hook.feeNow(), hook.OPENING_FEE());
        assertEq(token.balanceOf(address(hook)), 0, "the hook is allocated nothing");
    }

    function test_hookRefusesAnAddressWithoutItsPermissionBits() public {
        vm.expectRevert();
        probe.deploy(hookInitCode, keccak256("unmined"));
    }

    function test_constructorsRejectNativeValue() public {
        vm.deal(address(this), 2);
        (bytes32 salt,) = _mine(hookInitCode);
        vm.expectRevert(HookLaunchProbe.DeploymentFailed.selector);
        probe.deploy{value: 1}(hookInitCode, salt);
        vm.expectRevert(HookLaunchProbe.DeploymentFailed.selector);
        probe.deploy{value: 1}(vm.getCode("KeptToken.sol:KeptToken"), keccak256("value"));
    }

    function test_runtimesFitAndHaveNoForbiddenOpcodes() public {
        (bytes32 salt,) = _mine(hookInitCode);
        address hook = probe.deploy(hookInitCode, salt);
        _scan(hook.code);
        _scan(address(token).code);
    }

    function _scan(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "no DELEGATECALL, CALLCODE or SELFDESTRUCT");
            assertTrue(op != 0xf0 && op != 0xf5, "no CREATE or CREATE2");
        }
    }
}

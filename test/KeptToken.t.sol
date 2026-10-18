// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeptToken} from "../src/KeptToken.sol";

/// @notice The launch token: no constructor arguments, 18 decimals, exactly 10^27 minor units minted
/// once to its deployer (the launch factory), nothing else.
contract KeptTokenTest is Test {
    KeptToken token;
    address factory = makeAddr("factory");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        vm.prank(factory);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), factory, 1_000_000_000e18);
        token = new KeptToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "KEPT");
        assertEq(token.symbol(), "KEPT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(factory), 1e27, "whole supply to the deployer");
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_transfer() public {
        vm.prank(factory);
        assertTrue(token.transfer(alice, 5e18));
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(token.balanceOf(factory), 1e27 - 5e18);
        vm.prank(alice);
        vm.expectRevert(KeptToken.InsufficientBalance.selector);
        token.transfer(bob, 6e18);
        vm.prank(alice);
        vm.expectRevert(KeptToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
        assertEq(token.totalSupply(), 1e27, "transfers never change supply");
    }

    function test_approveAndTransferFrom() public {
        vm.prank(factory);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        assertTrue(token.approve(bob, 4e18));
        assertEq(token.allowance(alice, bob), 4e18);
        vm.prank(bob);
        vm.expectRevert(KeptToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 5e18);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 4e18));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(bob), 4e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, bob, 1e18);
        assertEq(token.allowance(alice, bob), type(uint256).max, "infinite allowance is not spent");
    }

    function test_noAdminSurface() public {
        bytes4[6] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("burn(uint256)")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("setFee(uint256)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], address(this), 1));
            assertFalse(ok, "no mint, burn, owner, pause or fee entry point");
        }
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        vm.prank(factory);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(factory), 1e27);
    }
}

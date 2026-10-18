// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeptToken} from "../src/KeptToken.sol";

/// @dev Random transfers, approvals and transferFroms among a fixed set of holders, including
/// self-transfers, zero amounts and over-spends. Ghosts mirror what each call must have done.
contract KeptTokenHandler is Test {
    KeptToken public immutable token;
    address[4] public holders;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    uint256 public succeeded;
    uint256 public violations;

    constructor(KeptToken token_, address[4] memory holders_) {
        token = token_;
        holders = holders_;
    }

    function holderCount() external pure returns (uint256) {
        return 4;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = holders[fromSeed % 4];
        address to = holders[toSeed % 4];
        uint256 balance = token.balanceOf(from);
        amount = bound(amount, 0, balance + 1);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok || amount > balance) ++violations;
            if (from != to && token.balanceOf(to) != toBefore + amount) ++violations;
            if (from == to && token.balanceOf(to) != toBefore) ++violations;
            ++succeeded;
        } catch {
            if (amount <= balance) ++violations;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner_ = holders[ownerSeed % 4];
        address spender = holders[spenderSeed % 4];
        if (infinite) amount = type(uint256).max;
        vm.prank(owner_);
        token.approve(spender, amount);
        ghostAllowance[owner_][spender] = amount;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = holders[spenderSeed % 4];
        address from = holders[fromSeed % 4];
        address to = holders[toSeed % 4];
        uint256 approved = token.allowance(from, spender);
        uint256 balance = token.balanceOf(from);
        uint256 cap = approved < balance ? approved : balance;
        amount = bound(amount, 0, cap == type(uint256).max ? cap : cap + 1);
        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            if (amount > approved || amount > balance) ++violations;
            if (approved != type(uint256).max) ghostAllowance[from][spender] = approved - amount;
            ++succeeded;
        } catch {
            if (amount <= approved && amount <= balance) ++violations;
        }
    }
}

contract KeptTokenInvariantTest is Test {
    KeptToken token;
    KeptTokenHandler handler;
    address[4] holders;

    function setUp() public {
        holders = [makeAddr("factory"), makeAddr("a"), makeAddr("b"), makeAddr("c")];
        vm.prank(holders[0]);
        token = new KeptToken();
        handler = new KeptTokenHandler(token, holders);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesSumToTheFixedSupply() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(holders[i]);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(sum, 1e27, "no KEPT created or destroyed");
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_callsBehaveAndAllowancesTrack() public view {
        assertEq(handler.violations(), 0, "a call succeeded or failed against its preconditions");
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                assertEq(
                    token.allowance(holders[i], holders[j]), handler.ghostAllowance(holders[i], holders[j])
                );
            }
        }
    }

    function afterInvariant() public view {
        assertGt(handler.succeeded(), 0, "no transfer succeeded");
    }

    function test_failurePaths() public {
        address a = holders[1];
        vm.prank(a);
        vm.expectRevert(KeptToken.InsufficientBalance.selector);
        token.transfer(holders[2], 1);
        vm.prank(a);
        vm.expectRevert(KeptToken.ZeroAddress.selector);
        token.approve(address(0), 1);
        vm.prank(holders[0]);
        token.approve(a, type(uint256).max);
        vm.prank(a);
        vm.expectRevert(KeptToken.ZeroAddress.selector);
        token.transferFrom(holders[0], address(0), 1);
        vm.prank(a);
        vm.expectRevert(KeptToken.InsufficientBalance.selector);
        token.transferFrom(holders[0], a, 1e27 + 1);
        vm.prank(a);
        vm.expectRevert(KeptToken.InsufficientAllowance.selector);
        token.transferFrom(holders[2], a, 1);
        // Zero-amount moves succeed and change nothing.
        vm.prank(a);
        assertTrue(token.transfer(holders[2], 0));
        vm.prank(holders[2]);
        assertTrue(token.transferFrom(holders[0], holders[2], 0));
        // Self-transfer of the whole supply leaves it in place.
        vm.prank(holders[0]);
        token.transfer(holders[0], 1e27);
        assertEq(token.balanceOf(holders[0]), 1e27);
        // Native value is refused.
        vm.deal(address(this), 1);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok);
    }
}

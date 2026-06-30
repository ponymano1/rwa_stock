// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Base.t.sol";

contract ComplianceTest is Base {
    function test_RevertWhen_TransferToUnverified() public {
        _mint(alice, 10 * ONE);
        vm.prank(alice);
        vm.expectRevert(bytes("COMPLIANCE_FAIL"));
        token.transfer(mallory, 1 * ONE);
    }

    function test_RevertWhen_TransferFromFrozen() public {
        _mint(alice, 10 * ONE);
        vm.prank(admin);
        comp.setFrozen(alice, true);
        vm.prank(alice);
        vm.expectRevert(bytes("COMPLIANCE_FAIL"));
        token.transfer(bob, 1 * ONE);
    }

    function test_RevertWhen_TransferToFrozen() public {
        _mint(alice, 10 * ONE);
        vm.prank(admin);
        comp.setFrozen(bob, true);
        vm.prank(alice);
        vm.expectRevert(bytes("COMPLIANCE_FAIL"));
        token.transfer(bob, 1 * ONE);
    }

    function test_RevertWhen_SenderInLockup() public {
        _mint(alice, 10 * ONE);
        vm.prank(admin);
        comp.setLock(alice, block.timestamp + 30 days);
        vm.prank(alice);
        vm.expectRevert(bytes("COMPLIANCE_FAIL"));
        token.transfer(bob, 1 * ONE);
    }

    function test_TransferAllowedAfterLockExpires() public {
        _mint(alice, 10 * ONE);
        vm.prank(admin);
        comp.setLock(alice, block.timestamp + 30 days);
        vm.warp(block.timestamp + 31 days);
        vm.prank(alice);
        token.transfer(bob, 1 * ONE);
        assertEq(token.balanceOf(bob), 1 * ONE);
    }

    function test_RevertWhen_MintToUnverifiedReceiver() public {
        // mallory 通过他人请求不可能，这里直接测 executeMint 给未验证人
        // 改为：alice 请求，但中途被冻结
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(token), 1000e6);
        uint256 id = token.requestMint(1000e6, 0);
        vm.stopPrank();

        vm.prank(admin);
        comp.setFrozen(alice, true); // 冻结后 canReceive=false

        vm.prank(op);
        vm.expectRevert(bytes("RECEIVER_NOT_ALLOWED"));
        token.executeMint(id, 10 * ONE, 100e18);
    }

    function test_NormalTransferBetweenVerified() public {
        _mint(alice, 10 * ONE);
        vm.prank(alice);
        token.transfer(bob, 4 * ONE);
        assertEq(token.balanceOf(alice), 6 * ONE);
        assertEq(token.balanceOf(bob), 4 * ONE);
    }
}
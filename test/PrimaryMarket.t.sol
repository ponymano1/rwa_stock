// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Base.t.sol";

contract PrimaryMarketTest is Base {
    /* ───────── 申购 ───────── */

    function test_RequestAndExecuteMint() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(token), 1000e6);
        uint256 id = token.requestMint(1000e6, 9 * ONE);
        vm.stopPrank();

        // 合约锁住 USDC
        assertEq(usdc.balanceOf(address(token)), 1000e6);

        vm.prank(op);
        token.executeMint(id, 10 * ONE, 100e18);

        assertEq(token.balanceOf(alice), 10 * ONE);
        // 锁定 USDC 转给 op 用于结算
        assertEq(usdc.balanceOf(op), 1000e6);
    }

    function test_RevertWhen_MintSlippageNotMet() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(token), 1000e6);
        uint256 id = token.requestMint(1000e6, 11 * ONE); // 要求至少 11 股
        vm.stopPrank();

        vm.prank(op);
        vm.expectRevert(bytes("SLIPPAGE"));
        token.executeMint(id, 10 * ONE, 100e18); // 只买到 10
    }

    function test_RevertWhen_UnverifiedRequestsMint() public {
        usdc.mint(mallory, 1000e6);
        vm.startPrank(mallory);
        usdc.approve(address(token), 1000e6);
        vm.expectRevert(bytes("NOT_ALLOWED"));
        token.requestMint(1000e6, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_MintBreaksSolvency() public {
        vm.prank(admin);
        reserve.setShares(5 * ONE); // 托管仅 5 股

        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(token), 1000e6);
        uint256 id = token.requestMint(1000e6, 0);
        vm.stopPrank();

        vm.prank(op);
        vm.expectRevert(bytes("SOLVENCY"));
        token.executeMint(id, 10 * ONE, 100e18); // 想铸 10 > 托管 5
    }

    function test_RevertWhen_MintWhileMarketClosed() public {
        vm.prank(admin); // 任何人可设 mock；这里用 admin 方便
        oracle.setMarketOpen(false);

        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(token), 1000e6);
        uint256 id = token.requestMint(1000e6, 0);
        vm.stopPrank();

        vm.prank(op);
        vm.expectRevert(bytes("MARKET_CLOSED"));
        token.executeMint(id, 10 * ONE, 100e18);
    }

    /* ───────── 赎回 ───────── */

    function test_RequestAndExecuteRedeem() public {
        _mint(alice, 10 * ONE);

        vm.prank(alice);
        uint256 id = token.requestRedeem(10 * ONE, 900e6);
        // 份额转入合约托管
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(token)), 10 * ONE);

        // 运营商卖股回款 1000 USDC
        usdc.mint(op, 1000e6);
        vm.startPrank(op);
        usdc.approve(address(token), 1000e6);
        token.executeRedeem(id, 10 * ONE, 100e18, 1000e6);
        vm.stopPrank();

        assertEq(token.balanceOf(address(token)), 0); // 已销毁
        assertEq(token.totalSupply(), 0);
        assertEq(usdc.balanceOf(alice), 1000e6);
    }

    function test_RevertWhen_RedeemSlippageNotMet() public {
        _mint(alice, 10 * ONE);
        vm.prank(alice);
        uint256 id = token.requestRedeem(10 * ONE, 1100e6); // 要求至少 1100

        usdc.mint(op, 1000e6);
        vm.startPrank(op);
        usdc.approve(address(token), 1000e6);
        vm.expectRevert(bytes("SLIPPAGE"));
        token.executeRedeem(id, 10 * ONE, 100e18, 1000e6);
        vm.stopPrank();
    }

    /* ───────── 取消 ───────── */

    function test_UserCancelMintAfterTimeout() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(token), 1000e6);
        uint256 id = token.requestMint(1000e6, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        token.cancelOrder(id);
        assertEq(usdc.balanceOf(alice), 1000e6); // 全额退款
    }

    function test_RevertWhen_UserCancelBeforeTimeout() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(token), 1000e6);
        uint256 id = token.requestMint(1000e6, 0);
        vm.expectRevert(bytes("not timed out"));
        token.cancelOrder(id);
        vm.stopPrank();
    }

    function test_OperatorCanCancelImmediately() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(token), 1000e6);
        uint256 id = token.requestMint(1000e6, 0);
        vm.stopPrank();

        vm.prank(op); // 运营商无需等超时（如停牌场景）
        token.cancelOrder(id);
        assertEq(usdc.balanceOf(alice), 1000e6);
    }

    function test_CancelRedeemReturnsShares() public {
        _mint(alice, 10 * ONE);
        vm.prank(alice);
        uint256 id = token.requestRedeem(10 * ONE, 0);

        vm.prank(op);
        token.cancelOrder(id);
        assertEq(token.balanceOf(alice), 10 * ONE); // 份额退回
    }

    function test_RevertWhen_ExecuteCancelledOrder() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(token), 1000e6);
        uint256 id = token.requestMint(1000e6, 0);
        vm.stopPrank();

        vm.prank(op);
        token.cancelOrder(id);

        vm.prank(op);
        vm.expectRevert(bytes("bad order"));
        token.executeMint(id, 10 * ONE, 100e18);
    }

    function test_RevertWhen_RandomUserCancelsOthersOrder() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(token), 1000e6);
        uint256 id = token.requestMint(1000e6, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 3 days);
        vm.prank(bob);
        vm.expectRevert(bytes("not authorized"));
        token.cancelOrder(id);
    }
}
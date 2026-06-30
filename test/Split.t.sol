// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Base.t.sol";

contract SplitTest is Base {
    function test_InitialMultiplierIsOne() public view {
        assertEq(token.uiMultiplier(), ONE);
        assertEq(token.newUIMultiplier(), ONE);
    }

    function test_ForwardSplitOnlyAffectsUINotRaw() public {
        _mint(alice, 10 * ONE);
        assertEq(token.balanceOf(alice), 10 * ONE);
        assertEq(token.balanceOfUI(alice), 10 * ONE);

        // 1拆2，1天后生效
        uint256 eff = block.timestamp + 1 days;
        vm.prank(op);
        token.setUIMultiplier(2 * ONE, eff, "SPLIT");

        // 生效前：仍按旧乘数
        assertEq(token.uiMultiplier(), ONE);
        assertEq(token.balanceOfUI(alice), 10 * ONE);

        // 生效后：UI 翻倍，raw 不变
        vm.warp(eff);
        assertEq(token.uiMultiplier(), 2 * ONE);
        assertEq(token.balanceOf(alice), 10 * ONE);
        assertEq(token.balanceOfUI(alice), 20 * ONE);
        assertEq(token.totalSupplyUI(), 20 * ONE);
    }

    function test_ReverseSplitHalvesUI() public {
        _mint(alice, 10 * ONE);
        uint256 eff = block.timestamp + 1 days;
        vm.prank(op);
        token.setUIMultiplier(ONE / 2, eff, "REVERSE_SPLIT");
        vm.warp(eff);
        assertEq(token.balanceOf(alice), 10 * ONE);
        assertEq(token.balanceOfUI(alice), 5 * ONE);
    }

    function test_ConversionRoundTripFloors() public {
        vm.warp(block.timestamp + 2 days);
        _refreshOracles(); // 关键：偿付检查会读 reserve
        vm.prank(op);
        token.setUIMultiplier(3 * ONE, block.timestamp + 1, "SPLIT");
        vm.warp(block.timestamp + 2);

        assertEq(token.toUIAmount(1), 3);
        assertEq(token.fromUIAmount(3 * ONE), ONE);
        assertEq(token.fromUIAmount(1), 0);
    }

    function test_RevertWhen_MultiplierZero() public {
        vm.prank(op);
        vm.expectRevert(bytes("multiplier=0"));
        token.setUIMultiplier(0, block.timestamp + 1 days, "SPLIT");
    }

    function test_RevertWhen_EffectiveNotFuture() public {
        vm.prank(op);
        vm.expectRevert(bytes("must be future"));
        token.setUIMultiplier(2 * ONE, block.timestamp, "SPLIT");
    }

    function test_RevertWhen_NonOperatorSchedulesSplit() public {
        vm.prank(alice);
        vm.expectRevert(); // AccessControl
        token.setUIMultiplier(2 * ONE, block.timestamp + 1 days, "SPLIT");
    }

    function test_RevertWhen_SplitBreaksSolvency() public {
        _mint(alice, 10 * ONE);
        // 托管只有 10 股，拆 2 倍后展示 20 股 > 托管 → 应失败
        vm.prank(admin);
        reserve.setShares(10 * ONE);
        vm.prank(op);
        vm.expectRevert(bytes("split breaks solvency"));
        token.setUIMultiplier(2 * ONE, block.timestamp + 1 days, "SPLIT");
    }

    function test_ConsecutiveSchedulesFixOldValue() public {
        _mint(alice, 10 * ONE);
        uint256 eff1 = block.timestamp + 1 days;
        vm.prank(op);
        token.setUIMultiplier(2 * ONE, eff1, "SPLIT");
        vm.warp(eff1); // 2x 已生效

        uint256 eff2 = block.timestamp + 1 days;
        vm.prank(op);
        token.setUIMultiplier(4 * ONE, eff2, "SPLIT");

        // 第二次排程前，旧值应被固化为 2x（而非初始 1x）
        assertEq(token.uiMultiplier(), 2 * ONE);
        vm.warp(eff2);
        assertEq(token.uiMultiplier(), 4 * ONE);
    }

    function test_EmitsUIMultiplierUpdated() public {
        uint256 eff = block.timestamp + 1 days;
        vm.expectEmit(false, false, false, true);
        emit IScaledUIAmount.UIMultiplierUpdated(ONE, 2 * ONE, eff);
        vm.prank(op);
        token.setUIMultiplier(2 * ONE, eff, "SPLIT");
    }
}
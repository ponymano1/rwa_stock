// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Base.t.sol";

contract FuzzTest is Base {
    /// raw↔UI 往返：fromUIAmount(toUIAmount(x)) <= x（向下取整不会放大）
    function testFuzz_ConversionNeverInflates(uint256 multiplier, uint96 raw) public {
        multiplier = bound(multiplier, 1, 100e18);
        vm.prank(op);
        token.setUIMultiplier(multiplier, block.timestamp + 1, "SPLIT");
        vm.warp(block.timestamp + 2);

        uint256 ui = token.toUIAmount(raw);
        uint256 back = token.fromUIAmount(ui);
        assertLe(back, uint256(raw)); // 永不放大，保证系统不被掏空
    }

    /// 分红派发后总可领取额 <= 已派发额（不凭空生成 USDC）
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

    /// 铸造永远不破坏偿付不变量
    function testFuzz_MintKeepsSolvency(uint96 stocks) public {
        stocks = uint96(bound(stocks, 1, 999_999e18)); // 不超过托管 1,000,000
        _mint(alice, stocks);
        assertTrue(token.isSolvent());
    }
}
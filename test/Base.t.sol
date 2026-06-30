// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StockRWAToken.sol";
import "../src/BasicCompliance.sol";
import "./mocks.sol";

abstract contract Base is Test {
    StockRWAToken   internal token;
    BasicCompliance internal comp;
    MockUSDC        internal usdc;
    MockStockOracle internal oracle;
    MockReserveOracle internal reserve;

    address internal admin    = makeAddr("admin");
    address internal op       = makeAddr("operator");
    address internal guardian = makeAddr("guardian");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal mallory  = makeAddr("mallory"); // 未 KYC

    uint256 internal constant ONE = 1e18;

   function setUp() public virtual {
        vm.warp(1_000_000); // 避免后续 block.timestamp - X 下溢

        usdc    = new MockUSDC();
        oracle  = new MockStockOracle(100e18, true);
        reserve = new MockReserveOracle(1_000_000e18);
        token   = new StockRWAToken("Tokenized AAPL", "tAAPL", address(usdc), admin, op, guardian);
        comp    = new BasicCompliance(admin);

        vm.startPrank(admin);
        token.setComplianceModule(address(comp));
        token.setOracle(address(oracle));
        token.setReserveOracle(address(reserve));
        comp.setVerified(alice, true);
        comp.setVerified(bob, true);
        comp.setVerified(op, true);
        comp.setVerified(address(token), true);
        vm.stopPrank();
    }

    /// 时间跳跃后刷新两个预言机的 updatedAt，避免误触 staleness 闸门
    function _refreshOracles() internal {
        oracle.setUpdatedAt(block.timestamp);
        reserve.setUpdatedAt(block.timestamp);
    }

    /* ───────── 工具：给 user 铸 stocks 股（UI 数量），乘数=1 时 raw==UI ───────── */
    function _mint(address user, uint256 stocks) internal {
        uint256 cost = 1_000_000e6; // 锁足额 USDC，成交价不影响份额数
        usdc.mint(user, cost);
        vm.startPrank(user);
        usdc.approve(address(token), cost);
        uint256 id = token.requestMint(cost, 0);
        vm.stopPrank();
        vm.prank(op);
        token.executeMint(id, stocks, 100e18);
    }

    /* ───────── 工具：运营商派发分红，需先给 op 备好 USDC ───────── */
    function _distribute(uint256 amount) internal {
        usdc.mint(op, amount);
        vm.startPrank(op);
        usdc.approve(address(token), amount);
        token.distributeDividend(amount);
        vm.stopPrank();
    }
}
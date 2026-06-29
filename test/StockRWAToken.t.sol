// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StockRWAToken.sol";
import "../src/BasicCompliance.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract StockRWATokenTest is Test {
    StockRWAToken token;
    BasicCompliance comp;
    MockUSDC usdc;
    address admin = address(0xA);
    address op    = address(0xB);
    address alice = address(0xC);

    function setUp() public {
        usdc = new MockUSDC();
        token = new StockRWAToken("Tokenized AAPL", "tAAPL", address(usdc), admin, op, admin);
        comp = new BasicCompliance(admin);
        vm.startPrank(admin);
        token.setComplianceModule(address(comp));
        comp.setVerified(alice, true);
        comp.setVerified(address(token), true); // 合约托管需可收
        comp.setVerified(op, true);
        vm.stopPrank();
    }

    function test_InitialMultiplierIsOne() public {
        assertEq(token.uiMultiplier(), 1e18);
    }

    function test_MintAndUIEqualsRawInitially() public {
        // alice 申购
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(token), 1000e6);
        uint256 id = token.requestMint(1000e6, 0);
        vm.stopPrank();

        // 运营商成交：买到 10 股
        vm.prank(op);
        token.executeMint(id, 10e18, 100e18);

        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.balanceOfUI(alice), 10e18); // 乘数=1，UI==raw
    }

    function test_TwoForOneSplitDoublesUI() public {
        // 先铸 10 股给 alice（略，复用上一步逻辑）
        _mintTo(alice, 10e18);

        // 安排 1拆2，明天生效
        vm.prank(op);
        token.setUIMultiplier(2e18, block.timestamp + 1 days, "SPLIT");

        // 生效前
        assertEq(token.balanceOfUI(alice), 10e18);
        // 生效后
        vm.warp(block.timestamp + 1 days + 1);
        assertEq(token.balanceOf(alice), 10e18);    // raw 不变
        assertEq(token.balanceOfUI(alice), 20e18);  // UI 翻倍
    }

    function test_DividendAccrualAndClaim() public {
        _mintTo(alice, 10e18); // alice 全部份额

        // 运营商发 50 USDC 分红
        usdc.mint(op, 50e6);
        vm.startPrank(op);
        usdc.approve(address(token), 50e6);
        token.distributeDividend(50e6);
        vm.stopPrank();

        assertApproxEqAbs(token.claimableDividend(alice), 50e6, 1);

        vm.prank(alice);
        uint256 got = token.claimDividend();
        assertApproxEqAbs(got, 50e6, 1);
    }

    function _mintTo(address to, uint256 stocks) internal {
        usdc.mint(to, 1e12);
        vm.startPrank(to);
        usdc.approve(address(token), type(uint256).max);
        uint256 id = token.requestMint(1e6, 0);
        vm.stopPrank();
        vm.prank(op);
        token.executeMint(id, stocks, 100e18);
    }
}
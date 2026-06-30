// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Base.t.sol";

contract DividendTest is Base {
    function test_SingleHolderGetsAll() public {
        _mint(alice, 10 * ONE);
        _distribute(50e6);
        assertApproxEqAbs(token.claimableDividend(alice), 50e6, 1);

        vm.prank(alice);
        uint256 got = token.claimDividend();
        assertApproxEqAbs(got, 50e6, 1);
        assertEq(token.claimableDividend(alice), 0);
    }

    function test_ProRataBetweenTwoHolders() public {
        _mint(alice, 30 * ONE);
        _mint(bob, 10 * ONE); // 总 40，alice 75% bob 25%
        _distribute(100e6);

        assertApproxEqAbs(token.claimableDividend(alice), 75e6, 2);
        assertApproxEqAbs(token.claimableDividend(bob), 25e6, 2);
    }

    function test_RevertWhen_DistributeWithNoSupply() public {
        usdc.mint(op, 10e6);
        vm.startPrank(op);
        usdc.approve(address(token), 10e6);
        vm.expectRevert(bytes("no shares"));
        token.distributeDividend(10e6);
        vm.stopPrank();
    }

    /// 关键：派发后再转账，历史分红应留在原持有人，不随份额转移
    function test_TransferAfterDistributionKeepsHistoricalDividend() public {
        _mint(alice, 10 * ONE);
        _distribute(50e6); // 全归 alice

        // alice 把全部份额转给 bob
        vm.prank(alice);
        token.transfer(bob, 10 * ONE);

        // 历史分红仍属 alice，bob 此时为 0
        assertApproxEqAbs(token.claimableDividend(alice), 50e6, 1);
        assertEq(token.claimableDividend(bob), 0);
    }

    /// 关键：转账后的新派发，应按新余额分配
    function test_NewDistributionAfterTransferGoesToNewHolder() public {
        _mint(alice, 10 * ONE);
        _distribute(50e6);

        vm.prank(alice);
        token.transfer(bob, 10 * ONE);

        _distribute(30e6); // 现在全归 bob

        assertApproxEqAbs(token.claimableDividend(alice), 50e6, 1); // 仅历史
        assertApproxEqAbs(token.claimableDividend(bob), 30e6, 1);   // 仅新增
    }

    function test_MultipleDistributionsAccumulate() public {
        _mint(alice, 10 * ONE);
        _distribute(20e6);
        _distribute(30e6);
        assertApproxEqAbs(token.claimableDividend(alice), 50e6, 1);
    }

    function test_ClaimResetsButKeepsFutureAccrual() public {
        _mint(alice, 10 * ONE);
        _distribute(20e6);
        vm.prank(alice);
        token.claimDividend();
        assertEq(token.claimableDividend(alice), 0);

        _distribute(10e6);
        assertApproxEqAbs(token.claimableDividend(alice), 10e6, 1);
    }

    function test_RevertWhen_ClaimNothing() public {
        vm.prank(alice);
        vm.expectRevert(bytes("nothing to claim"));
        token.claimDividend();
    }

    /// 分红不受拆分乘数影响：拆分后 claimable 不变
    function test_DividendUnaffectedBySplit() public {
        _mint(alice, 10 * ONE);
        _distribute(50e6);

        uint256 eff = block.timestamp + 1 days;
        vm.prank(op);
        token.setUIMultiplier(2 * ONE, eff, "SPLIT");
        vm.warp(eff);

        // UI 翻倍，但分红基于 raw 份额，金额不变
        assertEq(token.balanceOfUI(alice), 20 * ONE);
        assertApproxEqAbs(token.claimableDividend(alice), 50e6, 1);
    }

    /// 整除余数沉淀：派发金额无法整除时不丢钱，下次累积
    function test_IndivisibleRemainderStays() public {
        _mint(alice, 3 * ONE); // 3 股
        _distribute(10e6);     // 10/3 不整除
        uint256 c1 = token.claimableDividend(alice);
        _distribute(5e6);
        uint256 c2 = token.claimableDividend(alice);
        // 两次合计应接近 15e6（误差为整除截断，且单调递增）
        assertGt(c2, c1);
        assertLe(c2, 15e6);
        assertGe(c2, 15e6 - 10); // 截断误差极小
    }
}
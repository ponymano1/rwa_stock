// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Base.t.sol";

contract SystemSafetyTest is Base {
    /* ───────── 偿付 ───────── */

    function test_IsSolventTrueWhenBacked() public {
        _mint(alice, 10 * ONE);
        assertTrue(token.isSolvent());
    }

    function test_CustodySharesView() public view {
        assertEq(token.custodyShares(), 1_000_000e18);
    }

    function test_RevertWhen_ReserveStale() public {
        _mint(alice, 10 * ONE);
        // 把储备证明时间推到过期之外
        vm.prank(admin);
        reserve.setUpdatedAt(block.timestamp - 2 days);

        // 任何依赖 _readReserve 的操作应 revert
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(token), 1000e6);
        uint256 id = token.requestMint(1000e6, 0);
        vm.stopPrank();

        vm.prank(op);
        vm.expectRevert(bytes("reserve stale"));
        token.executeMint(id, 10 * ONE, 100e18);
    }

    function test_RevertWhen_PriceStaleOnExecute() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(token), 1000e6);
        uint256 id = token.requestMint(1000e6, 0);
        vm.stopPrank();

        vm.prank(admin);
        oracle.setUpdatedAt(block.timestamp - 2 hours); // 超过 1h 新鲜度

        vm.prank(op);
        vm.expectRevert(bytes("PRICE_STALE"));
        token.executeMint(id, 10 * ONE, 100e18);
    }

    /* ───────── 暂停 ───────── */

    function test_GuardianCanPauseBlockingTransfers() public {
        _mint(alice, 10 * ONE);
        vm.prank(guardian);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(); // Pausable: EnforcedPause
        token.transfer(bob, 1 * ONE);
    }

    function test_RevertWhen_NonGuardianPauses() public {
        vm.prank(alice);
        vm.expectRevert(); // AccessControl
        token.pause();
    }

    function test_AdminUnpauseRestoresTransfers() public {
        _mint(alice, 10 * ONE);
        vm.prank(guardian);
        token.pause();
        vm.prank(admin);
        token.unpause();

        vm.prank(alice);
        token.transfer(bob, 1 * ONE);
        assertEq(token.balanceOf(bob), 1 * ONE);
    }

    function test_RevertWhen_GuardianTriesUnpause() public {
        vm.prank(guardian);
        token.pause();
        vm.prank(guardian);
        vm.expectRevert(); // unpause 需 DEFAULT_ADMIN_ROLE
        token.unpause();
    }

    /* ───────── ERC-165 ───────── */

    function test_SupportsScaledUIInterfaces() public view {
        assertTrue(token.supportsInterface(type(IScaledUIAmount).interfaceId));
        assertTrue(token.supportsInterface(type(IScaledUIAmountNewUIMultiplier).interfaceId));
        assertTrue(token.supportsInterface(type(IScaledUIAmountConversion).interfaceId));
        assertTrue(token.supportsInterface(type(IScaledUIAmountBalances).interfaceId));
    }

    function test_SupportsERC165Itself() public view {
        assertTrue(token.supportsInterface(0x01ffc9a7)); // ERC-165
    }

    function test_DoesNotSupportRandomInterface() public view {
        assertFalse(token.supportsInterface(0xdeadbeef));
    }

    /* ───────── 管理权限 ───────── */

    function test_RevertWhen_NonAdminSetsOracle() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setOracle(address(0x123));
    }

    function test_RevertWhen_OrderTimeoutTooShort() public {
        vm.prank(admin);
        vm.expectRevert(bytes("too short"));
        token.setOrderTimeout(30 minutes);
    }
}
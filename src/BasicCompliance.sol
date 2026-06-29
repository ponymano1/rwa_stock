// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces.sol";

/**
 * @title 
 * @author 
 * @notice 实际生产中应替换为对接 KYC 服务商的 ERC-3643 身份注册表
 */
contract BasicCompliance is IComplianceModule, AccessControl {
    bytes32 public constant COMPLIANCE_ADMIN = keccak256("COMPLIANCE_ADMIN");

    mapping(address => bool) public isVerified;     // KYC 通过
    mapping(address => uint256) public lockedUntil; // 锁定期到期时间戳
    mapping(address => bool) public isFrozen;       // 制裁/冻结

    event VerifiedSet(address indexed account, bool verified);
    event LockSet(address indexed account, uint256 until);
    event FrozenSet(address indexed account, bool frozen);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ADMIN, admin);
    }

    function setVerified(address account, bool v) external onlyRole(COMPLIANCE_ADMIN) {
        isVerified[account] = v;
        emit VerifiedSet(account, v);
    }

    function setLock(address account, uint256 until) external onlyRole(COMPLIANCE_ADMIN) {
        lockedUntil[account] = until;
        emit LockSet(account, until);
    }

    function setFrozen(address account, bool f) external onlyRole(COMPLIANCE_ADMIN) {
        isFrozen[account] = f;
        emit FrozenSet(account, f);
    }

    function canReceive(address to) public view override returns (bool) {
        return isVerified[to] && !isFrozen[to];
    }

    function canTransfer(address from, address to, uint256 /*amount*/)
        external view override returns (bool)
    {
        if (isFrozen[from] || isFrozen[to]) return false;
        if (!isVerified[from] || !isVerified[to]) return false;
        if (block.timestamp < lockedUntil[from]) return false; // 发送方仍在锁定期
        return true;
    }
}
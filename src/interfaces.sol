// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* ───────────────────────── ERC-8056 核心（必须） ───────────────────────── */
interface IScaledUIAmount {
    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);
    event TransferWithUIAmount(address indexed from, address indexed to, uint256 amount, uint256 uiAmount);
    /// @notice 当前生效的 UI 乘数（18 位，1e18 = 1.0）
    function uiMultiplier() external view returns (uint256);
}

/* ──────────────────── ERC-8056 待生效乘数扩展（必须） ──────────────────── */
interface IScaledUIAmountNewUIMultiplier {
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
}

/* ────────────────────── ERC-8056 余额扩展（可选） ────────────────────── */
interface IScaledUIAmountBalances {
    function balanceOfUI(address account) external view returns (uint256);
    function totalSupplyUI() external view returns (uint256);
}

/* ────────────────────── ERC-8056 转换扩展（可选） ────────────────────── */
interface IScaledUIAmountConversion {
    function toUIAmount(uint256 rawAmount) external view returns (uint256);
    function fromUIAmount(uint256 uiAmount) external view returns (uint256);
}

/* ───────────────────────── 合规模块接口 ───────────────────────── */
interface IComplianceModule {
    /// @notice 转账前校验；铸造/销毁时由主合约单独判定，不调用此函数
    function canTransfer(address from, address to, uint256 amount) external view returns (bool);
    /// @notice 申购接收方是否允许持有（KYC / 合格投资者 / 地域）
    function canReceive(address to) external view returns (bool);
}

/* ───────────────────────── 股价预言机接口 ───────────────────────── */
interface IStockOracle {
    /// @return price 18 位精度股价（USDC 计价）
    /// @return updatedAt 价格时间戳
    /// @return marketOpen 当前是否开市
    function getPrice() external view returns (uint256 price, uint256 updatedAt, bool marketOpen);
}

/* ───────────────────────── 储备证明预言机接口 ───────────────────────── */
interface IReserveOracle {
    /// @return shares 托管账户中链下可证明的真实股票数量（18 位）
    /// @return updatedAt 证明时间戳
    function getCustodyShares() external view returns (uint256 shares, uint256 updatedAt);
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/interfaces.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract MockStockOracle is IStockOracle {
    uint256 public price;
    uint256 public updatedAt;
    bool public marketOpen;

    constructor(uint256 p, bool open) {
        price = p;
        marketOpen = open;
        updatedAt = block.timestamp;
    }
    function setPrice(uint256 p) external { price = p; updatedAt = block.timestamp; }
    function setMarketOpen(bool open) external { marketOpen = open; }
    function setUpdatedAt(uint256 t) external { updatedAt = t; }

    function getPrice() external view override returns (uint256, uint256, bool) {
        return (price, updatedAt, marketOpen);
    }
}

contract MockReserveOracle is IReserveOracle {
    uint256 public shares;
    uint256 public updatedAt;

    constructor(uint256 s) {
        shares = s;
        updatedAt = block.timestamp;
    }
    function setShares(uint256 s) external { shares = s; updatedAt = block.timestamp; }
    function setUpdatedAt(uint256 t) external { updatedAt = t; }

    function getCustodyShares() external view override returns (uint256, uint256) {
        return (shares, updatedAt);
    }
}
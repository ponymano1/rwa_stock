# StockRWAToken

**语言:** [English](./README.md) | **简体中文**

一套代币化股票(RWA)智能合约。每枚代币对应一份托管在链下的真实股票。底层的原始份额(raw shares)走标准 ERC-20(对 DeFi 友好),并在其上叠加三套相互独立的机制,以应对股票的现实特性:**公司行动拆分**、**现金分红**、**交易结算锁定**。

> **偿付不变量:** `totalSupply() * uiMultiplier() / 1e18 <= custodyShares`
> **锁定不变量:** `locked[user] <= balanceOf(user)`

---

## 合约文件

| 文件 | 作用 |
|------|------|
| `StockRWAToken.sol` | 主代币。ERC-20 + ERC-8056 + 分红 + 锁定 + 一级市场。 |
| `interfaces.sol` | ERC-8056(`IScaledUIAmount*`)、合规、股价预言机、储备证明预言机接口。 |
| `BasicCompliance.sol` | 参考合规模块(KYC / 冻结 / 锁定期)。生产环境应替换为 ERC-3643 身份注册表。 |

---

## 设计概览

合约只有一个唯一真相来源——**原始份额余额**(`balanceOf`)——并在其上投射三个正交的关注点。它们从不修改同一份状态,从而保证账务可审计。

### 1. 拆分层 —— ERC-8056 UI 乘数(纯展示)

正拆与反拆通过一个**展示乘数**处理,而非铸造或销毁。原始余额保持不变,乘数只改变用户**看到**的数量。

- `uiMultiplier()` 是当前生效乘数。新值通过 `setUIMultiplier(newMultiplier, effectiveAt, reason)` 排程,且**未来生效**,对应真实公司行动的记录日/生效日惯例,让集成方提前感知。
- `toUIAmount` / `fromUIAmount` 在原始份额与展示份额之间换算。
- 该层**价值中性**:2 拆 1 会让展示数量翻倍,但不改变任何人的经济权益。
- 排程拆分时会做前瞻性偿付断言,任何会破坏托管不变量的乘数都会被拒绝。

### 2. 分红层 —— 累积指数(真实增值,pull-based)

现金分红通过 **O(1) 累积指数**模式发放,独立于乘数。

- 运营商调用 `distributeDividend(usdcAmount)`,只推进一个全局 `dividendIndex`,没有逐持有人循环。
- 每个持有人的应得额按 `balanceOf` 累积,并在转账钩子里、余额变动之前惰性结算。
- 持有人通过 `claimDividend()` 主动提取(pull-based)。
- 由于累积基于 `balanceOf`——**包含锁定份额**——分红始终归真实受益人,即使其份额因挂单被冻结也不例外。

### 3. 锁定层 —— 结算冻结(份额留在钱包内)

为支持撮合交易所,份额可以**原地冻结**而非托管进合约。锁定份额仍留在用户 `balanceOf` 内,因此分红照常累积、拆分对持有人透明。

- `lock(user, amount)` / `unlock(user, amount)` 由交易所结算引擎(`SETTLEMENT_ROLE`)在下单/撤单时调用。
- `freeBalanceOf(user)` = `balanceOf - locked`。**任何用户自发的转账只能动用未锁定余额**,由 `_update` 顶部的单一校验强制执行。
- `settleTransfer` / `settleTransferBatch` 把**锁定的**份额从卖方过户给买方(即 DvP 的 token 腿)。它们翻转一个瞬时 `_settling` 标志以绕过未锁定校验,但仍会对买方执行完整合规检查。
- 由于赎回本质上是内部转账,**用户无法赎回正挂单中被锁定的份额**——无需额外代码。

---

## 一级市场(申购 / 赎回)

采用两段式 **请求 / 执行** 流程,带滑点保护与偿付断言,因为实际的买入/卖出发生在链下。

- **申购:** `requestMint(usdc, minUIOut)` 锁定 USDC → 运营商链下买股 → `executeMint(orderId, filledStocks, fillPrice)` 在断言偿付后铸造原始份额(向下取整更安全)。
- **赎回:** `requestRedeem(shares, minUSDCOut)` 把份额转入合约托管(仅限未锁定余额)→ 运营商链下卖股 → `executeRedeem(...)` 销毁份额并支付 USDC。
- `cancelOrder(orderId)` 原路退款。用户在 `orderTimeout` 之后可取消;运营商可随时取消(如停牌)。

---

## 角色

| 角色 | 权限 |
|------|------|
| `DEFAULT_ADMIN_ROLE` | 配置模块/预言机、设置超时、解除暂停、授予角色。 |
| `OPERATOR_ROLE` | 执行铸销、排程拆分、发放分红。 |
| `GUARDIAN_ROLE` | 紧急 `pause()`。 |
| `SETTLEMENT_ROLE` | 锁定/解锁,以及交割(过户)锁定份额。 |

> `SETTLEMENT_ROLE` **不**在构造函数中授予。部署后,admin 须调用 `grantRole(SETTLEMENT_ROLE, 交易所结算地址)`。它应与 `OPERATOR_ROLE` 分离——最好是独立热钱包或多签——因为它能搬动用户的锁定份额。

---

## 安全与预言机

- **储备证明预言机(PoR):** 每次铸造、每次排程拆分都会断言展示总股数不超过托管股数。过期证明(`> RESERVE_STALE_AFTER`)会被拒绝。
- **股价预言机:** 铸销执行要求当前开市且价格新鲜(`<= PRICE_STALE_AFTER`)。
- **合规:** 普通转账双向校验;铸造校验接收方;销毁放行。生产环境替换为 ERC-3643 注册表。
- **Pausable + ReentrancyGuard** 保护转账钩子及所有对外的价值转移函数。

> 若预言机未配置,合约会退化为宽松行为,**仅供测试**。生产环境必须配置全部预言机。

---

## 部署后清单

1. 向交易所结算钱包 `grantRole(SETTLEMENT_ROLE, …)`(与运营商分离)。
2. 通过 admin setter 配置合规模块与两个预言机。
3. 决定结算的**现金腿**:`settleTransfer` 只处理 token 腿。链上 USDC 应把两条腿包进同一笔原子交易(推荐做一个原子的 `settleDvP(seller, buyer, shares, usdc)`)。若 USDC 由平台链下托管,则以 `SettledTransfer` 事件作为内部现金入账的触发条件。

---

## 许可

MIT
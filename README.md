# StockRWAToken

**Language:** **English** | [简体中文](./README.zh-CN.md)

A tokenized-equity (RWA) smart-contract suite. Each token represents one share of an underlying real-world stock held in custody. Raw shares move as a standard ERC-20 (DeFi-friendly), while three independent mechanisms layer on top of it to handle the realities of equities: **corporate-action splits**, **cash dividends**, and **trade settlement locks**.

> **Solvency invariant:** `totalSupply() * uiMultiplier() / 1e18 <= custodyShares`
> **Lock invariant:** `locked[user] <= balanceOf(user)`

---

## Contracts

| File | Purpose |
|------|---------|
| `StockRWAToken.sol` | The main token. ERC-20 + ERC-8056 + dividends + locking + primary market. |
| `interfaces.sol` | ERC-8056 (`IScaledUIAmount*`), compliance, price oracle, and reserve oracle interfaces. |
| `BasicCompliance.sol` | A reference compliance module (KYC / freeze / lockup). Replace with an ERC-3643 identity registry in production. |

---

## Design Overview

The contract keeps a single source of truth — the **raw share balance** (`balanceOf`) — and projects three orthogonal concerns on top of it. They never mutate the same state, which keeps the accounting auditable.

### 1. Split layer — ERC-8056 UI multiplier (display only)

Stock splits and reverse splits are handled by a **display multiplier**, not by minting or burning. Raw balances stay fixed; the multiplier rescales what users *see*.

- `uiMultiplier()` is the live multiplier. A new value is scheduled with `setUIMultiplier(newMultiplier, effectiveAt, reason)` and **takes effect in the future**, mirroring the record-date / effective-date convention of real corporate actions so integrators can prepare.
- `toUIAmount` / `fromUIAmount` convert between raw shares and displayed shares.
- This layer is **value-neutral**: a 2-for-1 split doubles the displayed count without changing anyone's economic stake.
- Scheduling a split runs a forward-looking solvency assertion, so a multiplier that would break the custody invariant is rejected.

### 2. Dividend layer — cumulative index (real value, pull-based)

Cash dividends are distributed via an **O(1) cumulative-index** pattern, independent of the multiplier.

- The operator calls `distributeDividend(usdcAmount)`; this only bumps a global `dividendIndex`. No per-holder loop.
- Each holder's entitlement accrues against `balanceOf` and is settled lazily inside the transfer hook before any balance change.
- Holders withdraw with `claimDividend()` (pull-based).
- Because accrual is based on `balanceOf` — which **includes locked shares** — dividends always flow to the true beneficial owner, even while their shares are frozen for a pending trade.

### 3. Lock layer — settlement freeze (shares stay in the wallet)

To support an order-book exchange, shares can be **frozen in place** rather than escrowed into the contract. Locked shares remain in the user's `balanceOf`, so dividends keep accruing and splits stay transparent to the holder.

- `lock(user, amount)` / `unlock(user, amount)` are called by the exchange's settlement engine (`SETTLEMENT_ROLE`) when an order is placed / cancelled.
- `freeBalanceOf(user)` = `balanceOf - locked`. **Every user-initiated transfer can only spend the free balance**, enforced by a single guard at the top of `_update`.
- `settleTransfer` / `settleTransferBatch` move *locked* shares from seller to buyer (the token leg of delivery-vs-payment). They flip a transient `_settling` flag to bypass the free-balance guard, but still run the full compliance check on the buyer.
- Because redemption is just an internal transfer, **users cannot redeem shares that are locked in an open order** — no extra code needed.

---

## Primary Market (mint / redeem)

A two-step **request / execute** flow with slippage protection and solvency assertions, since the actual share purchase/sale happens off-chain.

- **Mint:** `requestMint(usdc, minUIOut)` locks USDC → operator buys shares off-chain → `executeMint(orderId, filledStocks, fillPrice)` mints raw shares (rounded down for safety) after asserting solvency.
- **Redeem:** `requestRedeem(shares, minUSDCOut)` moves shares into custody (free-balance only) → operator sells off-chain → `executeRedeem(...)` burns the shares and pays USDC.
- `cancelOrder(orderId)` refunds the original asset. Users may cancel after `orderTimeout`; the operator may cancel anytime (e.g. trading halt).

---

## Roles

| Role | Capabilities |
|------|--------------|
| `DEFAULT_ADMIN_ROLE` | Wire up modules/oracles, set timeouts, unpause, grant roles. |
| `OPERATOR_ROLE` | Execute mint/redeem, schedule splits, distribute dividends. |
| `GUARDIAN_ROLE` | Emergency `pause()`. |
| `SETTLEMENT_ROLE` | Lock/unlock and settle (deliver) locked shares. |

> `SETTLEMENT_ROLE` is **not** granted in the constructor. After deployment, the admin must `grantRole(SETTLEMENT_ROLE, exchangeSettlementAddress)`. Keep it separate from `OPERATOR_ROLE` — ideally a dedicated hot wallet or multisig — because it can move users' locked shares.

---

## Safety & Oracles

- **Reserve oracle (Proof-of-Reserve):** every mint and every scheduled split asserts that displayed total shares never exceed custody shares. Stale proofs (`> RESERVE_STALE_AFTER`) are rejected.
- **Price oracle:** mint/redeem execution requires an open market and a fresh price (`<= PRICE_STALE_AFTER`).
- **Compliance:** transfers are checked both ways; mints check the receiver; burns pass through. Swap in an ERC-3643 registry for production.
- **Pausable + ReentrancyGuard** protect the transfer hook and all external value-moving functions.

> If an oracle is left unset, the contract degrades to permissive behaviour for testing only. **Production must configure all oracles.**

---

## Post-deployment checklist

1. `grantRole(SETTLEMENT_ROLE, …)` to the exchange settlement wallet (separate from operator).
2. Configure the compliance module and both oracles via the admin setters.
3. Decide the **cash leg** of settlement: `settleTransfer` only handles the token leg. For on-chain USDC, wrap both legs into one atomic transaction (an atomic `settleDvP(seller, buyer, shares, usdc)` is recommended). For off-chain USDC custody, treat the `SettledTransfer` event as the trigger for internal cash booking.

---

## License

MIT
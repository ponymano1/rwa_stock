// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "./interfaces.sol";

/**
 * @title StockRWAToken
 * @notice 代币化股票：raw 份额走标准 ERC-20（DeFi 友好），
 *         拆分用 ERC-8056 乘数（纯展示），分红用独立累积指数（真实增值）。
 *
 * 不变量（偿付）：totalSupply() * uiMultiplier() / 1e18 <= custodyShares
 */
contract StockRWAToken is
    ERC20,
    ERC165,
    Pausable,
    ReentrancyGuard,
    AccessControl,
    IScaledUIAmount,
    IScaledUIAmountNewUIMultiplier,
    IScaledUIAmountBalances,
    IScaledUIAmountConversion
{
    using SafeERC20 for IERC20;

    /* ───────────── 角色 ───────────── */
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE"); // 执行铸销、拆分、分红
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE"); // 紧急暂停

    /* ───────────── 常量 ───────────── */
    uint256 private constant MULTIPLIER_ONE = 1e18; // 乘数与指数缩放基准
    uint256 public constant PRICE_STALE_AFTER = 1 hours;   // 股价新鲜度
    uint256 public constant RESERVE_STALE_AFTER = 1 days;  // PoR 新鲜度

    /* ───────────── 外部依赖 ───────────── */
    IERC20 public immutable usdc;            // 结算与分红货币（假定 6 位）
    IComplianceModule public compliance;
    IStockOracle public oracle;
    IReserveOracle public reserveOracle;

    /* ───────────── 拆分层状态（ERC-8056） ───────────── */
    uint256 private _uiMultiplier = MULTIPLIER_ONE;     // 旧值
    uint256 private _newUIMultiplier = MULTIPLIER_ONE;  // 新值
    uint256 private _effectiveAt;                       // 新值生效时间

    /* ───────────── 分红层状态（累积指数） ───────────── */
    // dividendIndex: 自部署以来，每持有 1e18 份额累计可领取的 USDC（6 位）
    uint256 public dividendIndex;
    mapping(address => uint256) public lastIndex;       // 用户上次结算时的指数
    mapping(address => uint256) public dividendOwed;    // 已结算但未提取的 USDC

    /* ───────────── 一级市场订单 ───────────── */
    enum OrderType { MINT, REDEEM }
    enum OrderStatus { PENDING, FILLED, CANCELLED }

    struct Order {
        address user;
        OrderType orderType;
        OrderStatus status;
        uint256 inputAmount;   // MINT: 锁定的 USDC；REDEEM: 锁定的 raw 份额
        uint256 minOutput;     // MINT: 最少 UI 代币；REDEEM: 最少 USDC
        uint256 createdAt;
    }

    uint256 public nextOrderId = 1;
    uint256 public orderTimeout = 3 days; // 超时可取消
    mapping(uint256 => Order) public orders;

    /* ───────────── 事件 ───────────── */
    event MintRequested(uint256 indexed orderId, address indexed user, uint256 usdcAmount, uint256 minUIOut);
    event MintExecuted(uint256 indexed orderId, address indexed user, uint256 shares, uint256 uiTokens, uint256 fillPrice);
    event RedeemRequested(uint256 indexed orderId, address indexed user, uint256 shares, uint256 minUSDCOut);
    event RedeemExecuted(uint256 indexed orderId, address indexed user, uint256 shares, uint256 usdcOut, uint256 fillPrice);
    event OrderCancelled(uint256 indexed orderId);
    event DividendDistributed(uint256 usdcAmount, uint256 newIndex);
    event DividendClaimed(address indexed user, uint256 usdcAmount);
    event ComplianceModuleUpdated(address module);
    event OracleUpdated(address oracle);
    event ReserveOracleUpdated(address oracle);

    /* ───────────── 构造 ───────────── */
    constructor(
        string memory name_,
        string memory symbol_,
        address usdc_,
        address admin_,
        address operator_,
        address guardian_
    ) ERC20(name_, symbol_) {
        require(usdc_ != address(0), "USDC=0");
        usdc = IERC20(usdc_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, operator_);
        _grantRole(GUARDIAN_ROLE, guardian_);
        _effectiveAt = block.timestamp; // 初始乘数立即有效
    }

    /* ════════════════════════════════════════════════════════════════
       拆分层（ERC-8056）：纯展示、价值中性、延迟生效
       ════════════════════════════════════════════════════════════════ */

    /// @notice 当前生效乘数；超过 _effectiveAt 后自动切换到新值
    function uiMultiplier() public view override returns (uint256) {
        return block.timestamp >= _effectiveAt ? _newUIMultiplier : _uiMultiplier;
    }

    function newUIMultiplier() external view override returns (uint256) {
        return _newUIMultiplier;
    }

    function effectiveAt() external view override returns (uint256) {
        return _effectiveAt;
    }

    /**
     * @notice 安排一次拆分。reason 应为 "SPLIT" / "REVERSE_SPLIT"。
     * @dev    必须未来生效，让集成方提前感知（对应记录日/生效日）。
     *         先把"当前已结算到的乘数"固化为旧值，再设新值。
     *         同时断言新乘数下系统仍偿付。
     */
    function setUIMultiplier(uint256 newMultiplier_, uint256 effectiveAt_, string calldata /*reason*/)
        external
        onlyRole(OPERATOR_ROLE)
    {
        require(newMultiplier_ > 0, "multiplier=0");
        require(effectiveAt_ > block.timestamp, "must be future");

        uint256 oldEffective;
        // 把"此刻实际生效的乘数"落定为旧值，避免连续排程时丢失中间状态
        uint256 nowMultiplier = uiMultiplier();
        _uiMultiplier = nowMultiplier;
        oldEffective = nowMultiplier;

        _newUIMultiplier = newMultiplier_;
        _effectiveAt = effectiveAt_;

        // 偿付前瞻：生效后展示总股数不得超过托管股数
        // totalSupply()*newMultiplier/1e18 <= custodyShares
        (uint256 custody, ) = _readReserve();
        require(
            (totalSupply() * newMultiplier_) / MULTIPLIER_ONE <= custody,
            "split breaks solvency"
        );

        emit UIMultiplierUpdated(oldEffective, newMultiplier_, effectiveAt_);
    }

    /* ───────────── ERC-8056 转换/余额扩展 ───────────── */

    /// @dev raw → UI，向下取整（�VarChar向系统安全方向）
    function toUIAmount(uint256 rawAmount) public view override returns (uint256) {
        return (rawAmount * uiMultiplier()) / MULTIPLIER_ONE;
    }

    /// @dev UI → raw，向下取整
    function fromUIAmount(uint256 uiAmount) public view override returns (uint256) {
        return (uiAmount * MULTIPLIER_ONE) / uiMultiplier();
    }

    function balanceOfUI(address account) external view override returns (uint256) {
        return toUIAmount(balanceOf(account));
    }

    function totalSupplyUI() external view override returns (uint256) {
        return toUIAmount(totalSupply());
    }

    /* ════════════════════════════════════════════════════════════════
       分红层：累积指数，pull-based，独立于乘数
       ════════════════════════════════════════════════════════════════ */

    /**
     * @notice 运营商把收到的（税后）现金分红注入并按 raw 份额比例分配。
     * @dev    O(1)：只更新全局指数。USDC 必须先转入本合约。
     */
    function distributeDividend(uint256 usdcAmount)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        uint256 supply = totalSupply();
        require(supply > 0, "no shares");
        require(usdcAmount > 0, "amount=0");

        // 收款（运营商需先 approve）
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // 每 1e18 份额新增可领 USDC。乘 1e18 后整除，余数留在合约（下次累积）
        dividendIndex += (usdcAmount * MULTIPLIER_ONE) / supply;

        emit DividendDistributed(usdcAmount, dividendIndex);
    }

    /// @notice 某账户当前可领取的 USDC（含已结算未提取）
    function claimableDividend(address user) public view returns (uint256) {
        return dividendOwed[user] + _accrued(user);
    }

    /// @dev 自上次结算以来新累积的分红
    function _accrued(address user) internal view returns (uint256) {
        uint256 delta = dividendIndex - lastIndex[user];
        if (delta == 0) return 0;
        // delta 单位：USDC*1e18/份额；balanceOf*delta/1e18 = USDC
        return (balanceOf(user) * delta) / MULTIPLIER_ONE;
    }

    /// @dev 把新累积分红落账到 dividendOwed，并推进 lastIndex。
    ///      必须在任何改变 balanceOf 的操作"之前"调用。
    function _settle(address user) internal {
        if (user == address(0)) return; // 铸造/销毁的 0 地址不参与
        dividendOwed[user] += _accrued(user);
        lastIndex[user] = dividendIndex;
    }

    /// @notice 提取分红 USDC
    function claimDividend() external nonReentrant returns (uint256 amount) {
        _settle(msg.sender);
        amount = dividendOwed[msg.sender];
        require(amount > 0, "nothing to claim");
        dividendOwed[msg.sender] = 0;
        usdc.safeTransfer(msg.sender, amount);
        emit DividendClaimed(msg.sender, amount);
    }

    /* ════════════════════════════════════════════════════════════════
       转账钩子：合规校验 + 分红结算 + ERC-8056 事件
       这是三套机制的交汇点，顺序至关重要。
       ════════════════════════════════════════════════════════════════ */
    function _update(address from, address to, uint256 amount)
        internal
        override
        whenNotPaused
    {
        // 1) 合规：普通转账双向校验；铸造(from=0)校验接收方；销毁(to=0)放行
        if (from != address(0) && to != address(0)) {
            require(address(compliance) == address(0) || compliance.canTransfer(from, to, amount), "COMPLIANCE_FAIL");
        } else if (from == address(0)) {
            require(address(compliance) == address(0) || compliance.canReceive(to), "RECEIVER_NOT_ALLOWED");
        }

        // 2) 先结算双方分红（在余额变动前，按旧余额结算，避免错配）
        _settle(from);
        _settle(to);

        // 3) 移动份额
        super._update(from, to, amount);

        // 4) ERC-8056 可选事件（展示 UI 数量）
        emit TransferWithUIAmount(from, to, amount, toUIAmount(amount));
    }

    /* ════════════════════════════════════════════════════════════════
       一级市场：请求/执行两段式，含滑点保护与偿付断言
       ════════════════════════════════════════════════════════════════ */

    /**
     * @notice 用户申购：锁定 USDC，等待运营商按实际成交价执行。
     * @param usdcAmount 锁定的 USDC
     * @param minUIOut   可接受的最小 UI 代币（股）数，低于则可取消退款
     */
    function requestMint(uint256 usdcAmount, uint256 minUIOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 orderId)
    {
        require(usdcAmount > 0, "amount=0");
        require(address(compliance) == address(0) || compliance.canReceive(msg.sender), "NOT_ALLOWED");

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        orderId = nextOrderId++;
        orders[orderId] = Order({
            user: msg.sender,
            orderType: OrderType.MINT,
            status: OrderStatus.PENDING,
            inputAmount: usdcAmount,
            minOutput: minUIOut,
            createdAt: block.timestamp
        });
        emit MintRequested(orderId, msg.sender, usdcAmount, minUIOut);
    }

    /**
     * @notice 运营商执行申购：链下已用锁定的 USDC 买入 filledStocks 股。
     * @param filledStocks 实际买到的股数（18 位，等于 UI 代币数）
     * @param fillPrice    实际成交均价（仅作记录/事件）
     * @dev    UI 代币数 = filledStocks；raw 份额 = UI/乘数（向下取整，少铸更安全）。
     */
    function executeMint(uint256 orderId, uint256 filledStocks, uint256 fillPrice)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        Order storage o = orders[orderId];
        require(o.status == OrderStatus.PENDING && o.orderType == OrderType.MINT, "bad order");
        _requireMarketOpen();

        uint256 uiTokens = filledStocks;
        require(uiTokens >= o.minOutput, "SLIPPAGE");

        // UI → raw 份额，向下取整
        uint256 shares = fromUIAmount(uiTokens);
        require(shares > 0, "zero shares");

        // 偿付断言：铸造后展示总股数不得超过托管股数
        (uint256 custody, ) = _readReserve();
        require(
            ((totalSupply() + shares) * uiMultiplier()) / MULTIPLIER_ONE <= custody,
            "SOLVENCY"
        );

        o.status = OrderStatus.FILLED;

        // 锁定的 USDC 转给运营商用于结算买入（实际架构可改为多签金库）
        usdc.safeTransfer(msg.sender, o.inputAmount);

        _mint(o.user, shares); // 触发 _update：合规校验接收方 + 分红结算
        emit MintExecuted(orderId, o.user, shares, uiTokens, fillPrice);
    }

    /**
     * @notice 用户赎回：锁定 raw 份额，等待运营商卖股回款。
     * @param shareAmount raw 份额
     * @param minUSDCOut  可接受的最小 USDC 回款
     */
    function requestRedeem(uint256 shareAmount, uint256 minUSDCOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 orderId)
    {
        require(shareAmount > 0, "amount=0");
        // 把份额从用户转入合约托管（触发分红结算），赎回挂起期间不再计分红
        _transfer(msg.sender, address(this), shareAmount);

        orderId = nextOrderId++;
        orders[orderId] = Order({
            user: msg.sender,
            orderType: OrderType.REDEEM,
            status: OrderStatus.PENDING,
            inputAmount: shareAmount,
            minOutput: minUSDCOut,
            createdAt: block.timestamp
        });
        emit RedeemRequested(orderId, msg.sender, shareAmount, minUSDCOut);
    }

    /**
     * @notice 运营商执行赎回：链下卖出对应股数，回款 usdcOut。
     * @param soldStocks 链下卖出的 UI 股数（用于核对/事件）
     * @param fillPrice  实际成交均价
     * @dev    运营商需先把 usdcOut 转入或 approve 给合约。
     */
    function executeRedeem(uint256 orderId, uint256 soldStocks, uint256 fillPrice, uint256 usdcOut)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        Order storage o = orders[orderId];
        require(o.status == OrderStatus.PENDING && o.orderType == OrderType.REDEEM, "bad order");
        _requireMarketOpen();
        require(usdcOut >= o.minOutput, "SLIPPAGE");

        o.status = OrderStatus.FILLED;

        // 销毁托管中的份额
        _burn(address(this), o.inputAmount);

        // 回款打给用户
        usdc.safeTransferFrom(msg.sender, o.user, usdcOut);

        emit RedeemExecuted(orderId, o.user, o.inputAmount, usdcOut, fillPrice);
        // soldStocks 仅用于事件核对
    }

    /**
     * @notice 超时 / 停牌 / 滑点导致无法成交时取消，原路退款。
     * @dev    用户或运营商均可在超时后调用；运营商可随时取消（停牌场景）。
     */
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        require(o.status == OrderStatus.PENDING, "not pending");
        bool isOwnerOrOp = (msg.sender == o.user) || hasRole(OPERATOR_ROLE, msg.sender);
        require(isOwnerOrOp, "not authorized");
        if (msg.sender == o.user) {
            require(block.timestamp >= o.createdAt + orderTimeout, "not timed out");
        }

        o.status = OrderStatus.CANCELLED;

        if (o.orderType == OrderType.MINT) {
            usdc.safeTransfer(o.user, o.inputAmount);          // 退 USDC
        } else {
            _transfer(address(this), o.user, o.inputAmount);   // 退份额
        }
        emit OrderCancelled(orderId);
    }

    /* ════════════════════════════════════════════════════════════════
       储备证明 / 偿付
       ════════════════════════════════════════════════════════════════ */
    function _readReserve() internal view returns (uint256 shares, uint256 updatedAt) {
        if (address(reserveOracle) == address(0)) {
            // 未配置时返回极大值以不阻断（测试场景）；生产环境应强制配置
            return (type(uint256).max, block.timestamp);
        }
        (shares, updatedAt) = reserveOracle.getCustodyShares();
        require(block.timestamp - updatedAt <= RESERVE_STALE_AFTER, "reserve stale");
    }

    function custodyShares() external view returns (uint256 shares) {
        (shares, ) = _readReserve();
    }

    /// @notice 当前是否偿付：展示总股数 <= 托管股数
    function isSolvent() external view returns (bool) {
        (uint256 custody, ) = _readReserve();
        return (totalSupply() * uiMultiplier()) / MULTIPLIER_ONE <= custody;
    }

    function _requireMarketOpen() internal view {
        if (address(oracle) == address(0)) return; // 未配置则跳过（测试）
        (, uint256 updatedAt, bool open) = oracle.getPrice();
        require(open, "MARKET_CLOSED");
        require(block.timestamp - updatedAt <= PRICE_STALE_AFTER, "PRICE_STALE");
    }

    /* ════════════════════════════════════════════════════════════════
       管理
       ════════════════════════════════════════════════════════════════ */
    function setComplianceModule(address m) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = IComplianceModule(m);
        emit ComplianceModuleUpdated(m);
    }

    function setOracle(address o_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        oracle = IStockOracle(o_);
        emit OracleUpdated(o_);
    }

    function setReserveOracle(address o_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        reserveOracle = IReserveOracle(o_);
        emit ReserveOracleUpdated(o_);
    }

    function setOrderTimeout(uint256 t) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(t >= 1 hours, "too short");
        orderTimeout = t;
    }

    function pause() external onlyRole(GUARDIAN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    /* ───────────── ERC-165 ───────────── */
    function supportsInterface(bytes4 id)
        public
        view
        override(ERC165, AccessControl)
        returns (bool)
    {
        return
            id == type(IScaledUIAmount).interfaceId ||              // 0xa60bf13d
            id == type(IScaledUIAmountNewUIMultiplier).interfaceId ||
            id == type(IScaledUIAmountConversion).interfaceId ||
            id == type(IScaledUIAmountBalances).interfaceId ||
            super.supportsInterface(id);
    }
}
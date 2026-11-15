// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../library/SafeTransfer.sol";
import "../interface/IDebtToken.sol";
import "../interface/IBscPledgeOracle.sol";
import "../interface/IUniswapV2Router02.sol";
import "../multiSignature/multiSignatureClient.sol";
/* ============================================================================
 * 【学习注释 · 文件总览】PledgePool.sol —— 固定利率借贷协议的核心合约（821 行）
 *
 * 业务一句话：管理员建池锁定「利率 + 期限 + 抵押率」，放款人存稳定币、借款人存抵押物，
 * settle() 一次性撮合锁定成交额，到期 finish() 卖抵押物还本付息（或爆仓 liquidate()）。
 *
 * 池子状态机（背诵这张图，整个文件就是围绕它写的）：
 *
 *   createPoolInfo            settle()              finish()                withdraw*
 *      ┌──────┐  双方存入  ┌──────┐────────►┌──────┐  时间到   ┌────────┐ ────► 分钱
 *      │ MATCH│ ────────► │ MATCH│         │EXECUTION│──────►│ FINISH │
 *      └──────┘            └──────┘         └──────┘          └────────┘
 *         │                    │                │
 *         │ 有一方没人存        │ checkoutLiquidate 抵押物贬值
 *         ▼                    ▼
 *      ┌──────┐            ┌────────────┐
 *      │UNDONE│            │LIQUIDATION │
 *      └──────┘            └────────────┘
 *
 * 三个高频问题（面试必问）：
 * 1. 为什么存款时不铸凭证？——因为能不能成交要等 settle 才知道，先铸再退太绕
 * 2. 利息怎么算？——interest = (endTime-settleTime)/365天 × interestRate × settleAmountLend，
 *    建池时利率锁死，所以到期利息在建池那一刻就已确定（这就是"固定利率"）
 * 3. settle 谁来调？——validCall 修饰器（多签），合约里没有定时器，链上没有 cron
 * ==========================================================================*/



contract PledgePool is ReentrancyGuard, SafeTransfer, multiSignatureClient{

    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // default decimal
    uint256 constant internal calDecimal = 1e18;
    // Based on the decimal of the commission and interest
    uint256 constant internal baseDecimal = 1e8;
    uint256 public minAmount = 100e18;
    // one years
    uint256 constant baseYear = 365 days;

    enum PoolState{ MATCH, EXECUTION, FINISH, LIQUIDATION, UNDONE }
    PoolState constant defaultChoice = PoolState.MATCH;

    bool public globalPaused = false;
    // pancake swap router
    address public swapRouter;
    // receiving fee address
    address payable public feeAddress;
    // oracle address
    IBscPledgeOracle public oracle;
    // fee
    uint256 public lendFee;
    uint256 public borrowFee;

        // 每个池的基本信息
    struct PoolBaseInfo{
        uint256 settleTime;         // 结算时间
        uint256 endTime;            // 结束时间
        uint256 interestRate;       // 池的固定利率，单位是1e8 (1e8)
        uint256 maxSupply;          // 池的最大限额
        uint256 lendSupply;         // 当前实际存款的借款
        uint256 borrowSupply;       // 当前实际存款的借款
        uint256 martgageRate;       // 池的抵押率，单位是1e8 (1e8)
        address lendToken;          // 借款方代币地址 (比如 BUSD..)
        address borrowToken;        // 借款方代币地址 (比如 BTC..)
        PoolState state;            // 状态 'MATCH, EXECUTION, FINISH, LIQUIDATION, UNDONE'
        IDebtToken spCoin;          // sp_token的erc20地址 (比如 spBUSD_1..)
        IDebtToken jpCoin;          // jp_token的erc20地址 (比如 jpBTC_1..)
        uint256 autoLiquidateThreshold; // 自动清算阈值 (触发清算阈值)
    }
    // total base pool.
    PoolBaseInfo[] public poolBaseInfo;

       // 每个池的数据信息
    struct PoolDataInfo{
        uint256 settleAmountLend;       // 结算时的实际出借金额
        uint256 settleAmountBorrow;     // 结算时的实际借款金额
        uint256 finishAmountLend;       // 完成时的实际出借金额
        uint256 finishAmountBorrow;     // 完成时的实际借款金额
        uint256 liquidationAmounLend;   // 清算时的实际出借金额
        uint256 liquidationAmounBorrow; // 清算时的实际借款金额
    }
    // total data pool
    PoolDataInfo[] public poolDataInfo;

       // 借款用户信息
    struct BorrowInfo {
        uint256 stakeAmount;           // 当前借款的质押金额
        uint256 refundAmount;          // 多余的退款金额
        bool hasNoRefund;              // 默认为false，false = 未退款，true = 已退款
        bool hasNoClaim;               // 默认为false，false = 未认领，true = 已认领
    }
    // Info of each user that stakes tokens.  {user.address : {pool.index : user.borrowInfo}}
    mapping (address => mapping (uint256 => BorrowInfo)) public userBorrowInfo;

      // 借款用户信息
    struct LendInfo {
        uint256 stakeAmount;          // 当前借款的质押金额
        uint256 refundAmount;         // 超额退款金额
        bool hasNoRefund;             // 默认为false，false = 无退款，true = 已退款
        bool hasNoClaim;              // 默认为false，false = 无索赔，true = 已索赔
    }

    // Info of each user that stakes tokens.  {user.address : {pool.index : user.lendInfo}}
    mapping (address => mapping (uint256 => LendInfo)) public userLendInfo;

        // 事件
        // 存款借出事件，from是借出者地址，token是借出的代币地址，amount是借出的数量，mintAmount是生成的数量
    event DepositLend(address indexed from,address indexed token,uint256 amount,uint256 mintAmount); 
    // 借出退款事件，from是退款者地址，token是退款的代币地址，refund是退款的数量
    event RefundLend(address indexed from, address indexed token, uint256 refund); 
    // 借出索赔事件，from是索赔者地址，token是索赔的代币地址，amount是索赔的数量
    event ClaimLend(address indexed from, address indexed token, uint256 amount); 
     // 提取借出事件，from是提取者地址，token是提取的代币地址，amount是提取的数量，burnAmount是销毁的数量
    event WithdrawLend(address indexed from,address indexed token,uint256 amount,uint256 burnAmount);
    // 存款借入事件，from是借入者地址，token是借入的代币地址，amount是借入的数量，mintAmount是生成的数量
    event DepositBorrow(address indexed from,address indexed token,uint256 amount,uint256 mintAmount); 
     // 借入退款事件，from是退款者地址，token是退款的代币地址，refund是退款的数量
    event RefundBorrow(address indexed from, address indexed token, uint256 refund);
    // 借入索赔事件，from是索赔者地址，token是索赔的代币地址，amount是索赔的数量
    event ClaimBorrow(address indexed from, address indexed token, uint256 amount); 
    // 提取借入事件，from是提取者地址，token是提取的代币地址，amount是提取的数量，burnAmount是销毁的数量
    event WithdrawBorrow(address indexed from,address indexed token,uint256 amount,uint256 burnAmount); 
    // 交换事件，fromCoin是交换前的币种地址，toCoin是交换后的币种地址，fromValue是交换前的数量，toValue是交换后的数量
    event Swap(address indexed fromCoin,address indexed toCoin,uint256 fromValue,uint256 toValue); 
    // 紧急借入提取事件，from是提取者地址，token是提取的代币地址，amount是提取的数量
    event EmergencyBorrowWithdrawal(address indexed from, address indexed token, uint256 amount); 
     // 紧急借出提取事件，from是提取者地址，token是提取的代币地址，amount是提取的数量
    event EmergencyLendWithdrawal(address indexed from, address indexed token, uint256 amount);
    // 状态改变事件，pid是项目id，beforeState是改变前的状态，afterState是改变后的状态
    event StateChange(uint256 indexed pid, uint256 indexed beforeState, uint256 indexed afterState); 
     // 设置费用事件，newLendFee是新的借出费用，newBorrowFee是新的借入费用
    event SetFee(uint256 indexed newLendFee, uint256 indexed newBorrowFee);
    // 设置交换路由器地址事件，oldSwapAddress是旧的交换地址，newSwapAddress是新的交换地址
    event SetSwapRouterAddress(address indexed oldSwapAddress, address indexed newSwapAddress); 
     // 设置费用地址事件，oldFeeAddress是旧的费用地址，newFeeAddress是新的费用地址
    event SetFeeAddress(address indexed oldFeeAddress, address indexed newFeeAddress);
    // 设置最小数量事件，oldMinAmount是旧的最小数量，newMinAmount是新的最小数量
    event SetMinAmount(uint256 indexed oldMinAmount, uint256 indexed newMinAmount); 

    constructor(
        address _oracle,
        address _swapRouter,
        address payable _feeAddress,
        address _multiSignature
    ) multiSignatureClient(_multiSignature) public {
        require(_oracle != address(0), "Is zero address");
        require(_swapRouter != address(0), "Is zero address");
        require(_feeAddress != address(0), "Is zero address");

        oracle = IBscPledgeOracle(_oracle);
        swapRouter = _swapRouter;
        feeAddress = _feeAddress;
        lendFee = 0;
        borrowFee = 0;
    }

    /**
     * @dev Set the lend fee and borrow fee
     * @notice Only allow administrators to operate
     */
    function setFee(uint256 _lendFee,uint256 _borrowFee) validCall external{
        lendFee = _lendFee;
        borrowFee = _borrowFee;
        emit SetFee(_lendFee, _borrowFee);
    }

    /**
     * @dev Set swap router address, example pancakeswap or babyswap..
     * @notice Only allow administrators to operate
     */
    function setSwapRouterAddress(address _swapRouter) validCall external{
        require(_swapRouter != address(0), "Is zero address");
        emit SetSwapRouterAddress(swapRouter,_swapRouter);
        swapRouter = _swapRouter;
    }

    /**
     * @dev Set up the address to receive the handling fee
     * @notice Only allow administrators to operate
     */
    function setFeeAddress(address payable _feeAddress) validCall external {
        require(_feeAddress != address(0), "Is zero address");
        emit SetFeeAddress(feeAddress, _feeAddress);
        feeAddress = _feeAddress;
    }

    /**
     * @dev Set the min amount
     */
    function setMinAmount(uint256 _minAmount) validCall external {
        emit SetMinAmount(minAmount,_minAmount);
        minAmount = _minAmount;
    }


     /**
     * @dev Query pool length
     */
    function poolLength() external view returns (uint256) {
        return poolBaseInfo.length;
    }

    /**
     * @dev 创建一个新的借贷池。函数接收一系列参数，包括结算时间、结束时间、利率、最大供应量、抵押率、借款代币、借出代币、SP代币、JP代币和自动清算阈值。
     *  Can only be called by the owner.
     */
    function createPoolInfo(uint256 _settleTime,  uint256 _endTime, uint64 _interestRate,
                        uint256 _maxSupply, uint256 _martgageRate, address _lendToken, address _borrowToken,
                    address _spToken, address _jpToken, uint256 _autoLiquidateThreshold) public validCall{
        // 检查是否已设置token ...
        // 需要结束时间大于结算时间
        require(_endTime > _settleTime, "createPool:end time grate than settle time");
        // 需要_jpToken不是零地址
        require(_jpToken != address(0), "createPool:is zero address");
        // 需要_spToken不是零地址
        require(_spToken != address(0), "createPool:is zero address");

        // 推入基础池信息
        poolBaseInfo.push(PoolBaseInfo({
            settleTime: _settleTime,
            endTime: _endTime,
            interestRate: _interestRate,
            maxSupply: _maxSupply,
            lendSupply:0,
            borrowSupply:0,
            martgageRate: _martgageRate,
            lendToken:_lendToken,
            borrowToken:_borrowToken,
            state: defaultChoice,
            spCoin: IDebtToken(_spToken),
            jpCoin: IDebtToken(_jpToken),
            autoLiquidateThreshold:_autoLiquidateThreshold
        }));
        // 推入池数据信息
        poolDataInfo.push(PoolDataInfo({
            settleAmountLend:0,
            settleAmountBorrow:0,
            finishAmountLend:0,
            finishAmountBorrow:0,
            liquidationAmounLend:0,
            liquidationAmounBorrow:0
        }));
    }
      /**
     * @dev Get pool state
     * @notice returned is an int integer
     */
    function getPoolState(uint256 _pid) public view returns (uint256) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        return uint256(pool.state);
    }

    /* ------------------------------------------------------------
     * 【学习注释】修饰器流水线（读函数前先看这四个）：
     *   nonReentrant      重入锁（OpenZeppelin），所有碰钱的函数必挂
     *   timeBefore(_pid)  当前时间 < settleTime   → 存款类函数用
     *   timeAfter(_pid)   当前时间 > settleTime   → 退款/领凭证类函数用
     *   stateMatch / stateNotMatchUndone / stateFinishLiquidation / stateUndone
     *                     状态门禁：每个函数只允许在特定状态下调用
     * 记忆法：看函数名前先看修饰器，修饰器就是这个函数的"准入条件"
     * ------------------------------------------------------------ */
       /**
     * @dev 存款人执行存款操作
     * @notice 池状态必须为MATCH
     * @param _pid 是池索引
     * @param _stakeAmount 是用户的质押金额
     */
    function depositLend(uint256 _pid, uint256 _stakeAmount) external payable nonReentrant notPause timeBefore(_pid) stateMatch(_pid){
        // 时间和状态的限制
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid];
        // 边界条件
        require(_stakeAmount <= (pool.maxSupply).sub(pool.lendSupply), "depositLend: 数量超过限制");
        uint256 amount = getPayableAmount(pool.lendToken,_stakeAmount);
        require(amount > minAmount, "depositLend: 少于最小金额");
        // 保存借款用户信息
        lendInfo.hasNoClaim = false;
        lendInfo.hasNoRefund = false;
        if (pool.lendToken == address(0)){
            lendInfo.stakeAmount = lendInfo.stakeAmount.add(msg.value);
            pool.lendSupply = pool.lendSupply.add(msg.value);
        } else {
            lendInfo.stakeAmount = lendInfo.stakeAmount.add(_stakeAmount);
            pool.lendSupply = pool.lendSupply.add(_stakeAmount);
        }
        emit DepositLend(msg.sender, pool.lendToken, _stakeAmount, amount);
    }

       /**
     * @dev 退还过量存款给存款人
     * @notice 池状态不等于匹配和未完成
     * @param _pid 是池索引
     */
    function refundLend(uint256 _pid) external nonReentrant notPause timeAfter(_pid) stateNotMatchUndone(_pid){
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池的基本信息
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池的数据信息
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid]; // 获取用户的出借信息
        // 限制金额
        require(lendInfo.stakeAmount > 0, "refundLend: not pledged"); // 需要用户已经质押了一定数量
        require(pool.lendSupply.sub(data.settleAmountLend) > 0, "refundLend: not refund"); // 需要池中还有未退还的金额
        require(!lendInfo.hasNoRefund, "refundLend: repeat refund"); // 需要用户没有重复退款
        // 用户份额 = 当前质押金额 / 总金额
        uint256 userShare = lendInfo.stakeAmount.mul(calDecimal).div(pool.lendSupply);
        // refundAmount = 总退款金额 * 用户份额
        uint256 refundAmount = (pool.lendSupply.sub(data.settleAmountLend)).mul(userShare).div(calDecimal);
        // 退款操作
        _redeem(msg.sender,pool.lendToken,refundAmount);
        // 更新用户信息
        lendInfo.hasNoRefund = true;
        lendInfo.refundAmount = lendInfo.refundAmount.add(refundAmount);
        emit RefundLend(msg.sender, pool.lendToken, refundAmount); // 触发退款事件
    }

    /* ============================================================
     * 【学习注释】claimLend() —— 放款人领 spToken（放款凭证）
     *
     * 前提：settle 已经跑完（状态 EXECUTION/FINISH/LIQUIDATION 均可领）。
     * 计算三步走（share 模式，本文件反复出现）：
     *   用户份额   userShare = 我的存款 / 池子总存款
     *   我分到的   spAmount  = settleAmountLend × userShare
     *   mint spToken + 标记 hasNoClaim 防重复领取
     *
     * 为什么用 ERC20 做凭证而不是 mapping？
     *   ① 可转让：放款收益可以二级市场卖掉，不用等到期
     *   ② 可组合：spToken 能抵押进其他 DeFi 协议
     *   ③ withdraw 时 burn 凭证换回资产，burn 数量即分钱份额，天然防重复领取
     * ============================================================ */
    function claimLend(uint256 _pid) external nonReentrant notPause timeAfter(_pid) stateNotMatchUndone(_pid){
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池的基本信息
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池的数据信息
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid]; // 获取用户的借款信息
        // 金额限制
        require(lendInfo.stakeAmount > 0, "claimLend: 不能领取 sp_token"); // 需要用户的质押金额大于0
        require(!lendInfo.hasNoClaim,"claimLend: 不能再次领取"); // 用户不能再次领取
        // 用户份额 = 当前质押金额 / 总金额
        uint256 userShare = lendInfo.stakeAmount.mul(calDecimal).div(pool.lendSupply); 
        // totalSpAmount = settleAmountLend
        uint256 totalSpAmount = data.settleAmountLend; // 总的Sp金额等于借款结算金额
        // 用户 sp 金额 = totalSpAmount * 用户份额
        uint256 spAmount = totalSpAmount.mul(userShare).div(calDecimal); 
        // 铸造 sp token
        pool.spCoin.mint(msg.sender, spAmount); 
        // 更新领取标志
        lendInfo.hasNoClaim = true; 
        emit ClaimLend(msg.sender, pool.borrowToken, spAmount); // 触发领取借款事件
    }

    /* ============================================================
     * 【学习注释】withdrawLend() —— 放款人 burn spToken 拿回本金+利息
     *
     * 分钱公式：赎回金额 = finishAmountLend（或清算残值）× (我的sp/总sp)
     * sp 是"份额"而不是"金额"——按比例分池子里实际有的钱。
     *
     * 两个状态的钱来源不同：
     *   FINISH      → 分 finishAmountLend（抵押物卖出的稳定币，含利息）
     *   LIQUIDATION → 分 liquidationAmounLend（清算残值，可能不足额）
     * 关键保护：放款人优先保本保息，借款人血本无归——这就是抵押借贷
     * 对放款方的安全设计，也是"清算"对借款人残酷的地方。
     * ============================================================ */
    function withdrawLend(uint256 _pid, uint256 _spAmount)  external nonReentrant notPause stateFinishLiquidation(_pid) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];
        require(_spAmount > 0, 'withdrawLend: 取款金额为零');
        // 销毁 sp_token
        pool.spCoin.burn(msg.sender,_spAmount);
        // 计算销毁份额
        uint256 totalSpAmount = data.settleAmountLend;
        // sp份额 = _spAmount/totalSpAmount
        uint256 spShare = _spAmount.mul(calDecimal).div(totalSpAmount);
        // 完成
        if (pool.state == PoolState.FINISH){
            require(block.timestamp > pool.endTime, "withdrawLend: 少于结束时间");
            // 赎回金额 = finishAmountLend * sp份额
            uint256 redeemAmount = data.finishAmountLend.mul(spShare).div(calDecimal);
            // 退款动作
             _redeem(msg.sender,pool.lendToken,redeemAmount);
            emit WithdrawLend(msg.sender,pool.lendToken,redeemAmount,_spAmount);
        }
        // 清算
        if (pool.state == PoolState.LIQUIDATION) {
            require(block.timestamp > pool.settleTime, "withdrawLend: 少于匹配时间");
            // 赎回金额
            uint256 redeemAmount = data.liquidationAmounLend.mul(spShare).div(calDecimal);
            // 退款动作
             _redeem(msg.sender,pool.lendToken,redeemAmount);
            emit WithdrawLend(msg.sender,pool.lendToken,redeemAmount,_spAmount);
        }
    }

       /**
     * @dev 紧急提取贷款
     * @notice 池状态必须是未完成
     * @param _pid 是池索引
     */
    function emergencyLendWithdrawal(uint256 _pid) external nonReentrant notPause stateUndone(_pid){
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池的基本信息
        require(pool.lendSupply > 0,"emergencLend: not withdrawal"); // 要求贷款供应大于0
        // 贷款紧急提款
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid]; // 获取用户的贷款信息
        // 限制金额
        require(lendInfo.stakeAmount > 0, "refundLend: not pledged"); // 要求质押金额大于0
        require(!lendInfo.hasNoRefund, "refundLend: again refund"); // 要求没有退款
        // 退款操作
        _redeem(msg.sender,pool.lendToken,lendInfo.stakeAmount); // 执行赎回操作
        // 更新用户信息
        lendInfo.hasNoRefund = true; // 设置没有退款为真
        emit EmergencyLendWithdrawal(msg.sender, pool.lendToken, lendInfo.stakeAmount); // 触发紧急贷款提款事件
    }



       /**
     * @dev 借款人质押操作
     * @param _pid 是池子索引
     * @param _stakeAmount 是用户质押的数量
     */
    function depositBorrow(uint256 _pid, uint256 _stakeAmount ) external payable nonReentrant notPause timeBefore(_pid) stateMatch(_pid){
        // 基础信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池子基础信息
        BorrowInfo storage borrowInfo = userBorrowInfo[msg.sender][_pid]; // 获取用户借款信息
        // 动作
        uint256 amount = getPayableAmount(pool.borrowToken, _stakeAmount); // 获取应付金额
        require(amount > 0, 'depositBorrow: deposit amount is zero'); // 要求质押金额大于0
        // 保存用户信息
        borrowInfo.hasNoClaim = false; // 设置用户未提取质押物
        borrowInfo.hasNoRefund = false; // 设置用户未退款
        // 更新信息
        if (pool.borrowToken == address(0)){ // 如果借款代币是0地址（即ETH）
            borrowInfo.stakeAmount = borrowInfo.stakeAmount.add(msg.value); // 更新用户质押金额
            pool.borrowSupply = pool.borrowSupply.add(msg.value); // 更新池子借款供应量
        } else{ // 如果借款代币不是0地址（即其他ERC20代币）
            borrowInfo.stakeAmount = borrowInfo.stakeAmount.add(_stakeAmount); // 更新用户质押金额
            pool.borrowSupply = pool.borrowSupply.add(_stakeAmount); // 更新池子借款供应量
        }
        emit DepositBorrow(msg.sender, pool.borrowToken, _stakeAmount, amount); // 触发质押借款事件
    }

        /**
     * @dev 退还给借款人的过量存款，当借款人的质押量大于0，且借款供应量减去结算借款量大于0，且借款人没有退款时，计算退款金额并进行退款。
     * @notice 池状态不等于匹配和未完成
     * @param _pid 是池状态
     */
    function refundBorrow(uint256 _pid) external nonReentrant notPause timeAfter(_pid) stateNotMatchUndone(_pid){
        // 基础信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池的基础信息
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池的数据信息
        BorrowInfo storage borrowInfo = userBorrowInfo[msg.sender][_pid]; // 获取借款人的信息
        // 条件
        require(pool.borrowSupply.sub(data.settleAmountBorrow) > 0, "refundBorrow: not refund"); // 需要借款供应量减去结算借款量大于0
        require(borrowInfo.stakeAmount > 0, "refundBorrow: not pledged"); // 需要借款人的质押量大于0
        require(!borrowInfo.hasNoRefund, "refundBorrow: again refund"); // 需要借款人没有退款
        // 计算用户份额
        uint256 userShare = borrowInfo.stakeAmount.mul(calDecimal).div(pool.borrowSupply); // 用户份额等于借款人的质押量乘以计算小数点后的位数，然后除以借款供应量
        uint256 refundAmount = (pool.borrowSupply.sub(data.settleAmountBorrow)).mul(userShare).div(calDecimal); // 退款金额等于（借款供应量减去结算借款量）乘以用户份额，然后除以计算小数点后的位数
        // 动作
        _redeem(msg.sender,pool.borrowToken,refundAmount); // 赎回
        // 更新用户信息
        borrowInfo.refundAmount = borrowInfo.refundAmount.add(refundAmount); // 更新借款人的退款金额
        borrowInfo.hasNoRefund = true; // 设置借款人已经退款
        emit RefundBorrow(msg.sender, pool.borrowToken, refundAmount); // 触发退款事件
    }

    /* ============================================================
     * 【学习注释】claimBorrow() —— 借款人领 jpToken + 提走借到的稳定币
     *
     * 最值得琢磨的一行：
     *   totalJpAmount = settleAmountLend × martgageRate
     * jpToken 的数量是"到期该还多少抵押物"的欠条——
     * 借 20000 U（抵押率 150%）→ jp = 20000×1.5 = 30000 份。
     * 到期 withdrawBorrow 时 burn 掉 30000 份，按比例赎回剩余抵押物。
     * 所以 jpToken 总量 = 抵押物需求量，burn 即"还清对应份额"。
     *
     * 同时当场把借到的稳定币转给借款人（_redeem lendToken）。
     * 从这一刻起：放款人拿 sp 等"本+息"，借款人拿 jp 等到期赎押。
     * ============================================================ */
    function claimBorrow(uint256 _pid) external nonReentrant notPause timeAfter(_pid) stateNotMatchUndone(_pid)  {
        // 池基本信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];
        BorrowInfo storage borrowInfo = userBorrowInfo[msg.sender][_pid];
        // 限制
        require(borrowInfo.stakeAmount > 0, "claimBorrow: 没有索取 jp_token");
        require(!borrowInfo.hasNoClaim,"claimBorrow: 再次索取");
        // 总 jp 数量 = settleAmountLend * martgageRate
        uint256 totalJpAmount = data.settleAmountLend.mul(pool.martgageRate).div(baseDecimal);
        uint256 userShare = borrowInfo.stakeAmount.mul(calDecimal).div(pool.borrowSupply);
        uint256 jpAmount = totalJpAmount.mul(userShare).div(calDecimal);
        // 铸造 jp token
        pool.jpCoin.mint(msg.sender, jpAmount);
        // 索取贷款资金
        uint256 borrowAmount = data.settleAmountLend.mul(userShare).div(calDecimal);
        _redeem(msg.sender,pool.lendToken,borrowAmount);
        // 更新用户信息
        borrowInfo.hasNoClaim = true;
        emit ClaimBorrow(msg.sender, pool.borrowToken, jpAmount);
    }

       /**
     * @dev 借款人提取剩余的保证金，这个函数首先检查提取的金额是否大于0，然后销毁相应数量的JPtoken。接着，它计算JPtoken的份额，并根据池的状态（完成或清算）进行相应的操作。如果池的状态是完成，它会检查当前时间是否大于结束时间，然后计算赎回金额并进行赎回。如果池的状态是清算，它会检查当前时间是否大于匹配时间，然后计算赎回金额并进行赎回。
     * @param _pid 是池状态
     * @param _jpAmount 是用户销毁JPtoken的数量
     */
    function withdrawBorrow(uint256 _pid, uint256 _jpAmount ) external nonReentrant notPause stateFinishLiquidation(_pid) {
        // 声明池基础信息和数据信息的存储
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];
        // 要求提取的金额大于0
        require(_jpAmount > 0, 'withdrawBorrow: withdraw amount is zero');
        // 销毁jp token
        pool.jpCoin.burn(msg.sender,_jpAmount);
        // jp份额
        uint256 totalJpAmount = data.settleAmountLend.mul(pool.martgageRate).div(baseDecimal);
        uint256 jpShare = _jpAmount.mul(calDecimal).div(totalJpAmount);
        // 完成状态
        if (pool.state == PoolState.FINISH) {
            // 要求当前时间大于结束时间
            require(block.timestamp > pool.endTime, "withdrawBorrow: less than end time");
            uint256 redeemAmount = jpShare.mul(data.finishAmountBorrow).div(calDecimal);
            _redeem(msg.sender,pool.borrowToken,redeemAmount);
            emit WithdrawBorrow(msg.sender, pool.borrowToken, _jpAmount, redeemAmount);
        }
        // 清算状态
        if (pool.state == PoolState.LIQUIDATION){
            // 要求当前时间大于匹配时间
            require(block.timestamp > pool.settleTime, "withdrawBorrow: less than match time");
            uint256 redeemAmount = jpShare.mul(data.liquidationAmounBorrow).div(calDecimal);
            _redeem(msg.sender,pool.borrowToken,redeemAmount);
            emit WithdrawBorrow(msg.sender, pool.borrowToken, _jpAmount, redeemAmount);
        }
    }
       /**
     * @dev 紧急借款提取
     * @notice 在极端情况下，总存款为0，或者总保证金为0，在某些极端情况下，如总存款为0或总保证金为0时，借款者可以进行紧急提取。首先，代码会获取池子的基本信息和借款者的借款信息，然后检查借款供应和借款者的质押金额是否大于0，以及借款者是否已经进行过退款。如果这些条件都满足，那么就会执行赎回操作，并标记借款者已经退款。最后，触发一个紧急借款提取的事件。
     * @param _pid 是池子的索引
     */
    function emergencyBorrowWithdrawal(uint256 _pid) external nonReentrant notPause stateUndone(_pid) {
        // 获取池子的基本信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        // 确保借款供应大于0
        require(pool.borrowSupply > 0,"emergencyBorrow: not withdrawal");
        // 获取借款者的借款信息
        BorrowInfo storage borrowInfo = userBorrowInfo[msg.sender][_pid];
        // 确保借款者的质押金额大于0
        require(borrowInfo.stakeAmount > 0, "refundBorrow: not pledged");
        // 确保借款者没有进行过退款
        require(!borrowInfo.hasNoRefund, "refundBorrow: again refund");
        // 执行赎回操作
        _redeem(msg.sender,pool.borrowToken,borrowInfo.stakeAmount);
        // 标记借款者已经退款
        borrowInfo.hasNoRefund = true;
        // 触发紧急借款提取事件
        emit EmergencyBorrowWithdrawal(msg.sender, pool.borrowToken, borrowInfo.stakeAmount);
    }

    /**
     * @dev Can it be settle
     * @param _pid is pool index
     */
    function checkoutSettle(uint256 _pid) public view returns(bool){
        return block.timestamp > poolBaseInfo[_pid].settleTime;
    }

    /* ============================================================
     * 【学习注释】settle() —— 全项目最核心的函数：一次性撮合
     *
     * 触发条件：settleTime 已过 + 状态是 MATCH，由多签持有者（validCall）调用。
     * 合约里没有定时器，"时间到了没人调 settle，池子永远停在 MATCH"——
     * 这既是设计（省 gas），也是中心化风险点（可写进学习报告）。
     *
     * 撮合公式（带数字例子最好懂）：
     *   设借款人押了 1 BTC，预言机价 BTC=30000 USDT，抵押率 martgageRate=150%（1.5e8）
     *   抵押物总价值 totalValue = 1 × (30000/1)      = 30000 USDT
     *   可支持借款额 actualValue = 30000 / 1.5       = 20000 USDT
     *   即"押 1 BTC 最多借 2 万 U"——抵押率越低，能借的越少、越安全
     *
     * 然后两边取小（撮合的本质）：
     *   情形 A：放款人多（lendSupply 50000 > actualValue 20000）
     *           → 借款方全成交：settleAmountBorrow = 押的全部
     *             放款方只成交 20000，多出的 30000 之后 refundLend 按比例退
     *   情形 B：放款人少（lendSupply 15000 < actualValue）
     *           → 放款方全成交：settleAmountLend = 15000
     *             借款方只收 15000 对应的抵押物，多押的 refundBorrow 退回
     *
     * 注意：settle 只"记账"（写 settleAmountLend/Borrow 两个数），
     *       不转钱、不铸币——真正的资金动作发生在 claim 和 refund 里。
     * 极端情况：任一方 supply 为 0 → UNDONE，之后走 emergency*Withdrawal 原路退款。
     * ============================================================ */
       /**
     * @dev  结算
     * @param _pid 是池子的索引
     */
    function settle(uint256 _pid) public validCall {
        // 获取基础池信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        // 获取数据池信息
        PoolDataInfo storage data = poolDataInfo[_pid];
        // 需要当前时间大于池子的结算时间
        require(block.timestamp > poolBaseInfo[_pid].settleTime, "settle: 小于结算时间");
        // 池子的状态必须是匹配状态
        require(pool.state == PoolState.MATCH, "settle: 池子状态必须是匹配");
        if (pool.lendSupply > 0 && pool.borrowSupply > 0) {
            // 获取标的物价格
            uint256[2]memory prices = getUnderlyingPriceView(_pid);
            // 总保证金价值 = 保证金数量 * 保证金价格
            uint256 totalValue = pool.borrowSupply.mul(prices[1].mul(calDecimal).div(prices[0])).div(calDecimal);
            // 转换为稳定币价值
            uint256 actualValue = totalValue.mul(baseDecimal).div(pool.martgageRate);
            // 提供贷款 > 实际价值
            if (pool.lendSupply > actualValue){
                // 总借款大于总借出
                data.settleAmountLend = actualValue;
                data.settleAmountBorrow = pool.borrowSupply;
            } else {
                // 总借款小于总借出
                data.settleAmountLend = pool.lendSupply;
                data.settleAmountBorrow = pool.lendSupply.mul(pool.martgageRate).div(prices[1].mul(baseDecimal).div(prices[0]));
            }
            // 更新池子状态
            pool.state = PoolState.EXECUTION;
            // 触发事件
            emit StateChange(_pid,uint256(PoolState.MATCH), uint256(PoolState.EXECUTION));
        } else {
            // 极端情况，借款或借出任一为0
            pool.state = PoolState.UNDONE;
            data.settleAmountLend = pool.lendSupply;
            data.settleAmountBorrow = pool.borrowSupply;
            // 触发事件
            emit StateChange(_pid,uint256(PoolState.MATCH), uint256(PoolState.UNDONE));
        }
    }

    /**
     * @dev Can it be finish
     * @param _pid is pool index
     */
    function checkoutFinish(uint256 _pid) public view returns(bool){
        return block.timestamp > poolBaseInfo[_pid].endTime;
    }

    /* ============================================================
     * 【学习注释】finish() —— 到期结算：卖抵押物、还本付息
     *
     * 固定利率公式（与 liquidate() 里一字不差地重复了一遍，要背）：
     *   timeRatio = (endTime - settleTime) / 365天          ← 期限占比
     *   interest  = timeRatio × interestRate × settleAmountLend
     *             = 期限 × 年化利率 × 成交本金              ← 到期利息
     *   lendAmount = 本金 + 利息                            ← 放款人应得总额
     *
     * 资金流四步：
     *   ① 卖出抵押物：_sellExactAmount 反向查"要买到 lendAmount 需要卖多少抵押物"
     *      然后去 PancakeSwap 换稳定币（先精确计算输入量，保证换回 ≥ 应得）
     *   ② 滑点保护：require(amountIn >= lendAmount)——换不回应付本息就直接 revert
     *   ③ 多出的部分（amountIn - lendAmount）给 feeAddress 当平台收入
     *   ④ 剩余抵押物扣 borrowFee 后记到 finishAmountBorrow，借款人 withdrawBorrow 赎回
     *
     * 审计视角：swap 路径的滑点风险直接吃在池子上——流动性薄的交易对
     * 在这里可能让整个池子卡死（revert）或让平台白拿差价。
     * ============================================================ */
    function finish(uint256 _pid) public validCall {
        // 获取基础池子信息和数据信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        PoolDataInfo storage data = poolDataInfo[_pid];

        // 验证当前时间是否大于池子的结束时间
        require(block.timestamp > poolBaseInfo[_pid].endTime, "finish: less than end time");
        // 验证池子的状态是否为执行状态
        require(pool.state == PoolState.EXECUTION,"finish: pool state must be execution");

        // 获取借款和贷款的token
        (address token0, address token1) = (pool.borrowToken, pool.lendToken);

        // 计算时间比率 = ((结束时间 - 结算时间) * 基础小数)/365天
        uint256 timeRatio = ((pool.endTime.sub(pool.settleTime)).mul(baseDecimal)).div(baseYear);

        // 计算利息 = 时间比率 * 利率 * 结算贷款金额
        uint256 interest = timeRatio.mul(pool.interestRate.mul(data.settleAmountLend)).div(1e16);

        // 计算贷款金额 = 结算贷款金额 + 利息
        uint256 lendAmount = data.settleAmountLend.add(interest);

        // 计算销售金额 = 贷款金额*(1+贷款费)
        uint256 sellAmount = lendAmount.mul(lendFee.add(baseDecimal)).div(baseDecimal);

        // 执行交换操作
        (uint256 amountSell,uint256 amountIn) = _sellExactAmount(swapRouter,token0,token1,sellAmount);

        // 验证交换后的金额是否大于等于贷款金额
        require(amountIn >= lendAmount, "finish: Slippage is too high");

        // 如果交换后的金额大于贷款金额，计算费用并赎回
        if (amountIn > lendAmount) {
            uint256 feeAmount = amountIn.sub(lendAmount) ;
            // 贷款费
            _redeem(feeAddress,pool.lendToken, feeAmount);
            data.finishAmountLend = amountIn.sub(feeAmount);
        }else {
            data.finishAmountLend = amountIn;
        }

        // 计算剩余的借款金额并赎回借款费
        uint256 remianNowAmount = data.settleAmountBorrow.sub(amountSell);
        uint256 remianBorrowAmount = redeemFees(borrowFee,pool.borrowToken,remianNowAmount);
        data.finishAmountBorrow = remianBorrowAmount;

        // 更新池子状态为完成
        pool.state = PoolState.FINISH;

        // 触发状态改变事件
        emit StateChange(_pid,uint256(PoolState.EXECUTION), uint256(PoolState.FINISH));
    }


    /* ============================================================
     * 【学习注释】checkoutLiquidate() —— 清算条件的判定（view 只读）
     *
     * 清算条件一行话：抵押物现值 < 应还本息 × (1 + autoLiquidateThreshold)
     *   borrowValueNow  = settleAmountBorrow × 当前抵押物价/稳定币价
     *   valueThreshold  = settleAmountLend × (1 + 阈值)
     * 举例：押 1 BTC 借 20000 U，清算阈值 10%（1e7/1e8）
     *   当 1 BTC 现价 < 22000 U 时（20000×1.1），任何人可以触发清算。
     * 注意：这里用的是「结算时锁定的 settleAmountBorrow」而不是用户当前
     * 押金——因为 settle 之后抵押物已经整池托管，不再按个人仓位变化。
     * ============================================================ */
    function checkoutLiquidate(uint256 _pid) external view returns(bool) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取基础池信息
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池数据信息
        // 保证金价格
        uint256[2]memory prices = getUnderlyingPriceView(_pid); // 获取标的价格视图
        // 保证金当前价值 = 保证金数量 * 保证金价格
        uint256 borrowValueNow = data.settleAmountBorrow.mul(prices[1].mul(calDecimal).div(prices[0])).div(calDecimal);
        // 清算阈值 = settleAmountLend*(1+autoLiquidateThreshold)
        uint256 valueThreshold = data.settleAmountLend.mul(baseDecimal.add(pool.autoLiquidateThreshold)).div(baseDecimal);
        return borrowValueNow < valueThreshold; // 如果保证金当前价值小于清算阈值，则返回true，否则返回false
    }

    /* ============================================================
     * 【学习注释】liquidate() —— 整池清算（与 finish 的三个关键差异）
     *
     * 1. 触发条件不同：finish 等时间到，liquidate 只要 checkoutLiquidate
     *    为 true（抵押物贬值）随时可触发，且任何人都能发起（validCall 多签）。
     * 2. 利息公式与 finish 一模一样（重复代码，读的时候对照着看）。
     * 3. ⚠️ 最重要的审计发现：这里【没有】require(amountIn >= lendAmount)！
     *    L664 只处理了 amountIn > lendAmount 的分支——滑点导致的亏损
     *    直接由 liquidationAmounLend 吸收，清算收益低时放款人可能收不回本金。
     *    对比 finish() 有滑点保护，这是本合约最值得写进学习报告的问题。
     *
     * 另外注意：本合约的清算是「整池一次性」，不是 Aave 那种逐仓清算——
     * 一个池子爆仓 = 全池借款人一起出局。实现简单，但粒度粗。
     * ============================================================ */
    function liquidate(uint256 _pid) public validCall {
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池子的数据信息
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池子的基本信息
        require(block.timestamp > pool.settleTime, "现在的时间小于匹配时间"); // 需要当前时间大于结算时间
        require(pool.state == PoolState.EXECUTION,"liquidate: 池子的状态必须是执行状态"); // 需要池子的状态是执行状态
        // sellamount
        (address token0, address token1) = (pool.borrowToken, pool.lendToken); // 获取借款和贷款的token
        // 时间比率 = ((结束时间 - 结算时间) * 基础小数)/365天
        uint256 timeRatio = ((pool.endTime.sub(pool.settleTime)).mul(baseDecimal)).div(baseYear);
        // 利息 = 时间比率 * 利率 * 结算贷款金额
        uint256 interest = timeRatio.mul(pool.interestRate.mul(data.settleAmountLend)).div(1e16);
        // 贷款金额 = 结算贷款金额 + 利息
        uint256 lendAmount = data.settleAmountLend.add(interest);
        // sellamount = lendAmount*(1+lendFee)
        // 添加贷款费用
        uint256 sellAmount = lendAmount.mul(lendFee.add(baseDecimal)).div(baseDecimal);
        (uint256 amountSell,uint256 amountIn) = _sellExactAmount(swapRouter,token0,token1,sellAmount); // 卖出准确的金额
        // 可能会有滑点，amountIn - lendAmount < 0;
        if (amountIn > lendAmount) {
            uint256 feeAmount = amountIn.sub(lendAmount) ; // 费用金额
            // 贷款费用
            _redeem(feeAddress,pool.lendToken, feeAmount);
            data.liquidationAmounLend = amountIn.sub(feeAmount);
        }else {
            data.liquidationAmounLend = amountIn;
        }
        // liquidationAmounBorrow  借款费用
        uint256 remianNowAmount = data.settleAmountBorrow.sub(amountSell); // 剩余的现在的金额
        uint256 remianBorrowAmount = redeemFees(borrowFee,pool.borrowToken,remianNowAmount); // 剩余的借款金额
        data.liquidationAmounBorrow = remianBorrowAmount;
        // 更新池子状态
        pool.state = PoolState.LIQUIDATION;
         // 事件
        emit StateChange(_pid,uint256(PoolState.EXECUTION), uint256(PoolState.LIQUIDATION));
    }


      /**
     * @dev 费用计算,计算并赎回费用。首先，它计算费用，这是通过乘以费率并除以基数来完成的。如果计算出的费用大于0，它将从费用地址赎回相应的费用。最后，它返回的是原始金额减去费用。
     */
    function redeemFees(uint256 feeRatio,address token,uint256 amount) internal returns (uint256){
        // 计算费用，费用 = 金额 * 费率 / 基数
        uint256 fee = amount.mul(feeRatio)/baseDecimal;
        // 如果费用大于0
        if (fee>0){
            // 从费用地址赎回相应的费用
            _redeem(feeAddress,token, fee);
        }
        // 返回金额减去费用
        return amount.sub(fee);
    }



    /* ============================================================
     * 【学习注释】swap 内部三件套（_getSwapPath / _getAmountIn / _swap）
     *
     * 目的：finish/liquidate 都需要"把抵押物换成稳定币"，三个函数各管一段：
     *   _getSwapPath  组交易路径：lendToken/borrowToken 是 0 地址(原生币)时
     *                 自动换成 WETH——所以这合约在 BSC 上跑也能兼容原生 BNB
     *   _getAmountIn  反向询价：要换出 amountOut 个稳定币，需要"投入"多少抵押物
     *   _swap         正式执行：三种分支（ETH→Token / Token→ETH / Token→Token），
     *                 minOut 传 0 = 不设滑点下限，靠上游 require 兜底（见 finish）
     * 审计视角：_safeApprove 授权额是 uint256(-1)（无限授权）——
     * 把全部资产控制权交给 swapRouter，一旦 router 可被 admin 替换
     * （setSwapRouterAddress 是 validCall 多签管理），资金面存在风险。
     * ============================================================ */
    function _getSwapPath(address _swapRouter,address token0,address token1) internal pure returns (address[] memory path){
        IUniswapV2Router02 IUniswap = IUniswapV2Router02(_swapRouter);
        path = new address[](2);
        path[0] = token0 == address(0) ? IUniswap.WETH() : token0;
        path[1] = token1 == address(0) ? IUniswap.WETH() : token1;
    }

     /**
      * @dev Get input based on output
      */
    function _getAmountIn(address _swapRouter,address token0,address token1,uint256 amountOut) internal view returns (uint256){
        IUniswapV2Router02 IUniswap = IUniswapV2Router02(_swapRouter);
        address[] memory path = _getSwapPath(swapRouter,token0,token1);
        uint[] memory amounts = IUniswap.getAmountsIn(amountOut, path);
        return amounts[0];
    }

     /**
      * @dev sell Exact Amount
      */
    function _sellExactAmount(address _swapRouter,address token0,address token1,uint256 amountout) internal returns (uint256,uint256){
        uint256 amountSell = amountout > 0 ? _getAmountIn(swapRouter,token0,token1,amountout) : 0;
        return (amountSell,_swap(_swapRouter,token0,token1,amountSell));
    }

    /**
      * @dev Swap
      */
    function _swap(address _swapRouter,address token0,address token1,uint256 amount0) internal returns (uint256) {
        if (token0 != address(0)){
            _safeApprove(token0, address(_swapRouter), uint256(-1));
        }
        if (token1 != address(0)){
            _safeApprove(token1, address(_swapRouter), uint256(-1));
        }
        IUniswapV2Router02 IUniswap = IUniswapV2Router02(_swapRouter);
        address[] memory path = _getSwapPath(_swapRouter,token0,token1);
        uint256[] memory amounts;
        if(token0 == address(0)){
            amounts = IUniswap.swapExactETHForTokens{value:amount0}(0, path,address(this), now+30);
        }else if(token1 == address(0)){
            amounts = IUniswap.swapExactTokensForETH(amount0,0, path, address(this), now+30);
        }else{
            amounts = IUniswap.swapExactTokensForTokens(amount0,0, path, address(this), now+30);
        }
        emit Swap(token0,token1,amounts[0],amounts[amounts.length-1]);
        return amounts[amounts.length-1];
    }

    /**
     * @dev Approve
     */
    function _safeApprove(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "!safeApprove");
    }

    /* ============================================================
     * 【学习注释】getUnderlyingPriceView() —— 预言机取价
     * 返回 [稳定币价格, 抵押物价格]，settle/checkoutLiquidate 都靠它。
     * prices[1]×1e18/prices[0] 的除法是在做"单位换算"：
     * 两个价格精度可能不同（稳定币 8 位、BTC 8 位等），相除后统一到 1e18。
     * 审计视角：oracle 是自建的 BscPledgeOracle（170 行），价格源可信度
     * 和更新机制直接决定清算的公平性——它若被操纵，清算阈值形同虚设。
     * ============================================================ */
    function getUnderlyingPriceView(uint256 _pid) public view returns(uint256[2]memory){
        // 从基础池中获取指定的池
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        // 创建一个新的数组来存储资产
        uint256[] memory assets = new uint256[](2);
        // 将借款和贷款的token添加到资产数组中
        assets[0] = uint256(pool.lendToken);
        assets[1] = uint256(pool.borrowToken);
        // 从预言机获取资产的价格
        uint256[]memory prices = oracle.getPrices(assets);
        // 返回价格数组
        return [prices[0],prices[1]];
    }

    /**
     * @dev set Pause
     */
    function setPause() public validCall {
        globalPaused = !globalPaused;
    }

    /* ============================================================
     * 【学习注释】文件底部的 4 个状态门禁修饰器
     * stateNotMatchUndone 名字很绕，实际意思是"settle 已经跑过了"
     * （EXECUTION/FINISH/LIQUIDATION 三种状态之一）——claim/refund 用它。
     * 阅读技巧：每个函数的准入条件 = notPause + 时间修饰器 + 状态修饰器
     * 三层叠加，画状态机时把修饰器抄到箭头上，图就完整了。
     * ============================================================ */
    modifier notPause() {
        require(globalPaused == false, "Stake has been suspended");
        _;
    }


    modifier timeBefore(uint256 _pid) {
        require(block.timestamp < poolBaseInfo[_pid].settleTime, "Less than this time");
        _;
    }

    modifier timeAfter(uint256 _pid) {
        require(block.timestamp > poolBaseInfo[_pid].settleTime, "Greate than this time");
        _;
    }


    modifier stateMatch(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.MATCH, "state: Pool status is not equal to match");
        _;
    }

    modifier stateNotMatchUndone(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.EXECUTION || poolBaseInfo[_pid].state == PoolState.FINISH || poolBaseInfo[_pid].state == PoolState.LIQUIDATION,"state: not match and undone");
        _;
    }

    modifier stateFinishLiquidation(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.FINISH || poolBaseInfo[_pid].state == PoolState.LIQUIDATION,"state: finish liquidation");
        _;
    }

    modifier stateUndone(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.UNDONE,"state: state must be undone");
        _;
    }

}

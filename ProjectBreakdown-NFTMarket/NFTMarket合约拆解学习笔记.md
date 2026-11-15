# NFTMarket 合约拆解学习笔记

> 范围：只用学 **智能合约**。前端、后端不在本笔记里。  
> 代码目录：`EasySwapContract/contracts/`  
> 用法：按课时往下走。每课先写「打开哪个文件」，再写「看什么、想什么」，最后有过关题。过关再进下一课。

---

## 怎么用

1. 左右开：左边笔记，右边对应 `.sol`。
2. 每读一个函数只问三句：**谁能调、资产去哪、订单在盘口里还是已经关掉。**
3. 贯穿数字例子（建议抄在纸上）：

```
NFT：BAYC #42（示例，任意 ERC721 都行）
卖家 S 挂单价：1 ETH
买家 B 出价：1.2 ETH（单品 Bid）
协议费 protocolShare：250  （2.5%，因为 TOTAL_SHARE = 10000）
List.amount 必须 = 1
expiry = 0 表示永不过期
salt ≠ 0
```

4. 学习以 `contracts/` 下正式合约为准。`contracts/test/` 只在跑测试时看。

---

## 学习地图（先看一眼）

```
EasySwapContract/contracts/
├── EasySwapOrderBook.sol     ★ 对外入口，撮合都在这里
├── EasySwapVault.sol         托管 ETH / NFT
├── OrderStorage.sol          价格红黑树 + 同价链表
├── OrderValidator.sol        filledAmount、取消标记
├── ProtocolManager.sol       协议费率
├── libraries/
│   ├── LibOrder.sol          订单结构与哈希
│   ├── LibPayInfo.sol        10000 = 100%，上限 10%
│   ├── RedBlackTreeLibrary.sol
│   └── LibTransferSafeUpgradeable.sol
└── interface/                用到再点
```

继承关系（OrderBook 是拼出来的）：

```
EasySwapOrderBook
  ├─ OrderStorage      盘口怎么存
  ├─ OrderValidator    能不能成交
  ├─ ProtocolManager   抽多少费
  └─ 指向 EasySwapVault 资产实际放哪
```

---

## 第 0 课：先搞懂产品（不看代码）

**目标：** 能讲清「链上订单簿 NFT 市场」和 OpenSea 差在哪。用时约 20 分钟。

OpenSea 一类：订单在链下签名，上架几乎不花 gas，有人买了才上链。  
EasySwap：订单写进合约，上架就要 gas，同时把 NFT 或 ETH **锁进金库**。好处是盘口可以在链上按价格排序查询，不必信中继器。

两个方向：

| side | 谁发起 | 锁什么 | 等人来干什么 |
| --- | --- | --- | --- |
| List（卖） | 卖家 | NFT | 买家来 match，付 ETH |
| Bid（买） | 买家 | ETH | 卖家来 match，交 NFT |

两种标的：

- `FixedPriceForItem`：指定 collection + tokenId
- `FixedPriceForCollection`：只出现在 Bid，「这个合集任意一个 NFT」

三个必须先接受的设计：

1. **资产先托管，后成交。** 挂着的 NFT 不在卖家钱包里。
2. **改价 = 取消旧单 + 下一张新单。** 因为 OrderKey 是整单哈希。
3. **合约不会自动对敲。** 必须有人调用 `matchOrder(sell, buy)`。

**过关：** 卖家刚 `makeOrders` 成功，BAYC #42 现在在谁的地址上？买家「立即购买」一定要先自己挂一个 Bid 吗？

---

## 第 1 课：订单长什么样 —— LibOrder

**目标：** 能默写 Order 字段，并知道 OrderKey 怎么来。用时约 25 分钟。

打开 `libraries/LibOrder.sol`。

盯三个东西：

1. `enum Side { List, Bid }`
2. `enum SaleKind { FixedPriceForCollection, FixedPriceForItem }`
3. `struct Order` 和 `function hash(Order)`

贯穿例子的卖单：

```
side      = List
saleKind  = FixedPriceForItem
maker     = S
nft       = { tokenId: 42, collection: BAYC, amount: 1 }
price     = 1e18
expiry    = 0
salt      = 12345
```

`OrderKey = keccak256(TYPEHASH + 上述全部字段)`。  
salt 或 price 改一个，key 就变。后面 `editOrders` 之所以「先 cancel 再 make」，原因就在这里。

`ORDERKEY_SENTINEL = 0x0` 表示「空 / 失败」。`makeOrders` 某个单没做成，对应位置就返回这个。

**过关：** 为什么 List 的 amount 在业务上几乎只能是 1？`hash` 里有没有把 `filledAmount` 算进去？（没有。成交状态在 OrderValidator 另一张 mapping 里。）

---

## 第 2 课：金库 —— 资产实际住在哪

**目标：** 搞清 Vault 只认 OrderBook，以及按 OrderKey 记账。用时约 30 分钟。

打开 `EasySwapVault.sol`。先看修饰器 `onlyEasySwapOrderBook`，再按「存 / 取 / 改」读。

| 函数 | 何时发生 | 记账 |
| --- | --- | --- |
| `depositNFT` | 挂 List | `NFTBalance[key] = tokenId`，NFT 转入 Vault |
| `withdrawNFT` | 取消或成交 | delete 后转给 to |
| `depositETH` | 挂 Bid | `ETHBalance[key] += msg.value` |
| `withdrawETH` | 取消或成交 | 减余额，转 ETH |
| `editNFT` | 卖家改价 | 旧 key 的 tokenId 记到新 key |
| `editETH` | 买家改价 | 多退少补，余额迁到新 key |
| `transferERC721` | 卖家吃 Bid 但卖单不在盘口 | 从卖家钱包直转买家 |

用户不能自己调这些函数。`setOrderBook` 只有 Owner 能调。部署顺序必须是：先 Vault，再 OrderBook.initialize(vault)，再 Vault.setOrderBook(orderBook)。

授权提醒：ERC721 要 `approve` **Vault 地址**，不是 OrderBook。`depositNFT` 内部是 `safeTransferFrom(from, Vault, tokenId)`。

**过关：** 买家出价 1.2 ETH、amount=1，Vault 里这个 OrderKey 的 ETHBalance 是多少？取消时退多少？

---

## 第 3 课：校验与成交状态 —— OrderValidator / ProtocolManager

**目标：** 知道一笔单怎样算「还能成交」。用时约 20 分钟。

打开 `OrderValidator.sol`。

```
filledAmount[orderKey]
  0                 未成交
  1 .. amount-1     部分成交（Bid 集合出价才可能 >1）
  amount            完全成交
  type(uint256).max 已取消（常量 CANCELLED）
```

`_validateOrder`：maker 非零、salt 非零、没过期（取消时可 skip）、List 要有 collection、Bid 价格 > 0。

再打开 `ProtocolManager.sol` + `LibPayInfo.sol`：

```
fee = total × protocolShare / 10000
protocolShare 上限 1000  → 最多 10%
```

贯穿例子：成交价 1 ETH，share 250 → 手续费 0.025 ETH，卖家到账 0.975 ETH。

**过关：** 已取消的单再 match，会在哪一层被拦住？`_getFilledAmount` 里那句 `require != CANCELLED`。

---

## 第 4 课：盘口怎么存 —— OrderStorage

**目标：** 能在纸上画出「同一合集三个卖价」的树和链表。用时约 45 分钟。这是本项目最「订单簿」的一课。

打开 `OrderStorage.sol`。先看三个 mapping，再读 `_addOrder` / `_removeOrder`，最后 `getBestPrice`。

结构：

```
priceTrees[collection][side]                 红黑树，节点是价格
orderQueues[collection][side][price]         该价格档的链表头尾
orders[orderKey] = { order, next }           节点
```

价格方向：

- List：`first()` = 最低卖价（买家想吃的最优）
- Bid：`last()` = 最高买价（卖家想吃的最优）

同价：新单接到 `tail`，先来的在 `head` —— 时间优先。

`_addOrder`：价格档不存在就 `tree.insert`；空队列则 head=tail=新单，否则旧 tail.next = 新单。  
`_removeOrder`：沿链表找到 maker+saleKind+expiry+salt+tokenId+amount 都匹配的节点，摘链；若该档空了，从树上删这个价格。

`getBestOrder` / `getOrders` 会跳过：

- 已过期（expiry != 0 且 < now）
- 查单品 Bid 时 tokenId 不符的单
- 查集合 Bid 时，把「单品 Bid」滤掉（避免拿错类型）

**过关：** 合集里有卖价 1.5、1.0、2.0 三档，`getBestPrice(collection, List)` 是哪个？同一 1.0 档有两单，先成交哪一单？

---

## 第 5 课：挂单 makeOrders

**目标：** 看懂「批量、部分成功、多余 ETH 退回」。用时约 30 分钟。

打开 `EasySwapOrderBook.sol` 的 `makeOrders` 和 `_makeOrderTry`。

准入：`whenNotPaused` + `nonReentrant`。

`_makeOrderTry` 必须同时成立：

- `order.maker == msg.sender`
- 价格非 0、salt 非 0
- expiry > now 或 expiry == 0
- `filledAmount[hash] == 0`（没被用过、没取消）

然后：

- List：`amount` 必须为 1，否则返回 sentinel；`vault.depositNFT`
- Bid：`amount` 不能为 0；`vault.depositETH{value: 单价×数量}`

成功则 `_addOrder` + `LogMake`；失败 `LogSkipOrder`，**整笔交易不一定 revert**。这是批量接口的风格：能做成的做成。

外层累加 Bid 所需 ETH，最后 `msg.value > 所需` 则退差。ETH 不够会在 `depositETH` 的 require 处回滚。

**过关：** 一次 `makeOrders` 里两单 List、第二单没授权，第一单会不会已经锁进 Vault？看代码：失败返回 sentinel 但不 revert，第一单已经 deposit 了——所以是部分成功。把这个结论写在函数旁边。

---

## 第 6 课：取消与改价

**目标：** 看懂退资产，以及 edit 为什么是「取消 + 新建」。用时约 35 分钟。

### 6.1 `_cancelOrderTry`

只有 maker，且 `filledAmount < nft.amount`。

- List：`withdrawNFT` 还给 maker
- Bid：退 `单价 × (amount - filled)` 的 ETH
- `_removeOrder` 出盘口，`_cancelOrder` 把 filled 写成 CANCELLED
- `LogCancel`

### 6.2 `_editOrderTry`

先检查旧新单的 saleKind / side / maker / collection / tokenId 必须相同，只能动 **price 和 amount**。完全成交的不能改。

流程：

1. `_removeOrder` + `_cancelOrder` 旧单
2. `_addOrder` 新单（新 salt、新 hash）
3. List：`vault.editNFT(oldKey, newKey)`，NFT 还在 Vault，只换记账 key
4. Bid：比较剩余 ETH；新总价更高要补 `msg.value`，更低则 Vault 把差额打回 maker

**过关：** 卖家把 1 ETH 改成 1.5 ETH，NFT 有没有离开 Vault？OrderKey 变了没有？旧 key 还能 match 吗？

---

## 第 7 课：撮合 —— 全项目最核心

**目标：** 能不看代码讲清两个分支的资金流。用时约 50 分钟。

打开 `_isMatchAvailable`，再打开 `_matchOrder`。建议把函数打印出来，左右标「卖家吃 Bid / 买家吃 List」。

### 7.1 能不能配

`_isMatchAvailable` 六条（见拆解文档 7.5）。卖单必须是 `FixedPriceForItem`。集合出价只能在买侧。

### 7.2 分支一：`msg.sender == sellOrder.maker`（卖家接受出价）

```
require(msg.value == 0)
成交价 fillPrice = buyOrder.price        ← 用买价
Bid 必须已在盘口（从 Vault 拿得出 ETH）
List 可以已在盘口，也可以是「现挂现吃」（isSellExist == false）
  已在盘口：Vault.withdrawNFT 给买家
  不在盘口：Vault.transferERC721 从卖家钱包直转（卖家要已授权 Vault）
ETH：Vault.withdrawETH(bidKey, fillPrice, OrderBook)
     → 卖家收到 fillPrice - fee
     → fee 留在 OrderBook
```

贯穿例子：B 事先锁了 1.2 ETH，S 接受 → S 得 1.2 × 0.975，协议 0.03，NFT #42 给 B。

### 7.3 分支二：`msg.sender == buyOrder.maker`（买家接受挂单）

```
List 必须已在盘口
成交价 fillPrice = sellOrder.price       ← 用卖价
Bid 可以不在盘口（Buy Now）：
  不在盘口：msg.value >= fillPrice，当场付钱
  在盘口：buyPrice >= fillPrice，从 Vault 抽出买价
NFT：Vault.withdrawNFT 给买家
卖家收到 fillPrice - fee
若买价 > 卖价，多出的 ETH 退买家
costValue：当场付的才计入，方便外层退 msg.value 余款
```

贯穿例子：S 挂 1 ETH，B 直接 match → B 付 ≥ 1 ETH，S 得 0.975，#42 给 B。

### 7.4 谁不能调

`msg.sender` 既不是卖单 maker 也不是买单 maker → revert `"HD: sender invalid"`。第三方不能替别人成交（没有经纪人角色）。

**过关：** 卖家吃 Bid 时成交价用哪边？买家吃 List 时呢？为什么不对称？

（卖家吃单用买价：卖家愿意按对方出的价卖。买家吃单用卖价：买家愿意按挂牌价买。各取「被吃那一侧」的报价。）

---

## 第 8 课：批量 match 与 multicall

**目标：** 知道 delegatecall 在这里干什么。用时约 25 分钟。

`matchOrders`：循环里 `address(this).delegatecall(matchOrderWithoutPayback(...))`。  
`onlyDelegateCall` 保证 `matchOrderWithoutPayback` 不能被外部当普通 call 用（`address(this) != self`）。

为什么不用普通内部调用？注释写的是批量时避免每笔都退 ETH；外层统一按累计 `buyETHAmount` 退一次。单笔失败只 `emit BatchMatchInnerError`，`successes[i]=false`，整笔交易继续。

`multicall`：把 make/cancel/edit/match 串进一笔交易。限制：

- selector 白名单
- **最多一个**会花 `msg.value` 的子调用（否则每个 delegatecall 都看到同一笔 msg.value，会重复花）

**过关：** 用户想「先出价再立刻吃一个卖单」，能不能放进一次 multicall？两个都 payable，会被 `"HD: multi value calls"` 拦住。这是设计约束，不是 bug。

---

## 第 9 课：把一张资金流图画完（合上代码）

**目标：** 不看文件，用贯穿例子走通两条路。用时约 20 分钟。

**路 A：挂 1 ETH，别人立即买**

```
S: NFT #42 ──make List──► Vault
B: 1 ETH ──match（当场 Bid）──► OrderBook
OrderBook ──0.975 ETH──► S
Vault ──#42──► B
0.025 ETH 留在 OrderBook（Owner 以后 withdrawETH）
```

**路 B：先出价 1.2 ETH，卖家接受**

```
B: 1.2 ETH ──make Bid──► Vault
S: 可以事先 make List，也可以当场交 NFT
S 调 match，msg.value = 0
Vault ──1.2 ETH──► OrderBook ──0.975×1.2──► S
NFT ──► B
```

对照：两条路协议费都从 **成交价** 扣，成交价在两条路里定义不同（卖价 vs 买价）。

---

## 第 10 课：管理员与升级

**目标：** 知道 Owner 能做什么。用时约 15 分钟。

OrderBook：`setVault`、`setProtocolShare`、`pause/unpause`、`withdrawETH`（提协议费）。  
Vault：`setOrderBook`。

合约是 OZ Upgradeable：`initialize` 只能跑一次，存储末尾 `__gap` 给将来加变量。学习阶段不必钻代理槽，只要知道「逻辑合约可以换，Vault 记账不能乱」。

**过关：** pause 之后 `makeOrders` 还能用吗？（`whenNotPaused`，不能。）已经锁在 Vault 里的 NFT 怎么办？只能等 unpause 后 cancel。

---

## 读代码时建议的文件顺序（复习用）

1. `LibOrder.sol` 结构 + hash
2. `EasySwapVault.sol` 存取
3. `OrderStorage.sol` `_addOrder` 与 `getBestPrice`
4. `EasySwapOrderBook.sol` `makeOrders` → `_cancelOrderTry` → `_editOrderTry`
5. `_isMatchAvailable` + `_matchOrder` 两个分支
6. `ProtocolManager` 费率
7. `matchOrders` / `multicall` 的 delegatecall

---

## 总自检（闭卷）

1. NFT 授权给谁？挂单后 NFT 在哪个合约？
2. OrderKey 包含哪些字段？改价为什么换 key？
3. 价格树 List 侧取最高还是最低？
4. `makeOrders` 某一单失败，其它单会不会回滚？
5. 买家 Buy Now 要不要先 make Bid？钱从 msg.value 还是 Vault 出？
6. 卖家接受 Bid 时 msg.value 为什么必须是 0？
7. 集合 Bid 和单品 List 成交时，tokenId 以谁为准？
8. 协议费当时打给 Owner 吗？还是积在 OrderBook？
9. `filledAmount == max` 还能 match 吗？
10. 第三方能不能调用 `matchOrder` 帮两边成交？

第 10 题：不能。`msg.sender` 必须是卖单或买单的 maker。没有 relayer 角色——这和 Seaport 允许他人 fill 签名单不一样。

---

## 可选：跑测试

```
cd EasySwapContract
npm install
npx hardhat test
```

先看与 `makeOrders`、`matchOrder` 相关的用例，对照第 5、7 课。测试里的地址、mock NFT 可以忽略，盯「先授权 Vault → make → match → ownerOf 变成买家」。

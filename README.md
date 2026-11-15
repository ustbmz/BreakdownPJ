# BreakdownPJ

四个 Web3 / 交易系统的拆解仓库：固定利率借贷、NFT 市场、永续合约、现货撮合引擎。每个子项目都有一份**全栈拆解文档**和一份**核心学习笔记**（合约或撮合核心，按课时走）。

远程：https://github.com/ustbmz/BreakdownPJ

---

## 怎么学

顺序、每周读哪一课、学完怎么验收，见 [学习安排.md](./学习安排.md)。默认一天 2 小时，六周走完四个项目：Pledge → NFTMarket → 永续 → market-match。

每个子目录先打开「项目拆解文档」，把产品、架构、数据流搞清楚；再按「学习笔记」对着源码一课一课过。笔记里不掺前端 / 后端（撮合引擎那份只覆盖 `match/`）。

| 项目 | 是什么 | 拆解文档 | 学习笔记 |
| --- | --- | --- | --- |
| [ProjectBreakdown-Pledge](./ProjectBreakdown-Pledge) | 固定利率、固定期限抵押借贷 | [Pledge项目拆解文档.md](./ProjectBreakdown-Pledge/Pledge项目拆解文档.md) | [Pledge合约拆解学习笔记.md](./ProjectBreakdown-Pledge/Pledge合约拆解学习笔记.md) |
| [ProjectBreakdown-NFTMarket](./ProjectBreakdown-NFTMarket) | 链上订单簿 NFT 市场（EasySwap） | [NFTMarket项目拆解文档.md](./ProjectBreakdown-NFTMarket/NFTMarket项目拆解文档.md) | [NFTMarket合约拆解学习笔记.md](./ProjectBreakdown-NFTMarket/NFTMarket合约拆解学习笔记.md) |
| [perpetual-contract](./perpetual-contract) | 链下撮合、链上结算的永续合约 | [永续合约项目拆解文档.md](./perpetual-contract/永续合约项目拆解文档.md) | [永续合约拆解学习笔记.md](./perpetual-contract/永续合约拆解学习笔记.md) |
| [market-match](./market-match) | 链下现货撮合引擎（Go，无合约） | [撮合引擎项目拆解文档.md](./market-match/撮合引擎项目拆解文档.md) | [撮合引擎核心拆解学习笔记.md](./market-match/撮合引擎核心拆解学习笔记.md) |

---

## 四个项目差在哪

| | Pledge | NFTMarket | 永续 | market-match |
| --- | --- | --- | --- | --- |
| 链上核心 | 资金池状态机 | 订单簿 + Vault | Perpetual + Dealer | 无 |
| 订单在哪 | 无 | 链上价格树 | 链下 EIP-712 签名 | MySQL 序列 + 内存簿 |
| 后端角色 | 轮询 view | 扫事件 | Relayer 发 `trade()` | 引擎自己撮合 |
| 钱谁管 | PledgePool | Vault | Dealer USDC | 上游账户系统 |

---

## 目录

```
BreakdownPJ/
├── 学习安排.md                   # 六周顺序：Pledge → NFT → 永续 → 撮合
├── ProjectBreakdown-Pledge/      # 合约 pledgev2 + 后端 + 前端
├── ProjectBreakdown-NFTMarket/   # EasySwap 合约 / Sync / Backend / 前端
├── perpetual-contract/           # Foundry 永续 + others/backend + others/fe
└── market-match/                 # Go 撮合引擎
```

原始上游仓库：

- Pledge：https://github.com/MetaNodeAcademy/ProjectBreakdown-Pledge
- NFTMarket：https://github.com/MetaNodeAcademy/ProjectBreakdown-NFTMarket
- 永续：https://github.com/MetaNodeAcademy/perpetual-contract

`market-match` 是中心化现货撮合，不要和永续 Relayer 或 NFT 链上订单簿当成同一件事。

---

## 本地注意

- 不要提交 `.env`。合约部署用的私钥只放本机。
- `market-match/data/` 是本地 MySQL / Redis 数据目录，已忽略。
- 前端：`cd` 到对应目录后 `pnpm i` / `yarn`。
- 永续合约：`cd perpetual-contract && forge test`。
- 撮合核心：`cd market-match && go test ./match/`。

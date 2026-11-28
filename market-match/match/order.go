package match

import (
	"fmt"
	"github.com/spf13/cast"
	"market-match/common"

	"github.com/shopspring/decimal"
)

// OrderBuyOrSell 是方向。挂单取 Buy 或 Sell。撤单、批量撤单取 Submit，没有买卖方向。
// iota：Buy=0，Sell=1，Submit=2。
// 序列表没有单独的方向列，方向藏在 type 这个整数里，由 puller.setOrderType 拆出来。
type OrderBuyOrSell int

const (
	Buy    OrderBuyOrSell = iota // 买单。BuySet 里价高的排前面
	Sell                         // 卖单。SellSet 里价低的排前面
	Submit                       // 撤单指令。matchCancel 按 OrderId 去 cache 找，不进树
)

func getBuyOrSellStr(buyOrSell OrderBuyOrSell) string {
	switch buyOrSell {
	case Buy:
		return "buy"
	case Sell:
		return "sell"
	case Submit:
		return "submit"
	default:
		common.Fatal("Error buyOrSell", buyOrSell)
	}
	return ""
}

// OrderState 是这张单撮完之后的枚举。Puller 扫进来时写成 Submitted。
// Type 是「想怎么成交」，State 是「变成了什么样」。
// 结果 JSON 里的 state 字符串有时和枚举不是同一个词：
// 市价一张都没吃上，枚举仍是 Submitted，finalizeTakerMarket 把字符串写成 canceled。
type OrderState int

const (
	Submitted                OrderState = iota // 刚入库。限价没配上就带着它入簿；市价没配上结果字符串另写成 canceled
	PartialFilled                              // fillAmount 减完还有剩余
	PartialCanceled                            // 枚举名。撤单和市价剩余通常只把结果字符串写成 partial-canceled
	Canceled                                   // matchLimitMaker 能立刻成交时把枚举设成它。普通撤单只改结果字符串
	Filled                                     // fillAmount 把 UnfilledAmount 减到 0
	Failed                                     // 枚举在。撤单在簿上找不到时，结果字符串是 failed，不写这个枚举
	Error                                      // 枚举在。撮合主路径不写它
	CircuitCanceled                            // 市价已经有第一笔，下一档对手价越出 CircuitRate。等号也算越界，第一笔不回滚
	SystemCanceled                             // 枚举在，主路径不赋值。精度不合格走的是 Type=SystemCancel，结果字符串是 canceled
	SelfTradeCanceled                          // 自成交撤掉一张本来是 Submitted 的单
	SelfTradePartialCanceled                   // 自成交撤掉一张已经 PartialFilled 的单
	SelfTradeDecreased                         // Stp=DC，重叠数量砍掉后还剩一点。结果字符串常记成 partial-canceled
	PrecisionCanceled                          // 市价买剩下的钱不够买一跳（1e-6 × 对手价）
)

// OrderType 是撮合循环里的种类。下面 iota 的数值和序列表 type 列不是同一套数。
// 库里的整数由 puller.setOrderType 拆成 BuyOrSell + Type：
//
//	库 0        → Submit + Cancel
//	库 1 / 2    → Buy / Sell + Market
//	库 3 / 4    → Buy / Sell + Limit
//	库 5 / 6    → Buy / Sell + Ioc。Match 里这个分支被注释，会掉进 default 然后 Fatal
//	库 7 / 8    → Buy / Sell + Fok
//	库 9 / 10   → 没有分支，Type 留着零值，零值就是 Market
//	库 13       → Submit + BatchCancel
//
// CheckOrderScale 不通过时，setOrderType 把 Type 改成 SystemCancel。单子仍进 Match，结果是撤，不进簿。
type OrderType int

const (
	Market       OrderType = iota // 0 市价。卖按币数量；买的 UnfilledAmount 是报价金额。剩余不入簿
	Limit                         // 1 限价。吃得动就吃，剩下的 Enqueue
	Ioc                           // 2 立即成交否则取消。函数写了，Match 的 case 被注释
	Cancel                        // 3 撤一张。按 OrderId 在 cache 里找，找不到结果字符串是 failed
	SystemCancel                  // 4 精度不合格。setOrderType 改过来的，matchSystemCancel 记成 canceled
	Fok                           // 5 要么全部成交，要么整张取消。预扫描失败时簿上一张不动
	LimitMaker                    // 6 能立刻成交则撤，否则挂上。setOrderType 没有 9/10，Match 也没有这个 case
	_                             // 7–12 占位，把 BatchCancel 顶到 13，和库里的 13 对齐
	_
	_
	_
	_
	_
	BatchCancel // 13 一次撤多张。要撤的 orderId 列表在 Extra
)

// SelfTradeWMType 是自成交策略，对应序列表 stp 列。
// 触发条件在 matchAmountBasedOrder：两边 UserId 相同，并且 Stp > 0。
// AST 是 0，不进那张表，同一用户的买卖也会按普通单成交。
type SelfTradeWMType int8

const (
	AST SelfTradeWMType = iota // 0 允许自成交
	DC                         // 1 重叠数量两边一起砍，多的那边留下
	CO                         // 2 撤掉簿上的旧单，新单继续找下一张
	CN                         // 3 撤掉新单，不入簿；旧单留在簿上
	CB                         // 4 新旧两张都撤
)

func getOrderTypeStr(orderType OrderType) string {
	var typeStr string
	switch orderType {
	case Market:
		typeStr = "market"
	case Limit:
		typeStr = "limit"
	case Ioc:
		typeStr = "ioc"
	case Cancel:
		typeStr = "cancel"
	case SystemCancel:
		typeStr = "system-cancel"
	case Fok:
		typeStr = "fok"
	case BatchCancel:
		typeStr = "batch-cancel"
	default:
		common.Fatal("orderType ", orderType)
	}
	return typeStr
}

// getOrderStateStr 把枚举转成日志用的字符串。
// SystemCanceled、PrecisionCanceled 不在这个 switch 里，传进来会 Fatal。
// 结果 JSON 走 getTakerStateStr，那一个把这两个状态也转成了字符串。
func getOrderStateStr(state OrderState) string {
	var stateStr string
	switch state {
	case Submitted:
		stateStr = "submitted"
	case PartialFilled:
		stateStr = "partial-filled"
	case Canceled:
		stateStr = "canceled"
	case PartialCanceled:
		stateStr = "partial-canceled"
	case Filled:
		stateStr = "filled"
	case Failed:
		stateStr = "failed"
	case Error:
		stateStr = "error"
	case CircuitCanceled:
		stateStr = "circuit-canceled"
	case SelfTradeCanceled:
		stateStr = "self-trade-canceled"
	case SelfTradePartialCanceled:
		stateStr = "self-trade-partial-canceled"
	case SelfTradeDecreased:
		stateStr = "self-trade-decreased"

	default:
		common.Fatal("error state type " + cast.ToString(state))
	}
	return stateStr
}

// getTakerStateStr 是 Taker 结果字符串。比 getOrderStateStr 多 SystemCanceled 和 PrecisionCanceled。
// 未知状态写成 "undefined ..."，不 Fatal。
func getTakerStateStr(state OrderState) string {
	var stateStr string
	switch state {
	case Submitted:
		stateStr = "submitted"
	case PartialFilled:
		stateStr = "partial-filled"
	case Canceled:
		stateStr = "canceled"
	case PartialCanceled:
		stateStr = "partial-canceled"
	case Filled:
		stateStr = "filled"
	case Failed:
		stateStr = "failed"
	case Error:
		stateStr = "error"
	case CircuitCanceled:
		stateStr = "circuit-canceled"
	case SelfTradeCanceled:
		stateStr = "self-trade-canceled"
	case SelfTradePartialCanceled:
		stateStr = "self-trade-partial-canceled"
	case SelfTradeDecreased:
		stateStr = "self-trade-decreased"
	case SystemCanceled:
		stateStr = "system-canceled"
	case PrecisionCanceled:
		stateStr = "precision-canceled"
	default:
		stateStr = fmt.Sprintf("undefined %v", state)
	}
	return stateStr
}

// Order 是内存里的一张委托。Puller 从 aibit_spot_sequence_{symbol} 扫一行填进来。
// 排队用 SeqId。撤单、cache 用 OrderId。成交价取对手（Maker）的 Price。
type Order struct {
	// 序列表主键 id。SELECT 的第一列扫进这里。
	// Comparator 用它做时间优先：同价时小的先成交。
	// 买单 A 的 id 是 8，新买单 G 的 id 是 20，两张都挂 50000 时先成交 A。
	// 新单的 SeqId 必须大于簿上对手单，否则 matchOrder 会 Fatal。
	SeqId int64

	// 序列表 user_id。和对手 UserId 相同且 Stp > 0 时走自成交，不按普通单成交。
	UserId int64

	// 序列表 order_id，业务单号。订单簿 cache 的 key，撤单按它找。排序看 SeqId。
	OrderId int64

	// Buy、Sell，或撤单用的 Submit。
	BuyOrSell OrderBuyOrSell

	// 这张单想怎么成交：Market / Limit / Fok / Cancel ……
	Type OrderType

	// 撮完变成什么样。Puller 刚扫进来时写成 Submitted。
	// fillAmount 减到 0 → Filled，否则 PartialFilled。
	State OrderState

	// 限价。吃单时成交价取对手的 Price：G 愿意出 50002，吃到 D 的 50001，成交价是 50001。
	Price decimal.Decimal

	// 还没成交的数量。限价、市价卖是币的个数。
	// 市价买是报价货币的金额：UnfilledAmount=50000 表示还剩 50000 USDT，不是 50000 个 BTC。
	// 市价买每一跳：unitPrice = 1e-6 × 对手价；钱不够一跳 → PrecisionCanceled；
	// 可买数量 = floor(剩余钱 / unitPrice) × 1e-6；扣钱 = 成交数量 × 对手价。
	UnfilledAmount decimal.Decimal

	// 市价滑点保护比例，0 表示不启用。限价单带了这个字段也不在限价循环里用。
	// 已经有第一笔成交后，下一档对手价满足任一条件就 CircuitCanceled，停止继续扫：
	//   对手价 <= 第一笔价 × (1 - CircuitRate)
	//   对手价 >= 第一笔价 × (1 + CircuitRate)
	// 等号也算越界。已经成交的第一笔不回滚。
	CircuitRate decimal.Decimal

	// 序列表 created_at，毫秒时间戳。时间优先看 SeqId，不看这一列。
	CreateAt int64

	// 序列表 stp。0 是 AST，允许自成交。1 DC，2 CO，3 CN，4 CB。
	Stp SelfTradeWMType

	// Puller 扫到这一行时的本地毫秒时间，不是库里的列。
	PullTime int64

	// 批量撤单的 orderId 列表，JSON。普通单是空字符串。matchBatchCancel 解出来逐个 Find。
	Extra string

	// 序列表 taker、maker 两列，费率字符串。比价、排序都不用，原样抄进 OrderResult。
	Taker string
	Maker string
}

// BatchCancelOrder 是 Extra 里的一项。matchBatchCancel 只读 OrderId，按它去 cache 找。
type BatchCancelOrder struct {
	OrderId     int64 `json:"order_id"` // 要撤的业务单号
	CancelState bool  `json:"cancel_state"`
}

func (order *Order) String() string {
	s := fmt.Sprintf("(seqId:%v orderId:%v buyorsell:%v UnfilledAmount:%v price:%v, circuitRate:%v, state:%v, type:%v)",
		order.SeqId,
		order.OrderId,
		order.BuyOrSell,
		order.UnfilledAmount,
		order.Price,
		order.CircuitRate,
		order.State,
		order.Type,
	)
	return s
}

// fillAmount 把成交数量从 UnfilledAmount 里减掉。
// 减到 0 → State=Filled，否则 State=PartialFilled。
// amount 比剩余还大直接 Fatal，调用方要先取 min(自己剩余, 对手剩余)。
func (order *Order) fillAmount(amount decimal.Decimal) {
	if amount.GreaterThan(order.UnfilledAmount) {
		common.Fatal("filling amount more than need", amount, order.UnfilledAmount)
	}
	order.UnfilledAmount = order.UnfilledAmount.Sub(amount)
	if order.UnfilledAmount.Equal(decimal.Zero) {
		order.State = Filled
	} else {
		order.State = PartialFilled
	}
}

func (order *Order) SetState(state OrderState) *Order {
	order.State = state
	return order
}

// isFilled 剩余已经减到 0。市价、限价、FOK 的循环用它决定还要不要继续找对手。
func (order *Order) isFilled() bool {
	return order.State == Filled
}

func (order *Order) isPartialFilled() bool {
	return order.State == PartialFilled
}

func (order *Order) isSelfTradeCanceled() bool {
	return order.State == SelfTradeCanceled
}

func (order *Order) isSelfTradePartialCanceled() bool {
	return order.State == SelfTradePartialCanceled
}

// oppoBuyOrSell 买单的对手方向是卖，卖单的对手方向是买。Peek 对手盘时用。
// Submit 不是 Buy，会落到下面的 return Buy。撤单不走这条。
func (order *Order) oppoBuyOrSell() OrderBuyOrSell {
	if order.BuyOrSell == Buy {
		return Sell
	}
	return Buy
}

// OrderCombineTypeStr 拼成 "buy-limit" 这种日志字符串。
func (order *Order) OrderCombineTypeStr() string {
	return getBuyOrSellStr(order.BuyOrSell) + "-" + getOrderTypeStr(order.Type)
}

// Comparator 是 BuySet / SellSet 的排序。return -1 表示 a 更靠前，Peek 先看到 a。
//
//	买单：价高在前；同价 SeqId 小在前。先挂买 50000，再挂买 50001，Peek(Buy) 是 50001。
//	      再挂一张同价 50001、SeqId 更大的，Peek 不变。
//	卖单：价低在前；同价 SeqId 小在前。贯穿例子 Peek(Sell) 是 D（50001），不是 E（50002）。
//
// SeqId 相等返回 0，树把它当成同一张。Enqueue 重复 orderId 另有 Fatal，不靠这里挡。
func Comparator(a, b interface{}) int {
	orderA := a.(*Order)
	orderB := b.(*Order)

	if orderA.BuyOrSell == Buy {
		switch {
		case orderA.Price.GreaterThan(orderB.Price) ||
			(orderA.Price.Equal(orderB.Price) && orderA.SeqId < orderB.SeqId):
			return -1
		case orderA.SeqId == orderB.SeqId:
			return 0
		default:
			return 1
		}
	} else {
		switch {
		case orderA.Price.LessThan(orderB.Price) ||
			(orderA.Price.Equal(orderB.Price) && orderA.SeqId < orderB.SeqId):
			return -1
		case orderA.SeqId == orderB.SeqId:
			return 0
		default:
			return 1
		}
	}
}

// CompareOrder 比较两张单是不是同一张的快照：价、剩余、SeqId、OrderId、Type、State 都要相等。
// 方向、UserId、Stp 不在这里面。
func CompareOrder(order1 *Order, order2 *Order) bool {
	if !order1.Price.Equal(order2.Price) ||
		!order1.UnfilledAmount.Equal(order2.UnfilledAmount) ||
		order1.SeqId != order2.SeqId ||
		order1.OrderId != order2.OrderId ||
		order1.Type != order2.Type ||
		order1.State != order2.State {
		return false
	}
	return true
}

// amountScale 决定 UnfilledAmount 按几位小数截断。
// 市价买的 UnfilledAmount 是报价金额，用价格精度 PriceScale。
// 其余（限价、市价卖）是币的数量，用数量精度 AmountScale。
func amountScale(symbol string, order *Order) int32 {
	if order.Type == Market && order.BuyOrSell == Buy {
		return common.PriceScale(symbol)
	} else {
		return common.AmountScale(symbol)
	}
}

// CheckOrderScale 检查数量、价格、滑点比例是不是已经落在交易对允许的小数位上。
// 返回 false 时，setOrderType 把 Type 改成 SystemCancel，这张单进不了簿。
// 函数自己会把三个字段截断后写回去，为了和旧 clojure 引擎的结果一致；返回值看的是截断前等不等。
func CheckOrderScale(symbol string, order *Order) bool {
	amountScaled := order.UnfilledAmount.Truncate(amountScale(symbol, order))
	priceScaled := order.Price.Truncate(common.PriceScale(symbol))
	rateScaled := order.CircuitRate.Truncate(common.PriceScale(symbol))

	equaled := amountScaled.Equal(order.UnfilledAmount) &&
		priceScaled.Equal(order.Price) &&
		rateScaled.Equal(order.CircuitRate)
	// 为了和clojure 结果一致
	order.UnfilledAmount = amountScaled
	order.Price = priceScaled
	order.CircuitRate = rateScaled
	return equaled
}

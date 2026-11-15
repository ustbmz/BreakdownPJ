/* ============================================================================
 * 【学习注释 · 文件总览】task.go —— schedule 服务的调度入口（阶段三必读）
 *
 * 这个进程的角色：一个"定时读链"的机器人，把合约状态镜像到 MySQL/Redis，
 * 供 api 服务（8080）给前端查询。它【只读不写】——全文件没有任何
 * Settle/Finish/Liquidate 调用，settle 由多签持有者在链下手动发交易。
 *
 * 读这个文件的方法：先看 5 个定时任务各管什么、频率多少，再点进
 * schedule/services/ 里对应的实现（重点 poolService.go）。
 *
 * 任务清单（gocron，UTC 时区）：
 *   UpdateAllPoolInfo     每 2 分钟   轮询合约池子 → 增量入库（核心任务）
 *   UpdateContractPrice   每 1 分钟   读预言机价格 → 存库（给前端展示）
 *   UpdateContractSymbol  每 2 小时   代币元数据
 *   UpdateTokenLogo       每 2 小时   代币图标
 *   BalanceMonitor        每 30 分钟  合约余额过低 → 发邮件报警
 *
 * 面试对比点：这是「轮询索引」，EasySwapSync 是「事件驱动索引」——
 * 轮询简单可靠但要等周期；事件驱动实时但要处理断点续扫和区块重组。
 * ==========================================================================*/
package tasks

import (
	"pledge-backend/db"
	"pledge-backend/schedule/common"
	"pledge-backend/schedule/services"
	"time"

	"github.com/jasonlvhit/gocron"
)

func Task() {

	// get environment variables
	common.GetEnv()

	// flush redis db
	err := db.RedisFlushDB()
	if err != nil {
		panic("clear redis error " + err.Error())
	}

	//init task
	services.NewPool().UpdateAllPoolInfo()
	services.NewTokenPrice().UpdateContractPrice()
	services.NewTokenSymbol().UpdateContractSymbol()
	services.NewTokenLogo().UpdateTokenLogo()
	services.NewBalanceMonitor().Monitor()
	// services.NewTokenPrice().SavePlgrPrice()
	services.NewTokenPrice().SavePlgrPriceTestNet()

	//run pool task
	s := gocron.NewScheduler()
	s.ChangeLoc(time.UTC)
	_ = s.Every(2).Minutes().From(gocron.NextTick()).Do(services.NewPool().UpdateAllPoolInfo)
	_ = s.Every(1).Minute().From(gocron.NextTick()).Do(services.NewTokenPrice().UpdateContractPrice)
	_ = s.Every(2).Hours().From(gocron.NextTick()).Do(services.NewTokenSymbol().UpdateContractSymbol)
	_ = s.Every(2).Hours().From(gocron.NextTick()).Do(services.NewTokenLogo().UpdateTokenLogo)
	_ = s.Every(30).Minutes().From(gocron.NextTick()).Do(services.NewBalanceMonitor().Monitor)
	//_ = s.Every(30).Minutes().From(gocron.NextTick()).Do(services.NewTokenPrice().SavePlgrPrice)
	_ = s.Every(30).Minutes().From(gocron.NextTick()).Do(services.NewTokenPrice().SavePlgrPriceTestNet)
	<-s.Start() // Start all the pending jobs

}

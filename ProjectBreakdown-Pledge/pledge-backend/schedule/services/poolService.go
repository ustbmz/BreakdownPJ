/* ============================================================================
 * 【学习注释 · 文件总览】poolService.go —— 链上池子 → 数据库的同步核心（阶段三精读）
 *
 * 这是理解「后端怎么镜像链上状态」的最佳样本，同步策略三步走：
 *   ① 轮询：每 2 分钟跑一次 UpdateAllPoolInfo（调度在 tasks/task.go）
 *   ② 全量枚举：PoolLength() 拿池子总数 → for 循环逐池调 PoolBaseInfo/PoolDataInfo
 *      （注意：这里是合约 view 调用，不是扫事件日志——所以新池子建好后
 *       最多要等 2 分钟才出现在前端列表里）
 *   ③ 增量落库：把链上数据拼成 JSON → 算 MD5 → 和 Redis 里缓存的旧 MD5 比，
 *      只有变化了才写 MySQL。MD5 缓存 30 分钟过期防哈希碰撞。
 *
 * 面试必问「为什么用 MD5 比对而不是每次直接写库？」→ 大多数周期里数据
 * 没变，直接写库浪费磁盘 IO 和 binlog；先算哈希比对，命中才写，
 * 是只读索引服务的通用优化。代价：MD5 碰撞概率极低但存在（见注释）。
 *
 * 两个数据表对应合约两个结构体：
 *   PoolBase   ← PoolBaseInfo（建池参数+实时 supply）
 *   PoolData   ← PoolDataInfo（settle/finish/liquidate 的成交额快照）
 * ==========================================================================*/
package services

import (
	"encoding/json"
	"math/big"
	"pledge-backend/config"
	"pledge-backend/contract/bindings"
	"pledge-backend/db"
	"pledge-backend/log"
	"pledge-backend/schedule/models"
	"pledge-backend/utils"
	"strings"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"
)

type poolService struct{}

func NewPool() *poolService {
	return &poolService{}
}

func (s *poolService) UpdateAllPoolInfo() {

	s.UpdatePoolInfo(config.Config.TestNet.PledgePoolToken, config.Config.TestNet.NetUrl, config.Config.TestNet.ChainId)

	// s.UpdatePoolInfo(config.Config.MainNet.PledgePoolToken, config.Config.MainNet.NetUrl, config.Config.MainNet.ChainId)

}

func (s *poolService) UpdatePoolInfo(contractAddress, network, chainId string) {

	log.Logger.Sugar().Info("UpdatePoolInfo ", contractAddress+" "+network)
	ethereumConn, err := ethclient.Dial(network)
	if nil != err {
		log.Logger.Error(err.Error())
		return
	}
	pledgePoolToken, err := bindings.NewPledgePoolToken(common.HexToAddress(contractAddress), ethereumConn)
	if nil != err {
		log.Logger.Error(err.Error())
		return
	}

	// borrowFee
	borrowFee, err := pledgePoolToken.PledgePoolTokenCaller.BorrowFee(nil)

	// lendFee
	lendFee, err := pledgePoolToken.PledgePoolTokenCaller.LendFee(nil)

	//poolLength
	pLength, err := pledgePoolToken.PledgePoolTokenCaller.PoolLength(nil)
	if nil != err {
		log.Logger.Error(err.Error())
		return
	}

	for i := 0; i <= int(pLength.Int64())-1; i++ {

		log.Logger.Sugar().Info("UpdatePoolInfo ", i)
		poolId := utils.IntToString(i + 1)
		baseInfo, err := pledgePoolToken.PledgePoolTokenCaller.PoolBaseInfo(nil, big.NewInt(int64(i)))
		if err != nil {
			log.Logger.Sugar().Info("UpdatePoolInfo PoolBaseInfo err", poolId, err)
			continue
		}

		_, borrowToken := models.NewTokenInfo().GetTokenInfo(baseInfo.BorrowToken.String(), chainId)
		_, lendToken := models.NewTokenInfo().GetTokenInfo(baseInfo.LendToken.String(), chainId)

		lendTokenJson, _ := json.Marshal(models.LendToken{
			LendFee:    lendFee.String(),
			TokenLogo:  lendToken.Logo,
			TokenName:  lendToken.Symbol,
			TokenPrice: lendToken.Price,
		})
		borrowTokenJson, _ := json.Marshal(models.BorrowToken{
			BorrowFee:  borrowFee.String(),
			TokenLogo:  borrowToken.Logo,
			TokenName:  borrowToken.Symbol,
			TokenPrice: borrowToken.Price,
		})

		poolBase := models.PoolBase{
			SettleTime:             baseInfo.SettleTime.String(),
			PoolId:                 utils.StringToInt(poolId),
			ChainId:                chainId,
			EndTime:                baseInfo.EndTime.String(),
			InterestRate:           baseInfo.InterestRate.String(),
			MaxSupply:              baseInfo.MaxSupply.String(),
			LendSupply:             baseInfo.LendSupply.String(),
			BorrowSupply:           baseInfo.BorrowSupply.String(),
			MartgageRate:           baseInfo.MartgageRate.String(),
			LendToken:              baseInfo.LendToken.String(),
			LendTokenSymbol:        lendToken.Symbol,
			LendTokenInfo:          string(lendTokenJson),
			BorrowToken:            baseInfo.BorrowToken.String(),
			BorrowTokenSymbol:      borrowToken.Symbol,
			BorrowTokenInfo:        string(borrowTokenJson),
			State:                  utils.IntToString(int(baseInfo.State)),
			SpCoin:                 baseInfo.SpCoin.String(),
			JpCoin:                 baseInfo.JpCoin.String(),
			AutoLiquidateThreshold: baseInfo.AutoLiquidateThreshold.String(),
		}

		hasInfoData, byteBaseInfoStr, baseInfoMd5Str := s.GetPoolMd5(&poolBase, "base_info:pool_"+chainId+"_"+poolId)
		if !hasInfoData || (baseInfoMd5Str != byteBaseInfoStr) { // have new data
			//tokenInfo
			err = models.NewPoolBase().SavePoolBase(chainId, poolId, &poolBase)
			if err != nil {
				log.Logger.Sugar().Error("SavePoolBase err ", chainId, poolId)
			}
			_ = db.RedisSet("base_info:pool_"+chainId+"_"+poolId, baseInfoMd5Str, 60*30) //The expiration time is set to prevent hsah collision
		}

		dataInfo, err := pledgePoolToken.PledgePoolTokenCaller.PoolDataInfo(nil, big.NewInt(int64(i)))
		if err != nil {
			log.Logger.Sugar().Info("UpdatePoolInfo PoolBaseInfo err", poolId, err)
			continue
		}

		hasPoolData, byteDataInfoStr, dataInfoMd5Str := s.GetPoolMd5(&poolBase, "data_info:pool_"+chainId+"_"+poolId)
		if !hasPoolData || (dataInfoMd5Str != byteDataInfoStr) { // have new data
			poolData := models.PoolData{
				PoolId:                 poolId,
				ChainId:                chainId,
				FinishAmountBorrow:     dataInfo.FinishAmountBorrow.String(),
				FinishAmountLend:       dataInfo.FinishAmountLend.String(),
				LiquidationAmounBorrow: dataInfo.LiquidationAmounBorrow.String(),
				LiquidationAmounLend:   dataInfo.LiquidationAmounLend.String(),
				SettleAmountBorrow:     dataInfo.SettleAmountBorrow.String(),
				SettleAmountLend:       dataInfo.SettleAmountLend.String(),
			}
			err = models.NewPoolData().SavePoolData(chainId, poolId, &poolData)
			if err != nil {
				log.Logger.Sugar().Error("SavePoolData err ", chainId, poolId)
			}
			_ = db.RedisSet("data_info:pool_"+chainId+"_"+poolId, dataInfoMd5Str, 60*30) //The expiration time is set to prevent hsah collision
		}
	}
}

func (s *poolService) GetPoolMd5(baseInfo *models.PoolBase, key string) (bool, string, string) {
	baseInfoBytes, _ := json.Marshal(baseInfo)
	baseInfoMd5Str := utils.Md5(string(baseInfoBytes))
	resInfoBytes, _ := db.RedisGet(key)
	if len(resInfoBytes) > 0 {
		return true, strings.Trim(string(resInfoBytes), `"`), baseInfoMd5Str
	} else {
		return false, strings.Trim(string(resInfoBytes), `"`), baseInfoMd5Str
	}
}

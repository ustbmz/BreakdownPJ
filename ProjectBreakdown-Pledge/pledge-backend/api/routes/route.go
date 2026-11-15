/* ============================================================================
 * 【学习注释 · 文件总览】route.go —— API 路由表（阶段三必读，一个文件看懂 API 面）
 *
 * 前端所有请求都挂在 /api/v21 这个版本前缀下（Version 从 configV21.toml 读）。
 * 路由共 10 条，分三组，读的时候问三个问题：
 *   ① 这个接口给前端页面哪个功能用？
 *   ② 带不带 CheckToken() 中间件？（带 = 需要登录态，数据更敏感）
 *   ③ controller 拿到参数后是查 MySQL 还是查 Redis？
 *
 * 核心接口（前端列表页就靠这两条）：
 *   GET  /poolBaseInfo   池子列表——参数 chainId（驼峰！curl 调试别写成 chain_id）
 *   GET  /poolDataInfo   池子成交额数据（settle/finish 金额）
 * 辅助接口：
 *   GET  /token          代币清单（符号/图标/价格）
 *   POST /pool/search    池子搜索（需登录）
 *   POST /pool/debtTokenList  sp/jp 凭证列表（需登录）
 *   GET  /price          PLGR 价格（对接库币交易所）
 * 管理接口：
 *   POST /pool/setMultiSign、/pool/getMultiSign  多签配置的读写
 * 用户体系：
 *   POST /user/login、/user/logout
 *
 * 验证方式（本地环境已跑通）：
 *   curl --noproxy '*' "http://127.0.0.1:8080/api/v21/poolBaseInfo?chainId=97"
 * ==========================================================================*/
package routes

import (
	"github.com/gin-gonic/gin"
	"pledge-backend/api/controllers"
	"pledge-backend/api/middlewares"
	"pledge-backend/config"
)

func InitRoute(e *gin.Engine) *gin.Engine {

	// version group
	v2Group := e.Group("/api/v" + config.Config.Env.Version)

	// pledge-defi backend
	poolController := controllers.PoolController{}
	v2Group.GET("/poolBaseInfo", poolController.PoolBaseInfo)                                   //pool base information
	v2Group.GET("/poolDataInfo", poolController.PoolDataInfo)                                   //pool data information
	v2Group.GET("/token", poolController.TokenList)                                             //pool token information
	v2Group.POST("/pool/debtTokenList", middlewares.CheckToken(), poolController.DebtTokenList) //pool debtTokenList
	v2Group.POST("/pool/search", middlewares.CheckToken(), poolController.Search)               //pool search

	// plgr-usdt price
	priceController := controllers.PriceController{}
	v2Group.GET("/price", priceController.NewPrice) //new price on ku-coin-exchange

	// pledge-defi admin backend
	multiSignPoolController := controllers.MultiSignPoolController{}
	v2Group.POST("/pool/setMultiSign", middlewares.CheckToken(), multiSignPoolController.SetMultiSign) //multi-sign set
	v2Group.POST("/pool/getMultiSign", middlewares.CheckToken(), multiSignPoolController.GetMultiSign) //multi-sign get

	userController := controllers.UserController{}
	v2Group.POST("/user/login", userController.Login)                             // login
	v2Group.POST("/user/logout", middlewares.CheckToken(), userController.Logout) // logout

	return e
}

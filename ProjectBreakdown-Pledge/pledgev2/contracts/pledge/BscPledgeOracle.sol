// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../multiSignature/multiSignatureClient.sol";
import "@chainlink/contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";



/* ============================================================================
 * 【学习注释 · 文件总览】BscPledgeOracle —— 自建预言机（清算公平性的命门）
 *
 * 双价格源设计（getUnderlyingPrice 里二选一）：
 *   ① assetsMap[资产] 有 Chainlink Aggregator → 用 latestRoundData() 读链上喂价
 *   ② 没配 Aggregator → 回退到 priceMap[资产]（管理员手动 setPrice 写死的价）
 *
 * ⚠️ 三个审计发现（学习报告素材，前两个是实际 bug）：
 *   1. setPrices() 的 bug：循环里写的是 priceMap[i]（数组下标）而不是
 *      priceMap[assets[i]]（资产地址）——批量设价会把价格写到 0,1,2… 下标上，
 *      与 getUnderlyingPrice 读 priceMap[资产地址] 完全对不上，等于没生效。
 *   2. 精度换算的潜在问题：tokenDecimals > 18 时算 (18-tokenDecimals) 会
 *      下溢（0.6 无内置溢出保护），10**负数下溢出极大值——除完后价格变小。
 *   3. priceMap 是管理员可随意写的价格源：多签若作恶，settle 撮合比例和
 *      清算触发都可以被操纵。生产环境应当只信任 Chainlink + 偏差检查。
 *
 * 对照学习：现代项目（Aave/Compound）的 Oracle 还会做 heartbeat 检查、
 * 双源交叉验证、 TWAP——读完这份代码再看那些项目就懂为什么了。
 * ==========================================================================*/

contract BscPledgeOracle is multiSignatureClient {

    mapping(uint256 => AggregatorV3Interface) internal assetsMap;
    mapping(uint256 => uint256) internal decimalsMap;
    mapping(uint256 => uint256) internal priceMap;
    uint256 internal decimals = 1;

    constructor(address multiSignature) multiSignatureClient(multiSignature) public {
//        //  bnb/USD
//        assetsMap[uint256(0x0000000000000000000000000000000000000000)] = AggregatorV3Interface(0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526);
//        // DAI/USD
//        assetsMap[uint256(0xf2bDB4ba16b7862A1bf0BE03CD5eE25147d7F096)] = AggregatorV3Interface(0xE4eE17114774713d2De0eC0f035d4F7665fc025D);
//        // BTC/USD
//        assetsMap[uint256(0xF592aa48875a5FDE73Ba64B527477849C73787ad)] = AggregatorV3Interface(0x5741306c21795FdCBb9b265Ea0255F499DFe515C);
//        // BUSD/USD
//        assetsMap[uint256(0xDc6dF65b2fA0322394a8af628Ad25Be7D7F413c2)] = AggregatorV3Interface(0x9331b55D9830EF609A2aBCfAc0FBCE050A52fdEa);
//
//
//        decimalsMap[uint256(0x0000000000000000000000000000000000000000)] = 18;
//        decimalsMap[uint256(0xf2bDB4ba16b7862A1bf0BE03CD5eE25147d7F096)] = 18;
//        decimalsMap[uint256(0xF592aa48875a5FDE73Ba64B527477849C73787ad)] = 18;
//        decimalsMap[uint256(0xDc6dF65b2fA0322394a8af628Ad25Be7D7F413c2)] = 18;

    }

    /**
      * @notice set the precision
      * @dev function to update precision for an asset
      * @param newDecimals replacement oldDecimal
      */
    function setDecimals(uint256 newDecimals) public validCall{
        decimals = newDecimals;
    }


    /* ------------------------------------------------------------
     * 【学习注释】setPrices() —— ⚠️ 有 bug 的函数，注意读法
     * 意图：批量设价 priceMap[assets[i]] = prices[i]
     * 实际：priceMap[i] = prices[i] —— 写成了数组下标！
     * 后果：设了价也查不到（查询按资产地址取 key），整个函数形同虚设。
     * 这个 bug 之所以一直没被发现，是因为主路径走的是 Chainlink 聚合器，
     * priceMap 回退路径几乎没人用——"没被走过的路最容易出现坏代码"。
     * ------------------------------------------------------------ */
    /**
      * @notice Set prices in bulk
      * @dev function to update prices for an asset
      * @param prices replacement oldPrices
      */
    function setPrices(uint256[]memory assets,uint256[]memory prices) external validCall {
        require(assets.length == prices.length, "input arrays' length are not equal");
        uint256 len = assets.length;
        for (uint i=0;i<len;i++){
            priceMap[i] = prices[i];
        }
    }

    /**
      * @notice retrieve prices of assets in bulk
      * @dev function to get price for an assets
      * @param  assets Asset for which to get the price
      * @return uint mantissa of asset price (scaled by 1e8) or zero if unset or contract paused
      */
    function getPrices(uint256[]memory assets) public view returns (uint256[]memory) {
        uint256 len = assets.length;
        uint256[] memory prices = new uint256[](len);
        for (uint i=0;i<len;i++){
            prices[i] = getUnderlyingPrice(assets[i]);
        }
        return prices;
    }

    /**
      * @notice retrieves price of an asset
      * @dev function to get price for an asset
      * @param asset Asset for which to get the price
      * @return uint mantissa of asset price (scaled by 1e8) or zero if unset or contract paused
      */
    function getPrice(address asset) public view returns (uint256) {
        return getUnderlyingPrice(uint256(asset));
    }

    /* ------------------------------------------------------------
     * 【学习注释】getUnderlyingPrice() —— 价格读取的决策树（本合约最核心函数）
     *
     * 有 Chainlink 聚合器？──是──→ latestRoundData() 取最新喂价
     *        │否                    按代币精度换算到统一精度（见下方⚠️）
     *        ▼
     *   回退 priceMap[资产]（管理员手动定价，可被操纵的口子）
     *
     * ⚠️ 精度换算那三行：tokenDecimals > 18 时 (18-tokenDecimals) 是负数，
     * Solidity 0.6 的 uint 指数运算会下溢出天文数字——价格被除到接近 0。
     * BSC 上主流代币精度都 ≤ 18 所以平时踩不到，但这是个埋着的雷。
     * ------------------------------------------------------------ */
    /**
      * @notice get price based on index
      * @dev function to get price for index
      * @param underlying for which to get the price
      * @return uint mantissa of asset price (scaled by 1e8) or zero if unset or contract paused
      */
    function getUnderlyingPrice(uint256 underlying) public view returns (uint256) {
        AggregatorV3Interface assetsPrice = assetsMap[underlying];
        if (address(assetsPrice) != address(0)){
            (, int price,,,) = assetsPrice.latestRoundData();
            uint256 tokenDecimals = decimalsMap[underlying];
            if (tokenDecimals < 18){
                return uint256(price)/decimals*(10**(18-tokenDecimals));
            }else if (tokenDecimals > 18){
                return uint256(price)/decimals/(10**(18-tokenDecimals));
            }else{
                return uint256(price)/decimals;
            }
        }else {
            return priceMap[underlying];
        }
    }


    /**
      * @notice set price of an asset
      * @dev function to set price for an asset
      * @param asset Asset for which to set the price
      * @param price the Asset's price
      */
    function setPrice(address asset,uint256 price) public validCall {
        priceMap[uint256(asset)] = price;
    }

    /**
      * @notice set price of an underlying
      * @dev function to set price for an underlying
      * @param underlying underlying for which to set the price
      * @param price the underlying's price
      */
    function setUnderlyingPrice(uint256 underlying,uint256 price) public validCall {
        require(underlying>0 , "underlying cannot be zero");
        priceMap[underlying] = price;
    }

    /**
      * @notice set price of an asset
      * @dev function to set price for an asset
      * @param asset Asset for which to set the price
      * @param aggergator the Asset's aggergator
      */
    function setAssetsAggregator(address asset,address aggergator,uint256 _decimals) public validCall {
        assetsMap[uint256(asset)] = AggregatorV3Interface(aggergator);
        decimalsMap[uint256(asset)] = _decimals;
    }

    /**
      * @notice set price of an underlying
      * @dev function to set price for an underlying
      * @param underlying underlying for which to set the price
      * @param aggergator the underlying's aggergator
      */
    function setUnderlyingAggregator(uint256 underlying,address aggergator,uint256 _decimals) public validCall {
        require(underlying>0 , "underlying cannot be zero");
        assetsMap[underlying] = AggregatorV3Interface(aggergator);
        decimalsMap[underlying] = _decimals;
    }

    /** @notice get asset aggregator based on asset
      * @dev function to get aggregator for asset
      * @param asset for which to get the aggregator
      * @ return  an asset aggregator
      */
    function getAssetsAggregator(address asset) public view returns (address,uint256) {
        return (address(assetsMap[uint256(asset)]),decimalsMap[uint256(asset)]);
    }

     /**
       * @notice get asset aggregator based on index
       * @dev function to get aggregator for index
       * @param underlying for which to get the aggregator
       * @ return an asset aggregator
       */
    function getUnderlyingAggregator(uint256 underlying) public view returns (address,uint256) {
        return (address(assetsMap[underlying]),decimalsMap[underlying]);
    }

}

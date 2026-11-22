// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* ============================================================================
 * 【学习注释 · 第 3 课】手续费刻度
 *
 * TOTAL_SHARE = 10000 表示 100%。protocolShare = 250 就是 2.5%。
 * 成交价 1 ETH → 协议费 0.025 ETH，卖家到账 0.975 ETH。
 * 费从成交价里扣，先留在 OrderBook，Owner 以后 withdrawETH 提走，成交当时不打给 Owner。
 * MAX_PROTOCOL_SHARE = 1000，上限 10%。
 * ==========================================================================*/
library LibPayInfo {
    //total share in percentage, 10,000 = 100%
    uint128 public constant TOTAL_SHARE = 10000;
    uint128 public constant MAX_PROTOCOL_SHARE = 1000;
    bytes32 public constant TYPE_HASH =
        keccak256("PayInfo(address receiver,uint96 share)");

    struct PayInfo {
        address payable receiver;
        // Share of funds. 
        // Basis point format.
        uint96 share;
    }

    function hash(PayInfo memory info) internal pure returns (bytes32) {
        return keccak256(abi.encode(TYPE_HASH, info.receiver, info.share));
    }
}

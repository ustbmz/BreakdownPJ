// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Price} from "./RedBlackTreeLibrary.sol";

type OrderKey is bytes32;

/* ============================================================================
 * 【学习注释 · 第 1 课】订单长什么样
 *
 * OrderKey = hash(整张 Order)。price、salt、expiry 任一改动，key 就变。
 * 所以改价不能原地改字段，只能取消旧单、再挂一张新单（见 OrderBook._editOrderTry）。
 *
 * hash 不算 filledAmount。成交了多少、有没有取消，记在 OrderValidator.filledAmount。
 *
 * ORDERKEY_SENTINEL = 0x0，表示「这一格失败 / 空」。makeOrders 某一单没做成，
 * 返回数组对应位置就是它，整笔交易不一定 revert。
 *
 * List 的 amount 业务上必须是 1：一件 ERC721。Bid 的 amount 可以大于 1，
 * 那是「这个价买好几件」的集合出价，才会出现部分成交。
 * ==========================================================================*/
library LibOrder {
    /// 订单方向：谁发起、锁进金库的是什么。
    enum Side {
        List, // 卖单。卖家锁 NFT，等买家来付 ETH
        Bid // 买单。买家锁 ETH，等卖家来交 NFT
    }

    /// 这张单锁的是「某一件」还是「这个合集里任意一件」。
    enum SaleKind {
        FixedPriceForCollection, // 只出现在 Bid：这个价买该合集任意 NFT，成交时 tokenId 以卖单为准
        FixedPriceForItem // 指定 collection + tokenId。List 只能是这一种
    }

    /// 订单要交易的 NFT。三个字段都进 OrderKey。
    struct Asset {
        uint256 tokenId; // 哪一件。集合 Bid 的这个值在撮合时不看
        address collection; // ERC721 合约地址，盘口按它分树
        uint96 amount; // 件数。List 必须是 1；集合 Bid 可以 >1，才会部分成交
    }

    /// 查询用的「哪一件」，没有 amount，不参与 hash。
    struct NFTInfo {
        address collection; // ERC721 合约地址
        uint256 tokenId; // 这一件的编号
    }

    /// 一张订单的全部身份。hash(Order) 得到 OrderKey，成交进度不在这里。
    struct Order {
        Side side; // List 或 Bid
        SaleKind saleKind; // 单品还是合集
        address maker; // 下单人。挂单时必须是 msg.sender；撮合时 msg.sender 必须是两边 maker 之一
        Asset nft; // 标的
        Price price; // 单价，单位 wei。买 2 件要锁 price × 2
        uint64 expiry; // 过期时间戳。0 = 永不过期
        uint64 salt; // 不能为 0。同样的价再挂一单，靠它得到不同的 OrderKey
    }

    /// 盘口上存的节点：订单本体 + 同价队列里的下一单。
    struct DBOrder {
        Order order; // 这张单
        OrderKey next; // 同一价格档里、排在后面的那张；0x0 表示后面没有了
    }

    /// 同一个 collection、同一个 side、同一个单价上的队列。先挂的在 head，新单接到 tail。
    struct OrderQueue {
        OrderKey head; // 这一档最先成交的那张
        OrderKey tail; // 这一档最后挂上的那张
    }

    /// editOrders 的入参：旧 key 取消，再用新 Order 挂一张。
    struct EditDetail {
        OrderKey oldOrderKey; // 要改掉的那张
        LibOrder.Order newOrder; // 改完的内容。price / salt 变了，key 一定变
    }

    /// matchOrder 的入参：一张卖单配一张买单，调用者必须是其中一边的 maker。
    struct MatchDetail {
        LibOrder.Order sellOrder; // 卖单，side 必须是 List
        LibOrder.Order buyOrder; // 买单，side 必须是 Bid
    }

    OrderKey public constant ORDERKEY_SENTINEL = OrderKey.wrap(0x0);

    bytes32 public constant ASSET_TYPEHASH =
        keccak256("Asset(uint256 tokenId,address collection,uint96 amount)");

    bytes32 public constant ORDER_TYPEHASH =
        keccak256(
            "Order(uint8 side,uint8 saleKind,address maker,Asset nft,uint128 price,uint64 expiry,uint64 salt)Asset(uint256 tokenId,address collection,uint96 amount)"
        );

    function hash(Asset memory asset) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    ASSET_TYPEHASH,
                    asset.tokenId,
                    asset.collection,
                    asset.amount
                )
            );
    }

    /// 整单哈希。不含 filledAmount，成交进度不在这张结构体里。
    function hash(Order memory order) internal pure returns (OrderKey) {
        return
            OrderKey.wrap(
                keccak256(
                    abi.encodePacked(
                        ORDER_TYPEHASH,
                        order.side,
                        order.saleKind,
                        order.maker,
                        hash(order.nft),
                        Price.unwrap(order.price),
                        order.expiry,
                        order.salt
                    )
                )
            );
    }

    function isSentinel(OrderKey orderKey) internal pure returns (bool) {
        return OrderKey.unwrap(orderKey) == OrderKey.unwrap(ORDERKEY_SENTINEL);
    }

    function isNotSentinel(OrderKey orderKey) internal pure returns (bool) {
        return OrderKey.unwrap(orderKey) != OrderKey.unwrap(ORDERKEY_SENTINEL);
    }
}

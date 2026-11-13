//! Shops show their stock (see `assets.tables.shop`), but nothing can be bought yet:
//! the server doesn't keep an inventory of ordinary items to put a purchase into.

const std = @import("std");

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const assets = roze.assets;
const Scope = roze.Scope;

const log = std.log.scoped(.@"roze::commands::shop");

/// How many shops a single `CS_MULTI_SHOP_GOODS` is answered for.
const shops_per_request_max = 64;

/// The stock of each shop of `assets.tables.shop`, in the shape the client wants it. Same order.
const shop_goods: []const []const protobuf.gen.ShopGoodsInfo = shop_goods: {
    @setEvalBranchQuota(100_000);

    var result: [assets.tables.shop.len][]const protobuf.gen.ShopGoodsInfo = undefined;

    for (&result, assets.tables.shop) |*goods_out, shop| {
        var goods: [shop.goods.len]protobuf.gen.ShopGoodsInfo = undefined;
        for (&goods, shop.goods) |*info, config| info.* = .{
            .id = config.id,
            .money_id = config.money_id,
            .money_num = config.money_num,
            .precond_met = true,
        };

        const final_goods = goods;
        goods_out.* = &final_goods;
    }

    const final = result;
    break :shop_goods &final;
};

/// Shops we don't know of are empty.
fn goodsOf(shop_id: i32) []const protobuf.gen.ShopGoodsInfo {
    for (assets.tables.shop, shop_goods) |shop, goods| {
        if (shop.id == shop_id) return goods;
    }

    log.debug("shop {d} is not in the table", .{shop_id});
    return &.{};
}

pub fn CS_SHOP_GOODS(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Shop_Goods.Decoded);
    log.info("goods of shop {d} requested", .{request.shop_id});

    try scope.sink.send(.SC_SHOP_GOODS, @as(protobuf.gen.SC_Shop_Goods, .{
        .shop_id = request.shop_id,
        .goods = goodsOf(request.shop_id),
    }));
}

pub fn CS_MULTI_SHOP_GOODS(scope: *Scope) Scope.Error!void {
    var request = try scope.command.take(protobuf.gen.CS_Multi_Shop_Goods.Decoded);

    var shop_infos_buf: [shops_per_request_max]protobuf.gen.ShopInfo = undefined;
    var count: usize = 0;

    // The client looks its shops up in the response, so each one it asked for has to be there.
    while (try request.shop_ids.next()) |shop_id| {
        if (count == shop_infos_buf.len) break;

        shop_infos_buf[count] = .{ .shop_id = shop_id, .goods = goodsOf(shop_id) };
        count += 1;
    }

    try scope.sink.send(.SC_MULTI_SHOP_GOODS, @as(
        protobuf.gen.SC_Multi_Shop_Goods,
        .{ .shop_infos = shop_infos_buf[0..count] },
    ));
}

pub fn CS_SHOP_BUY(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Shop_Buy.Decoded);
    log.info("purchase in shop {d} refused", .{request.shop_id});

    try scope.sink.send(.SC_SHOP_BUY, @as(
        protobuf.gen.SC_Shop_Buy,
        .{ .result = -1, .shop_id = request.shop_id },
    ));
}

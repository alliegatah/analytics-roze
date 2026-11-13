const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const assets = roze.assets;
const Gameplay = roze.Gameplay;
const Scope = roze.Scope;
const MotiveUniqueId = Gameplay.Character.MotiveUniqueId;

/// How many of each wind road ("Circuitway") unlock item the player has.
const wind_road_item_count = 99;

pub fn CS_ITEM_BAG_GET_LIST(scope: *Scope) Scope.Error!void {
    const wind_road_end = MotiveUniqueId.count + assets.tables.wind_road_item.len;
    const normal_count = wind_road_end + assets.tables.catalyst.len;
    var items: [normal_count + assets.tables.abyss_reward_item.len]protobuf.gen.CmdItem = undefined;

    // Weapons live in the bag as items that carry their own state.
    for (items[0..MotiveUniqueId.count], 0..) |*item, instance| {
        const uid: MotiveUniqueId = .fromInstance(instance);
        const config = uid.config();

        item.* = .{
            .item_id = config.item_id,
            .item_num = 1,
            .bind_id = uid.toInt(),
            .item_uniq_data = .{ .motive_data = .{
                .motive_uniq_id = uid.toInt(),
                .claim_time = scope.time.toMilliseconds(),
                .level = config.level,
                .refine = scope.gameplay.transient.sandbox.refineOf(uid),
                .break_level = config.break_level,
            } },
        };
    }

    for (items[MotiveUniqueId.count..wind_road_end], assets.tables.wind_road_item) |*item, item_id| {
        item.* = .{
            .item_id = item_id,
            .item_num = wind_road_item_count,
            // For ordinary items the bind id is the item id.
            .bind_id = item_id,
        };
    }
    for (items[wind_road_end..normal_count], assets.tables.catalyst) |*item, item_id|
        item.* = .{ .item_id = item_id, .item_num = 1, .bind_id = item_id };
    for (items[normal_count..], assets.tables.abyss_reward_item, scope.gameplay.abyss.items) |*item, id, count|
        item.* = .{ .item_id = id, .bind_id = id, .item_num = count };

    try scope.sink.send(.SC_ITEM_BAG_GET_LIST, @as(
        protobuf.gen.SC_Item_Bag_Get_List,
        .{ .items = &items },
    ));
}

//! Liquid silver creatures. The player owns one of each; which one is taken into battle
//! is only remembered until logout.

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const assets = roze.assets;
const Scope = roze.Scope;

/// A creature's unique id is its position in `assets.tables.silver_creature`, counted from 1.
const creatures: []const protobuf.gen.SilverCreatureInfo = creatures: {
    const table = assets.tables.silver_creature;
    var result: [table.len]protobuf.gen.SilverCreatureInfo = undefined;

    for (&result, table, 1..) |*info, config, uniq_id| info.* = .{
        .silver_creature_id = config.id,
        .uniq_id = uniq_id,
        .level = config.level,
    };

    const final = result;
    break :creatures &final;
};

pub fn CS_SILVER_CREATURE_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_SILVER_CREATURE_RSP, @as(protobuf.gen.SC_Silver_Creature_Rsp, .{
        .silver_creature_info_list = creatures,
        .in_battle_uniq_id = scope.gameplay.transient.silver_creature_uniq_id,
    }));
}

pub fn CS_REQ_SILVER_CREATURE_IN_BATTLE(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Req_Silver_Creature_In_Battle.Decoded);

    if (request.uniq_id == 0 or request.uniq_id > creatures.len) {
        return try scope.sink.send(.SC_RES_SILVER_CREATURE_IN_BATTLE_RESULT, @as(
            protobuf.gen.SC_Res_Silver_Creature_In_Battle_Result,
            .{ .result = -1 },
        ));
    }

    scope.gameplay.transient.silver_creature_uniq_id = request.uniq_id;

    try scope.sink.send(.SC_RES_SILVER_CREATURE_IN_BATTLE_RESULT, @as(
        protobuf.gen.SC_Res_Silver_Creature_In_Battle_Result,
        .{ .uniq_id = request.uniq_id },
    ));
}

pub fn CS_REQ_SILVER_CREATURE_LEAVE_BATTLE(scope: *Scope) Scope.Error!void {
    const uniq_id = scope.gameplay.transient.silver_creature_uniq_id;
    scope.gameplay.transient.silver_creature_uniq_id = 0;

    try scope.sink.send(.SC_RES_SILVER_CREATURE_LEAVE_BATTLE_RESULT, @as(
        protobuf.gen.SC_Res_Silver_Creature_Leave_Battle_Result,
        .{ .uniq_id = uniq_id },
    ));
}

const std = @import("std");

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

const log = std.log.scoped(.@"roze::commands::dungeons");

/// Every dungeon group is open for battle.
const group_states: []const protobuf.gen.OneDungeonsGroupState = group_states: {
    const table = roze.assets.tables.dungeon_group;
    var result: [table.len]protobuf.gen.OneDungeonsGroupState = undefined;

    for (&result, table) |*state, group_id| state.* = .{
        .dungeons_group_id = group_id,
        .state = @backingInt(protobuf.gen.EnmDungeonsGroupState.EDGS_UNLOCK),
    };

    const final = result;
    break :group_states &final;
};

pub fn CS_DUNGEONS_FULL_DATA(scope: *Scope) Scope.Error!void {
    try scope.sink.send(
        .SC_DUNGEONS_FULL_DATA,
        @as(protobuf.gen.SC_Dungeons_Full_Data, .{
            .data = .{
                .common_data = .init,
                .horde_data = .init,
                .wait_reward_data = .init,
                .group_state_data = .{ .list = group_states },
            },
        }),
    );
}

// The dungeon handlers below don't validate anything against the dungeon tables (we don't
// have them), they acknowledge whatever the client asks for. The encounters themselves are
// spawned and simulated by the client.

pub fn CS_DUNGEONS_ENTER(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Dungeons_Enter.Decoded);
    if (scope.gameplay.abyss.run.abyss_id != 0) return scope.sink.send(.SC_DUNGEONS_ENTER, @as(protobuf.gen.SC_Dungeons_Enter, .{ .result = 207, .dungeons_id = request.dungeons_id }));
    log.info("entering dungeon {d}", .{request.dungeons_id});

    scope.gameplay.transient.dungeon_id = request.dungeons_id;
    scope.gameplay.transient.dungeon_battle_id = 0;

    try scope.sink.send(.SC_DUNGEONS_ENTER, @as(
        protobuf.gen.SC_Dungeons_Enter,
        .{ .dungeons_id = request.dungeons_id },
    ));
}

pub fn CS_DUNGEONS_ENTER_ALREADY(scope: *Scope) Scope.Error!void {
    const transient = &scope.gameplay.transient;
    const run = &scope.gameplay.abyss.run;
    if (run.abyss_id != 0) {
        var times: [roze.Gameplay.Abyss.rooms_max]i64 = undefined;
        for (times[0..run.completed], run.times[0..run.completed]) |*out, time| out.* = @intCast(time);
        return scope.sink.send(.SC_DUNGEONS_ENTER_ALREADY, @as(protobuf.gen.SC_Dungeons_Enter_Already, .{
            .cur_system = .EST_ABYSS,
            .abyss_info = .{ .abyss_id = run.abyss_id, .layer = run.layer, .room = run.room, .finish_time = times[0..run.completed] },
        }));
    }

    const response: protobuf.gen.SC_Dungeons_Enter_Already = if (transient.dungeon_id != 0) .{
        .cur_system = .EST_DUNGEONS,
        .dungeons_info = .{
            .dungeons_id = @truncate(transient.dungeon_id),
            .battle_id = transient.dungeon_battle_id,
        },
    } else .{
        .cur_system = .EST_INVALID,
    };

    try scope.sink.send(.SC_DUNGEONS_ENTER_ALREADY, response);
}

pub fn CS_DUNGEONS_CURRENT_DATA(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Dungeons_Current_Data.Decoded);

    const info: protobuf.gen.DungeonsCurrentData = if (request.info) |info| .{
        .dungeons_id = info.dungeons_id,
        .battle_id = info.battle_id,
    } else .init;

    log.info("dungeon {d} progress: battle {d} done", .{ info.dungeons_id, info.battle_id });
    scope.gameplay.transient.dungeon_battle_id = info.battle_id;

    try scope.sink.send(.SC_DUNGEONS_CURRENT_DATA, @as(
        protobuf.gen.SC_Dungeons_Current_Data,
        .{ .info = info },
    ));
}

pub fn CS_DUNGEONS_FINISH(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Dungeons_Finish.Decoded);
    log.info("finished dungeon {d} (victory: {}, leave: {}, replay: {})", .{
        request.dungeons_id,
        request.victory,
        request.leave,
        request.replay,
    });

    scope.gameplay.transient.dungeon_battle_id = 0;
    // On replay the client stays inside and follows up with `CS_DUNGEONS_REPLAY`.
    if (!request.replay) scope.gameplay.transient.dungeon_id = 0;

    try scope.sink.send(.SC_DUNGEONS_FINISH, @as(
        protobuf.gen.SC_Dungeons_Finish,
        .{
            .team_lv_before = scope.level.team,
            .team_lv_after = scope.level.team,
        },
    ));
}

pub fn CS_DUNGEONS_REPLAY(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Dungeons_Replay.Decoded);
    if (scope.gameplay.abyss.run.abyss_id != 0) return scope.sink.send(.SC_DUNGEONS_REPLAY, @as(protobuf.gen.SC_Dungeons_Replay, .{ .result = 207, .dungeons_id = request.dungeons_id }));
    log.info("replaying dungeon {d}", .{request.dungeons_id});

    scope.gameplay.transient.dungeon_id = request.dungeons_id;
    scope.gameplay.transient.dungeon_battle_id = 0;

    try scope.sink.send(.SC_DUNGEONS_REPLAY, @as(
        protobuf.gen.SC_Dungeons_Replay,
        .{ .dungeons_id = request.dungeons_id },
    ));
}

pub fn CS_DUNGEONS_GROUP_UNLOCK_REQ(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Dungeons_Group_Unlock_Req.Decoded);
    log.info("unlocking dungeon group {d}", .{request.dungeons_group_id});

    try scope.sink.send(.SC_DUNGEONS_GROUP_UNLOCK_RSP, @as(
        protobuf.gen.SC_Dungeons_Group_Unlock_Rsp,
        .{ .dungeons_group_id = request.dungeons_group_id },
    ));
}

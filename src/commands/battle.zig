const std = @import("std");

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Gameplay = roze.Gameplay;
const Scope = roze.Scope;
const assets = roze.assets;

pub fn CS_ENTER_BATTLE(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Enter_Battle.Decoded);

    try scope.sink.send(.SC_ENTER_BATTLE, @as(
        protobuf.gen.SC_Enter_Battle,
        .{
            .battle_uid = (@as(u64, request.battle_field_id) << 32) | request.battle_inst_id,
            .battle_type = request.battle_type,
            .battle_field_id = request.battle_field_id,
            .random_seed = @truncate(scope.time.toMilliseconds()),
        },
    ));
}

pub fn CS_START_BATTLE(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Start_Battle.Decoded);

    try scope.sink.send(.SC_START_BATTLE, @as(
        protobuf.gen.SC_Start_Battle,
        .{
            .battle_uid = request.battle_uid,
            .battle_type = request.battle_type,
            .battle_field_id = request.battle_field_id,
        },
    ));
}

pub fn CS_PAUSE_BATTLE(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Pause_Battle.Decoded);

    try scope.sink.send(.SC_PAUSE_BATTLE, @as(
        protobuf.gen.SC_Pause_Battle,
        .{
            .battle_uid = request.battle_uid,
            .battle_type = request.battle_type,
            .battle_field_id = request.battle_field_id,
            .pause = request.pause,
        },
    ));
}

pub fn CS_LEAVE_BATTLE(scope: *Scope) Scope.Error!void {
    const log = std.log.scoped(.@"roze::commands::leave_battle");

    var request = try scope.command.take(protobuf.gen.CS_Leave_Battle.Decoded);
    var state_save_needed: bool = false;

    const battle_result = request.battle_result orelse {
        log.debug("invalid battle result", .{});
        return try scope.sink.send(.SC_LEAVE_BATTLE, @as(
            protobuf.gen.SC_Leave_Battle,
            .{ .ret = -1 },
        ));
    };

    const hp_needs_refill = switch (battle_result) {
        .ENM_BATTLE_RESULT_TYPE_DEAD_FAIL => true,
        else => false,
    };

    const character = &scope.gameplay.character;
    while (try request.character_data.next()) |character_data| {
        const character_index = Gameplay.Character.Index.fromInstId(character_data.inst_id) orelse continue;

        const hp_new = if (hp_needs_refill)
            roze.stats.maxHp(scope.asset_index, scope.gameplay, character_index)
        else
            character_data.current_hp;

        character.snapshots[character_index.toInt()] = .wrap(.{
            .hp = hp_new,
            .permanent_liquid = character_data.permanent_liquid,
        });
        state_save_needed = true;

        try scope.notifyCharacterAttrib(character_index);
    }

    const extra_info: ?protobuf.gen.BattleExtraInfo = switch (battle_result) {
        .ENM_BATTLE_RESULT_TYPE_DEAD_FAIL => .{
            .reborn_map_id = scope.gameplay.map.id,
            .reborn_savepoint = assets.npc_lists.save_point_npc_ids[scope.gameplay.map.save_point_index],
        },
        else => null,
    };

    try scope.sink.send(.SC_LEAVE_BATTLE, @as(
        protobuf.gen.SC_Leave_Battle,
        .{
            .battle_uid = request.battle_uid,
            .battle_type = request.battle_type,
            .battle_field_id = request.battle_field_id,
            .battle_result = request.battle_result,
            .extra_info = extra_info,
        },
    ));

    errdefer comptime unreachable; // Ensure that it's safe to request save.
    if (state_save_needed) scope.store.requestGameplayStateSave();
}

const std = @import("std");
const roze = @import("../roze.zig");
const p = roze.protobuf.gen;
const Scope = roze.Scope;
const Abyss = roze.Gameplay.Abyss;
const tables = roze.assets.tables;
const log = std.log.scoped(.@"roze::commands::abyss");

const RoomTeam = struct {
    room: u32,
    members: roze.Gameplay.Character.Team.Members,
    slot: roze.Gameplay.Character.Team.Slot,

    fn forRoom(scope: *Scope, room: u32) ?RoomTeam {
        const index = Abyss.roomIndex(room) orelse return null;
        const members = scope.gameplay.abyss_teams[index];
        for (members, 0..) |member, i| {
            if (member != .none) return .{ .room = room, .members = members, .slot = @fromBackingInt(@intCast(i)) };
        }
        return null;
    }

    fn notify(team: RoomTeam, scope: *Scope) Scope.Error!void {
        const packers = roze.protobuf.packers;
        var team_buffer: packers.Buffer(packers.TeamDataBuffer, 1) = undefined;
        var teams = team_buffer.toList();
        packers.packTeamData(&teams, @fromBackingInt(0), team.members, scope.gameplay.catalysts.abyss[Abyss.roomIndex(team.room).?]);
        teams.items(.data)[0].team_id = team.room;
        var attrib_buffer: packers.Buffer(packers.CharacterAttribDataBuffer, 4) = undefined;
        var attrib = attrib_buffer.toList();
        for (team.members) |member| if (member.unwrap()) |ci|
            packers.packCharacterAttribDataWith(scope.asset_index, &attrib, scope.gameplay, ci, .full);
        try scope.sink.send(.SC_CHARACTER_TEMP_TEAM_NTF, @as(p.SC_Character_Temp_Team_Ntf, .{
            .cur_team = .{
                .team_type = 5,
                .team_src = .{ .src = team.room },
                .using_member_slot = team.slot.toSlotId(),
                .team_data = teams.items(.data)[0],
                .temporary_liquid = .init,
                .attrib_data = attrib.items(.data),
            },
        }));
    }
};

// These expired CBT2 rotations stay playable on the local sandbox. They do not reset.
const active_modes: [Abyss.mode_count]p.CmdActiveAbyssInfo = active: {
    var out: [Abyss.mode_count]p.CmdActiveAbyssInfo = undefined;
    for (&out, tables.abyss) |*entry, mode| entry.* = .{
        .abyss_id = mode.id,
        .start_time = 1,
        .end_time = std.math.maxInt(u32),
    };
    break :active out;
};

pub fn CS_REQ_ABYSS_INFO(scope: *Scope) Scope.Error!void {
    _ = try scope.command.take(p.CS_Req_Abyss_Info.Decoded);
    const state = &scope.gameplay.abyss;
    var modes: [Abyss.mode_count]p.CmdOneAbyssData = undefined;
    var layers: [Abyss.layer_count]p.CmdOneLayerData = undefined;
    var rooms: [Abyss.layer_count][Abyss.rooms_max]p.CmdRoomInfo = undefined;
    var offset: usize = 0;
    for (tables.abyss, 0..) |mode, mi| {
        const start = offset;
        for (mode.layers) |layer| {
            const saved = &state.layers[offset];
            var room_n: usize = 0;
            for (layer.rooms, 0..) |id, ri| {
                if (saved.times[ri] == 0) continue;
                rooms[offset][room_n] = .{ .room_id = id, .finish_time = saved.times[ri] };
                room_n += 1;
            }
            // The client uses is_passed to unlock the next layer. Keep all layers
            // selectable in the sandbox while stars, times and rewards stay earned.
            layers[offset] = .{ .layer = layer.index, .room_list = rooms[offset][0..room_n], .star = saved.star, .is_passed = true };
            offset += 1;
        }
        modes[mi] = .{ .abyss_id = mode.id, .layer_list = layers[start..offset], .star_total = state.total(mi), .star_awarded = state.claimed[mi] };
    }
    try scope.sink.send(.SC_RES_ABYSS_INFO, @as(p.SC_Res_Abyss_Info, .{
        .abyss_data = .{ .abyss_list = &modes, .cur_abyss_id = state.run.abyss_id, .cur_layer = state.run.layer, .cur_room = state.run.room },
        .active_abyss_list = &active_modes,
    }));
}

pub fn CS_REQ_ABYSS_ENTER(scope: *Scope) Scope.Error!void {
    const req = try scope.command.take(p.CS_Req_Abyss_Enter.Decoded);
    var next = scope.gameplay.abyss;
    next.enter(req.abyss_id, req.layer, req.room) catch |err| {
        return scope.sink.send(.SC_RES_ABYSS_ENTER, @as(p.SC_Res_Abyss_Enter, .{ .result = Abyss.result(err) }));
    };
    const location = Abyss.locate(req.abyss_id, req.layer) catch unreachable; // Validated by enter.
    const room = location.config.rooms[req.room - 1];
    const team = RoomTeam.forRoom(scope, room) orelse {
        log.warn("cannot enter Abyss {d} layer {d}: room {d} has no team", .{ req.abyss_id, req.layer, room });
        return scope.sink.send(.SC_RES_ABYSS_ENTER, @as(p.SC_Res_Abyss_Enter, .{ .result = 207 }));
    };
    const output_start = scope.sink.end.*;
    const seq_start = scope.sink.send_seq.*;
    errdefer {
        scope.sink.end.* = output_start;
        scope.sink.send_seq.* = seq_start;
    }
    // This acknowledgement starts map travel. Do not send a live team-switch
    // notification in the departing scene: TeamData.OnTempTeamNtf can call
    // ForceStartAssembleCharactersFromLua before the destination's battle data
    // is initialized. Select the team server-side; the destination receives it
    // through the normal CS_CHARACTER_TEAMS initialization reply.
    try scope.sink.send(.SC_RES_ABYSS_ENTER, @as(p.SC_Res_Abyss_Enter, .{}));
    scope.gameplay.abyss = next;
    scope.gameplay.transient.abyss_team_room = team.room;
    scope.gameplay.transient.abyss_using_slot = team.slot;
    scope.gameplay.transient.dungeon_id = 0;
    scope.gameplay.transient.dungeon_battle_id = 0;
    scope.store.requestGameplayStateSave();
}

pub fn CS_REQ_ABYSS_ENTER_ALREADY(scope: *Scope) Scope.Error!void {
    _ = try scope.command.take(p.CS_Req_Abyss_Enter_Already.Decoded);
    const run = &scope.gameplay.abyss.run;
    try scope.sink.send(.SC_RES_ABYSS_ENTER_ALREADY, @as(p.SC_Res_Abyss_Enter_Already, .{
        .result = if (run.abyss_id == 0) 4408 else 0,
        .abyss_id = run.abyss_id,
        .layer = run.layer,
        .room = run.room,
    }));
}

pub fn CS_REQ_ABYSS_PROGRESS_UPDATE(scope: *Scope) Scope.Error!void {
    const req = try scope.command.take(p.CS_Req_Abyss_Progress_Update.Decoded);
    var next = scope.gameplay.abyss;
    next.progress(req.abyss_id, req.layer, req.room, req.finish_time) catch |err| {
        return scope.sink.send(.SC_RES_ABYSS_PROGRESS_UPDATE, @as(p.SC_Res_Abyss_Progress_Update, .{ .result = Abyss.result(err) }));
    };
    const location = Abyss.locate(req.abyss_id, req.layer) catch unreachable; // Validated by progress.
    const next_team: ?RoomTeam = if (next.run.completed < location.config.rooms.len) team: {
        const room = location.config.rooms[next.run.completed];
        break :team RoomTeam.forRoom(scope, room) orelse {
            log.warn("cannot advance Abyss {d} layer {d}: room {d} has no team", .{ req.abyss_id, req.layer, room });
            return scope.sink.send(.SC_RES_ABYSS_PROGRESS_UPDATE, @as(p.SC_Res_Abyss_Progress_Update, .{ .result = 207 }));
        };
    } else null;
    const output_start = scope.sink.end.*;
    const seq_start = scope.sink.send_seq.*;
    errdefer {
        scope.sink.end.* = output_start;
        scope.sink.send_seq.* = seq_start;
    }
    // The client prepares the next battlefield on acknowledgement, then waits for
    // this notification to assemble its characters and end the room transition.
    try scope.sink.send(.SC_RES_ABYSS_PROGRESS_UPDATE, @as(p.SC_Res_Abyss_Progress_Update, .{}));
    if (next_team) |team| try team.notify(scope);
    scope.gameplay.abyss = next;
    if (next_team) |team| {
        scope.gameplay.transient.abyss_team_room = team.room;
        scope.gameplay.transient.abyss_using_slot = team.slot;
    }
    scope.store.requestGameplayStateSave();
}

pub fn CS_REQ_ABYSS_FINISH(scope: *Scope) Scope.Error!void {
    var req = try scope.command.take(p.CS_Req_Abyss_Finish.Decoded);
    var task_ids: [3]u32 = undefined;
    var n: usize = 0;
    while (try req.task_finish.next()) |id| {
        if (n == task_ids.len) return scope.sink.send(.SC_RES_ABYSS_FINISH, @as(p.SC_Res_Abyss_Finish, .{ .result = 207, .abyss_id = req.abyss_id }));
        task_ids[n] = id;
        n += 1;
    }
    var next = scope.gameplay.abyss;
    const finished = next.finish(req.abyss_id, req.is_win, if (req.finish_reason) |reason| @intCast(@backingInt(reason)) else 0, task_ids[0..n]) catch |err| {
        return scope.sink.send(.SC_RES_ABYSS_FINISH, @as(p.SC_Res_Abyss_Finish, .{ .result = Abyss.result(err), .abyss_id = req.abyss_id }));
    };
    try scope.sink.send(.SC_RES_ABYSS_FINISH, @as(p.SC_Res_Abyss_Finish, .{
        .abyss_id = req.abyss_id,
        .layer = finished.layer,
        .cur_star = finished.current,
        .layer_star = finished.best,
        .abyss_star = finished.total,
    }));
    scope.gameplay.abyss = next;
    // The client sends CS_SET_TMP_TEAM_REQ(type=0) when returning to the ordinary team.
    scope.store.requestGameplayStateSave();
}

pub fn CS_REQ_ABYSS_STAR_AWARD(scope: *Scope) Scope.Error!void {
    const req = try scope.command.take(p.CS_Req_Abyss_Star_Award.Decoded);
    var next = scope.gameplay.abyss;
    const deltas = next.claim(req.abyss_id) catch |err| {
        return scope.sink.send(.SC_RES_ABYSS_STAR_AWARD, @as(p.SC_Res_Abyss_Star_Award, .{ .result = Abyss.result(err), .abyss_id = req.abyss_id }));
    };
    var awards: [Abyss.item_count]p.CmdItem = undefined;
    var balances: [Abyss.item_count]p.CmdItem = undefined;
    var n: usize = 0;
    for (deltas, tables.abyss_reward_item, 0..) |count, id, i| {
        if (count == 0) continue;
        awards[n] = .{ .item_id = id, .bind_id = id, .item_num = count };
        balances[n] = .{ .item_id = id, .bind_id = id, .item_num = next.items[i] };
        n += 1;
    }
    // Roll back the output cursor on failure so inventory and the acknowledgement are atomic.
    const output_start = scope.sink.end.*;
    const seq_start = scope.sink.send_seq.*;
    errdefer {
        scope.sink.end.* = output_start;
        scope.sink.send_seq.* = seq_start;
    }
    try scope.sink.send(.SC_ITEM_BAG_CHANGE_NTF, @as(p.SC_Item_Bag_Change_Ntf, .{
        .reason = .ENM_ITEM_CHANGE_ABYSS_STAR_REWARD,
        .items = balances[0..n],
    }));
    try scope.sink.send(.SC_RES_ABYSS_STAR_AWARD, @as(p.SC_Res_Abyss_Star_Award, .{
        .abyss_id = req.abyss_id,
        .star_count = next.claimed[Abyss.modeIndex(req.abyss_id).?],
        .award_list = awards[0..n],
    }));
    scope.gameplay.abyss = next;
    scope.store.requestGameplayStateSave();
}

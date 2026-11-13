//! Exercise the real dispatcher, protobuf decoder and response framing without a live client.
const std = @import("std");
const t = std.testing;
const roze = @import("roze.zig");
const p = roze.protobuf.gen;
const Fixture = struct {
    gameplay: roze.Gameplay = .init,
    index: roze.assets.Index = undefined,
    output: [65535]u8 = undefined,
    input: [8192]u8 = undefined,
    end: usize = 0,
    seq: u32 = 0,
    capacity: usize = 65535,
    save_requested: bool = false,

    fn send(f: *Fixture, tag: p.EClientServerCmds, request: anytype) !void {
        f.end = 0;
        f.save_requested = false;
        var writer: std.Io.Writer = .fixed(&f.input);
        try roze.protobuf.encode(@TypeOf(request), &request, &writer);
        var scope: roze.Scope = .{
            .time = .{ .impl = if (@import("builtin").os.tag == .windows)
                -std.time.epoch.windows * (std.time.ns_per_s / 100)
            else
                .{ .sec = 0, .nsec = 0 } },
            .sink = .{ .buffer = f.output[0..f.capacity], .end = &f.end, .send_seq = &f.seq },
            .command = .{ .id = @intCast(@backingInt(tag)), .data = writer.buffered() },
            .gameplay = &f.gameplay,
            .asset_index = &f.index,
            .level = .default,
            .store = .{ .role_id = 1337, .gameplay_state_save_requested = false },
        };
        try roze.commands.execute(&scope);
        f.save_requested = scope.store.gameplay_state_save_requested;
    }

    fn body(f: *Fixture, tag: p.EClientServerCmds, comptime Message: type) !Message {
        var offset: usize = 0;
        while (offset < f.end) {
            const header = roze.net.Header.decode(f.output[offset..][0..roze.net.Header.size]);
            offset += roze.net.Header.size;
            const pkg = try roze.protobuf.decode(p.CSMsgPkg.Decoded, f.output[offset..][0..header.decrypted_len]);
            offset += header.decrypted_len;
            if (pkg.head.?.cmd == @backingInt(tag)) return roze.protobuf.decode(Message, pkg.body);
        }
        return error.ResponseMissing;
    }

    fn expectCommands(f: *Fixture, expected: []const p.EClientServerCmds) !void {
        var offset: usize = 0;
        for (expected) |tag| {
            try t.expect(offset + roze.net.Header.size <= f.end);
            const header = roze.net.Header.decode(f.output[offset..][0..roze.net.Header.size]);
            offset += roze.net.Header.size;
            const pkg = try roze.protobuf.decode(p.CSMsgPkg.Decoded, f.output[offset..][0..header.decrypted_len]);
            offset += header.decrypted_len;
            try t.expectEqual(@as(u32, @intCast(@backingInt(tag))), pkg.head.?.cmd);
        }
        try t.expectEqual(f.end, offset);
    }
};

test "initial Abyss entry defers live team switching until the destination scene initializes" {
    var f: Fixture = .{};
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try f.index.init(arena.allocator());
    const normal = f.gameplay.character_team.members;
    f.gameplay.abyss_teams[0] = .{ .none, .wrap(roze.Gameplay.Character.Index.fromInt(2)), .none, .none };
    try f.send(.CS_REQ_ABYSS_ENTER, @as(p.CS_Req_Abyss_Enter, .{ .abyss_id = 1000, .layer = 1, .room = 1 }));
    // A live-switch notification here runs TeamData's character assembly in
    // the departing scene, before the entry acknowledgement starts map travel.
    try f.expectCommands(&.{.SC_RES_ABYSS_ENTER});
    try t.expectEqual(@as(u32, 100101), f.gameplay.transient.abyss_team_room);
    try f.send(.CS_CHARACTER_TEAMS, @as(p.CS_Character_Teams, .{}));
    const current = (try f.body(.SC_CHARACTER_TEAMS, p.SC_Character_Teams.Decoded)).cur_team.?;
    try t.expectEqual(@as(i32, 5), current.team_type);
    try t.expectEqual(@as(u64, 100101), current.team_src.?.src);
    try t.expectEqual(@as(u32, 2), current.using_member_slot);
    var team = current.team_data.?;
    const member = (try team.member_data.next()).?;
    try t.expectEqual(@as(u32, 2), member.member_slot_id);
    try t.expectEqual(@as(u64, 3), member.inst_id);
    try t.expectEqualDeep(normal, f.gameplay.character_team.members);
}

test "reward response overflow leaves claims, balances and output unchanged" {
    var f: Fixture = .{};
    f.gameplay.abyss.layers[0] = .{ .star = 3, .passed = 1 };
    const state = f.gameplay.abyss;
    try f.send(.CS_REQ_ABYSS_STAR_AWARD, @as(p.CS_Req_Abyss_Star_Award, .{ .abyss_id = 1000 }));
    const first = roze.net.Header.decode(f.output[0..roze.net.Header.size]);
    f.capacity = roze.net.Header.size + first.decrypted_len;
    f.gameplay.abyss = state;
    const seq = f.seq;
    try t.expectError(error.SinkBufferOverflow, f.send(.CS_REQ_ABYSS_STAR_AWARD, @as(p.CS_Req_Abyss_Star_Award, .{ .abyss_id = 1000 })));
    try t.expectEqualDeep(state, f.gameplay.abyss);
    try t.expectEqual(@as(usize, 0), f.end);
    try t.expectEqual(seq, f.seq);
    try t.expect(!f.save_requested);
}

test "Agenda requests are registered and return complete City Records and Abyss wrappers" {
    var f: Fixture = .{};
    try f.send(.CS_NEWBIE_GET_DATA_REQUEST, @as(p.CS_Newbie_Get_Data_Request, .{}));
    var newbie = try f.body(.SC_NEWBIE_GET_DATA_RESPONSE, p.SC_Newbie_Get_Data_Response.Decoded);
    try t.expectEqual(@as(i32, 0), newbie.result);
    var stages: usize = 0;
    while (try newbie.stages.next()) |stage| {
        try t.expect(stage.is_unlocked);
        stages += 1;
    }
    var events: usize = 0;
    while (try newbie.newbies.next()) |_| {
        events += 1;
    }
    try t.expectEqual(@as(usize, 7), stages);
    try t.expectEqual(@as(usize, 42), events);
    try f.send(.CS_REQ_ABYSS_INFO, @as(p.CS_Req_Abyss_Info, .{}));
    var info = try f.body(.SC_RES_ABYSS_INFO, p.SC_Res_Abyss_Info.Decoded);
    var modes: usize = 0;
    var layers: usize = 0;
    var data = info.abyss_data.?;
    while (try data.abyss_list.next()) |mode_in| {
        var mode = mode_in;
        modes += 1;
        while (try mode.layer_list.next()) |layer| {
            try t.expect(layer.is_passed); // Client prerequisite gate is open.
            try t.expectEqual(@as(u32, 0), layer.star);
            layers += 1;
        }
    }
    try t.expectEqual(@as(usize, 3), modes);
    try t.expectEqual(@as(usize, 18), layers);
    var active: usize = 0;
    while (try info.active_abyss_list.next()) |mode| {
        try t.expect(mode.start_time < 1794355200 and mode.end_time > 1794355200);
        active += 1;
    }
    try t.expectEqual(@as(usize, 3), active);
    try t.expect(!f.save_requested);
}

test "every sandbox Abyss layer is selectable without granting stars or rewards" {
    var f: Fixture = .{};
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try f.index.init(arena.allocator());
    for (&f.gameplay.abyss_teams) |*team| team[0] = .wrap(roze.Gameplay.Character.Index.fromInt(0));
    for (roze.assets.tables.abyss) |mode| {
        for (mode.layers) |layer| {
            try f.send(.CS_REQ_ABYSS_ENTER, @as(p.CS_Req_Abyss_Enter, .{ .abyss_id = mode.id, .layer = layer.index, .room = 1 }));
            try t.expectEqual(@as(i32, 0), (try f.body(.SC_RES_ABYSS_ENTER, p.SC_Res_Abyss_Enter.Decoded)).result);
            try f.send(.CS_REQ_ABYSS_ENTER_ALREADY, @as(p.CS_Req_Abyss_Enter_Already, .{}));
            const resumed = try f.body(.SC_RES_ABYSS_ENTER_ALREADY, p.SC_Res_Abyss_Enter_Already.Decoded);
            try t.expectEqual(mode.id, resumed.abyss_id);
            try t.expectEqual(layer.index, resumed.layer);
            try t.expectEqual(@as(u32, 1), resumed.room);
        }
        try f.send(.CS_REQ_ABYSS_STAR_AWARD, @as(p.CS_Req_Abyss_Star_Award, .{ .abyss_id = mode.id }));
        try t.expectEqual(@as(i32, 4406), (try f.body(.SC_RES_ABYSS_STAR_AWARD, p.SC_Res_Abyss_Star_Award.Decoded)).result);
    }
    try t.expectEqualDeep(roze.Gameplay.Abyss.State.init.layers, f.gameplay.abyss.layers);
    try t.expectEqualDeep(roze.Gameplay.Abyss.State.init.items, f.gameplay.abyss.items);
}

test "battle victory accepts negative coordinates and full-width instance IDs" {
    var f: Fixture = .{};
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try f.index.init(arena.allocator());
    const uid = std.math.maxInt(u64);
    try f.send(.CS_START_BATTLE, @as(p.CS_Start_Battle, .{
        .battle_uid = uid,
        .battle_type = .ENM_BATTLE_TYPE_REPEAT_DUNGEON,
        .battle_field_id = 100101,
    }));
    try f.send(.CS_LEAVE_BATTLE, @as(p.CS_Leave_Battle, .{
        .battle_uid = uid,
        .battle_type = .ENM_BATTLE_TYPE_REPEAT_DUNGEON,
        .battle_field_id = 100101,
        .battle_result = .ENM_BATTLE_RESULT_TYPE_SUCCESS,
        .character_data = &.{.{ .inst_id = 1, .current_hp = 1234, .permanent_liquid = -1 }},
        .battle_end_info = .{
            .vector3 = .{ .x = -123, .y = 456, .z = -789 },
            .block_id = std.math.maxInt(u64),
            .monsters = &.{ -1, std.math.minInt(i64) },
            .play_time = 60,
        },
    }));
    const response = try f.body(.SC_LEAVE_BATTLE, p.SC_Leave_Battle.Decoded);
    try t.expectEqual(@as(i32, 0), response.ret);
    try t.expectEqual(@as(u64, uid), response.battle_uid);
    try t.expectEqual(p.EBattleResultType.ENM_BATTLE_RESULT_TYPE_SUCCESS, response.battle_result.?);
    const snapshot = f.gameplay.character.snapshots[0].unwrap().?;
    try t.expectEqual(@as(i32, 1234), snapshot.hp);
    try t.expectEqual(@as(i32, -1), snapshot.permanent_liquid);
    try t.expect(f.save_requested);
}

test "Abyss entry, reconnect, settlement, claim and bag balances use the wire contract" {
    var f: Fixture = .{};
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try f.index.init(arena.allocator());
    f.gameplay.abyss_teams[roze.Gameplay.Abyss.roomIndex(100101).?][0] = .wrap(roze.Gameplay.Character.Index.fromInt(0));
    try f.send(.CS_REQ_ABYSS_ENTER, @as(p.CS_Req_Abyss_Enter, .{ .abyss_id = 1000, .layer = 1, .room = 100101 }));
    try t.expectEqual(@as(i32, 4404), (try f.body(.SC_RES_ABYSS_ENTER, p.SC_Res_Abyss_Enter.Decoded)).result);
    try t.expect(!f.save_requested);
    try f.send(.CS_REQ_ABYSS_ENTER, @as(p.CS_Req_Abyss_Enter, .{ .abyss_id = 1000, .layer = 1, .room = 1 }));
    try t.expect(f.save_requested);
    try f.send(.CS_REQ_ABYSS_ENTER_ALREADY, @as(p.CS_Req_Abyss_Enter_Already, .{}));
    const confirmed = try f.body(.SC_RES_ABYSS_ENTER_ALREADY, p.SC_Res_Abyss_Enter_Already.Decoded);
    try t.expectEqual(@as(u32, 1), confirmed.room);
    try f.send(.CS_REQ_ABYSS_PROGRESS_UPDATE, @as(p.CS_Req_Abyss_Progress_Update, .{ .abyss_id = 1000, .layer = 1, .room = 1, .finish_time = 60_000 }));
    try t.expectEqual(@as(i32, 0), (try f.body(.SC_RES_ABYSS_PROGRESS_UPDATE, p.SC_Res_Abyss_Progress_Update.Decoded)).result);
    try f.send(.CS_DUNGEONS_ENTER_ALREADY, @as(p.CS_Dungeons_Enter_Already, .{}));
    const resumed = try f.body(.SC_DUNGEONS_ENTER_ALREADY, p.SC_Dungeons_Enter_Already.Decoded);
    try t.expectEqual(p.EnmDungeonsSystemType.EST_ABYSS, resumed.cur_system.?);
    var times = resumed.abyss_info.?.finish_time;
    try t.expectEqual(@as(?i64, 60_000), try times.next());
    try f.send(.CS_REQ_ABYSS_FINISH, @as(p.CS_Req_Abyss_Finish, .{
        .abyss_id = 1000,
        .is_win = true,
        .finish_reason = .ENM_ABYSS_FINISH_REASON_NORMAL,
        .task_finish = &.{ 100101, 100102, 100103 },
    }));
    const finish = try f.body(.SC_RES_ABYSS_FINISH, p.SC_Res_Abyss_Finish.Decoded);
    try t.expectEqual(@as(u32, 3), finish.abyss_star);
    try t.expectEqual(@as(u32, 0), f.gameplay.abyss.run.abyss_id);
    try f.send(.CS_REQ_ABYSS_STAR_AWARD, @as(p.CS_Req_Abyss_Star_Award, .{ .abyss_id = 1000 }));
    var award = try f.body(.SC_RES_ABYSS_STAR_AWARD, p.SC_Res_Abyss_Star_Award.Decoded);
    try t.expectEqual(@as(u32, 3), award.star_count);
    var amount: u32 = 0;
    while (try award.award_list.next()) |item| {
        if (item.item_id == 770002) amount += item.item_num;
    }
    try t.expectEqual(@as(u32, 500), amount);
    var bag_change = try f.body(.SC_ITEM_BAG_CHANGE_NTF, p.SC_Item_Bag_Change_Ntf.Decoded);
    try t.expectEqual(p.EnmItemReason.ENM_ITEM_CHANGE_ABYSS_STAR_REWARD, bag_change.reason.?);
    try t.expect((try bag_change.items.next()) != null);
    const before = f.gameplay.abyss.items;
    try f.send(.CS_REQ_ABYSS_STAR_AWARD, @as(p.CS_Req_Abyss_Star_Award, .{ .abyss_id = 1000 }));
    try t.expectEqual(@as(i32, 4406), (try f.body(.SC_RES_ABYSS_STAR_AWARD, p.SC_Res_Abyss_Star_Award.Decoded)).result);
    try t.expectEqualDeep(before, f.gameplay.abyss.items);
    try t.expect(!f.save_requested);
    try f.send(.CS_ITEM_BAG_GET_LIST, @as(p.CS_Item_Bag_Get_List, .{}));
    var bag = try f.body(.SC_ITEM_BAG_GET_LIST, p.SC_Item_Bag_Get_List.Decoded);
    var found = false;
    while (try bag.items.next()) |item| if (item.item_id == 770002) {
        try t.expectEqual(@as(u32, 500), item.item_num);
        found = true;
    };
    try t.expect(found);
}

test "selected Abyss teams activate on entry and advance between sides without another enter request" {
    var f: Fixture = .{};
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try f.index.init(arena.allocator());
    const original = f.gameplay.character_team.members;
    try f.send(.CS_CHARACTER_UPDATE_TMP_TEAM, @as(p.CS_Character_Update_Tmp_Team, .{
        .team_type = 5,
        .tmp_team_data = &.{
            .{ .team_src = .{ .src = 100501 }, .team_data = .{ .member_data = &.{.{ .member_slot_id = 2, .inst_id = 3 }} } },
            .{ .team_src = .{ .src = 100502 }, .team_data = .{ .member_data = &.{.{ .member_slot_id = 4, .inst_id = 4 }} } },
        },
    }));
    try t.expectEqual(@as(i32, 0), (try f.body(.SC_CHARACTER_UPDATE_TMP_TEAM, p.SC_Character_Update_Tmp_Team.Decoded)).result);
    try f.send(.CS_REQ_ABYSS_ENTER, @as(p.CS_Req_Abyss_Enter, .{ .abyss_id = 1000, .layer = 5, .room = 1 }));
    try f.expectCommands(&.{.SC_RES_ABYSS_ENTER});
    try f.send(.CS_CHARACTER_TEAMS, @as(p.CS_Character_Teams, .{}));
    var initial = (try f.body(.SC_CHARACTER_TEAMS, p.SC_Character_Teams.Decoded)).cur_team.?;
    try t.expectEqual(@as(i32, 5), initial.team_type);
    try t.expectEqual(@as(u64, 100501), initial.team_src.?.src);
    try t.expectEqual(@as(u32, 2), initial.using_member_slot);
    try t.expectEqual(@as(u64, 3), (try initial.team_data.?.member_data.next()).?.inst_id);
    try f.send(.CS_CHARACTER_TEAMS, @as(p.CS_Character_Teams, .{}));
    const current = (try f.body(.SC_CHARACTER_TEAMS, p.SC_Character_Teams.Decoded)).cur_team.?;
    try t.expectEqual(@as(i32, 5), current.team_type);
    try t.expectEqual(@as(u64, 100501), current.team_src.?.src);

    const progress: p.CS_Req_Abyss_Progress_Update = .{ .abyss_id = 1000, .layer = 5, .room = 1, .finish_time = 40_000 };
    try f.send(.CS_REQ_ABYSS_PROGRESS_UPDATE, progress);
    try f.expectCommands(&.{ .SC_RES_ABYSS_PROGRESS_UPDATE, .SC_CHARACTER_TEMP_TEAM_NTF });
    var second = (try f.body(.SC_CHARACTER_TEMP_TEAM_NTF, p.SC_Character_Temp_Team_Ntf.Decoded)).cur_team.?;
    try t.expectEqual(@as(i32, 5), second.team_type);
    try t.expectEqual(@as(u64, 100502), second.team_src.?.src);
    try t.expectEqual(@as(u32, 4), second.using_member_slot);
    try t.expectEqual(@as(u32, 100502), second.team_data.?.team_id);
    try t.expectEqual(@as(u64, 4), (try second.team_data.?.member_data.next()).?.inst_id);
    try t.expectEqual(@as(u64, 4), (try second.attrib_data.next()).?.inst_id);
    try t.expectEqual(@as(u32, 100502), f.gameplay.transient.abyss_team_room);
    try t.expectEqualDeep(original, f.gameplay.character_team.members);
    const after_first = f.gameplay.abyss;
    try f.send(.CS_REQ_ABYSS_PROGRESS_UPDATE, progress);
    try f.expectCommands(&.{ .SC_RES_ABYSS_PROGRESS_UPDATE, .SC_CHARACTER_TEMP_TEAM_NTF });
    try t.expectEqualDeep(after_first, f.gameplay.abyss);

    try f.send(.CS_DUNGEONS_ENTER_ALREADY, @as(p.CS_Dungeons_Enter_Already, .{}));
    const resumed = (try f.body(.SC_DUNGEONS_ENTER_ALREADY, p.SC_Dungeons_Enter_Already.Decoded)).abyss_info.?;
    try t.expectEqual(@as(u32, 2), resumed.room);
    try f.send(.CS_START_BATTLE, @as(p.CS_Start_Battle, .{ .battle_uid = 2, .battle_type = .ENM_BATTLE_TYPE_ABYSS, .battle_field_id = 100502 }));
    try f.send(.CS_LEAVE_BATTLE, @as(p.CS_Leave_Battle, .{ .battle_uid = 2, .battle_type = .ENM_BATTLE_TYPE_ABYSS, .battle_field_id = 100502, .battle_result = .ENM_BATTLE_RESULT_TYPE_SUCCESS }));
    try f.send(.CS_REQ_ABYSS_PROGRESS_UPDATE, @as(p.CS_Req_Abyss_Progress_Update, .{ .abyss_id = 1000, .layer = 5, .room = 2, .finish_time = 50_000 }));
    try f.expectCommands(&.{.SC_RES_ABYSS_PROGRESS_UPDATE});
    try f.send(.CS_REQ_ABYSS_FINISH, @as(p.CS_Req_Abyss_Finish, .{ .abyss_id = 1000, .is_win = true, .task_finish = &.{ 100104, 100105, 100106 } }));
    try t.expectEqual(@as(u32, 3), (try f.body(.SC_RES_ABYSS_FINISH, p.SC_Res_Abyss_Finish.Decoded)).layer_star);
    try f.send(.CS_SET_TMP_TEAM_REQ, @as(p.CS_Set_Tmp_Team_Req, .{ .team_type = 0 }));
    try t.expectEqual(@as(i32, 0), (try f.body(.SC_SET_TMP_TEAM_RSP, p.SC_Set_Tmp_Team_Rsp.Decoded)).result);
    try t.expectEqual(@as(u32, 0), f.gameplay.transient.abyss_team_room);
    try t.expectEqualDeep(original, f.gameplay.character_team.members);
}

test "Abyss team activation and side changes roll back if the response buffer fills" {
    var f: Fixture = .{};
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try f.index.init(arena.allocator());
    f.gameplay.abyss_teams[roze.Gameplay.Abyss.roomIndex(100501).?][0] = .wrap(roze.Gameplay.Character.Index.fromInt(0));
    f.gameplay.abyss_teams[roze.Gameplay.Abyss.roomIndex(100502).?][0] = .wrap(roze.Gameplay.Character.Index.fromInt(1));
    const enter: p.CS_Req_Abyss_Enter = .{ .abyss_id = 1000, .layer = 5, .room = 1 };
    const before_enter = f.gameplay.abyss;
    const transient_before = f.gameplay.transient;
    try f.send(.CS_REQ_ABYSS_ENTER, enter);
    const first_frame = roze.net.Header.decode(f.output[0..roze.net.Header.size]);
    f.capacity = roze.net.Header.size + first_frame.decrypted_len - 1;
    f.gameplay.abyss = before_enter;
    f.gameplay.transient = transient_before;
    var seq = f.seq;
    try t.expectError(error.SinkBufferOverflow, f.send(.CS_REQ_ABYSS_ENTER, enter));
    try t.expectEqualDeep(before_enter, f.gameplay.abyss);
    try t.expectEqualDeep(transient_before, f.gameplay.transient);
    try t.expectEqual(@as(usize, 0), f.end);
    try t.expectEqual(seq, f.seq);
    try t.expect(!f.save_requested);

    f.capacity = f.output.len;
    try f.send(.CS_REQ_ABYSS_ENTER, enter);
    const before_progress = f.gameplay.abyss;
    const team_before = f.gameplay.transient;
    const progress: p.CS_Req_Abyss_Progress_Update = .{ .abyss_id = 1000, .layer = 5, .room = 1, .finish_time = 40_000 };
    try f.send(.CS_REQ_ABYSS_PROGRESS_UPDATE, progress);
    const ack = roze.net.Header.decode(f.output[0..roze.net.Header.size]);
    f.capacity = roze.net.Header.size + ack.decrypted_len;
    f.gameplay.abyss = before_progress;
    f.gameplay.transient = team_before;
    seq = f.seq;
    try t.expectError(error.SinkBufferOverflow, f.send(.CS_REQ_ABYSS_PROGRESS_UPDATE, progress));
    try t.expectEqualDeep(before_progress, f.gameplay.abyss);
    try t.expectEqualDeep(team_before, f.gameplay.transient);
    try t.expectEqual(@as(usize, 0), f.end);
    try t.expectEqual(seq, f.seq);
    try t.expect(!f.save_requested);
}

test "empty selected Abyss teams reject entry and progress without changing the attempt" {
    var f: Fixture = .{};
    const before = f.gameplay.abyss;
    const enter: p.CS_Req_Abyss_Enter = .{ .abyss_id = 1000, .layer = 5, .room = 1 };
    try f.send(.CS_REQ_ABYSS_ENTER, enter);
    try t.expectEqual(@as(i32, 207), (try f.body(.SC_RES_ABYSS_ENTER, p.SC_Res_Abyss_Enter.Decoded)).result);
    try t.expectEqualDeep(before, f.gameplay.abyss);
    try t.expect(!f.save_requested);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try f.index.init(arena.allocator());
    f.gameplay.abyss_teams[roze.Gameplay.Abyss.roomIndex(100501).?][0] = .wrap(roze.Gameplay.Character.Index.fromInt(0));
    try f.send(.CS_REQ_ABYSS_ENTER, enter);
    const entered = f.gameplay.abyss;
    try f.send(.CS_REQ_ABYSS_PROGRESS_UPDATE, @as(p.CS_Req_Abyss_Progress_Update, .{ .abyss_id = 1000, .layer = 5, .room = 1, .finish_time = 40_000 }));
    try t.expectEqual(@as(i32, 207), (try f.body(.SC_RES_ABYSS_PROGRESS_UPDATE, p.SC_Res_Abyss_Progress_Update.Decoded)).result);
    try t.expectEqualDeep(entered, f.gameplay.abyss);
    try t.expect(!f.save_requested);
}

test "temporary room teams round-trip, reject duplicates and restore the ordinary team" {
    var f: Fixture = .{};
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try f.index.init(arena.allocator());
    const original = f.gameplay.character_team.members;
    try f.send(.CS_CHARACTER_UPDATE_TMP_TEAM, @as(p.CS_Character_Update_Tmp_Team, .{
        .team_type = 5,
        .tmp_team_data = &.{
            .{ .team_src = .{ .src = 200101 }, .team_data = .{ .member_data = &.{.{ .member_slot_id = 1, .inst_id = 1 }} } },
            .{ .team_src = .{ .src = 200102 }, .team_data = .{ .member_data = &.{.{ .member_slot_id = 3, .inst_id = 2 }} } },
        },
    }));
    try t.expectEqual(@as(i32, 0), (try f.body(.SC_CHARACTER_UPDATE_TMP_TEAM, p.SC_Character_Update_Tmp_Team.Decoded)).result);
    const saved = f.gameplay.abyss_teams;
    try f.send(.CS_CHARACTER_UPDATE_TMP_TEAM, @as(p.CS_Character_Update_Tmp_Team, .{
        .team_type = 5,
        .tmp_team_data = &.{.{ .team_src = .{ .src = 200102 }, .team_data = .{ .member_data = &.{.{ .member_slot_id = 1, .inst_id = 1 }} } }},
    }));
    try t.expectEqual(@as(i32, 207), (try f.body(.SC_CHARACTER_UPDATE_TMP_TEAM, p.SC_Character_Update_Tmp_Team.Decoded)).result);
    try t.expectEqualDeep(saved, f.gameplay.abyss_teams);
    try f.send(.CS_CHARACTER_TMP_TEAM_QUERY, @as(p.CS_Character_Tmp_Team_Query, .{ .team_type = 5, .team_src = &.{ .{ .src = 200101 }, .{ .src = 200102 } } }));
    var query = try f.body(.SC_CHARACTER_TMP_TEAM_QUERY, p.SC_Character_Tmp_Team_Query.Decoded);
    var n: usize = 0;
    while (try query.tmp_team_data.next()) |_| {
        n += 1;
    }
    try t.expectEqual(@as(usize, 2), n);
    try f.send(.CS_SET_TMP_TEAM_REQ, @as(p.CS_Set_Tmp_Team_Req, .{ .team_type = 5, .team_src = .{ .src = 200102 } }));
    const selected = try f.body(.SC_SET_TMP_TEAM_RSP, p.SC_Set_Tmp_Team_Rsp.Decoded);
    try t.expectEqual(@as(i32, 0), selected.result);
    try t.expectEqual(@as(u32, 3), selected.cur_team.?.using_member_slot);
    try t.expectEqual(@as(u8, 1), f.gameplay.character_team.bits.using_slot.toSlotId());
    try t.expectEqual(@as(u32, 200102), f.gameplay.transient.abyss_team_room);
    try t.expectEqualDeep(original, f.gameplay.character_team.members);
    try f.send(.CS_CHARACTER_TEAMS, @as(p.CS_Character_Teams, .{}));
    const current = try f.body(.SC_CHARACTER_TEAMS, p.SC_Character_Teams.Decoded);
    try t.expectEqual(@as(i32, 5), current.cur_team.?.team_type);
    try f.send(.CS_SET_TMP_TEAM_REQ, @as(p.CS_Set_Tmp_Team_Req, .{ .team_type = 0 }));
    try t.expectEqual(@as(u32, 0), f.gameplay.transient.abyss_team_room);
    try t.expectEqualDeep(original, f.gameplay.character_team.members);
}

test "reactor equips and removes regular catalysts, preserving empty character slots" {
    var f: Fixture = .{};
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try f.index.init(arena.allocator());
    const members: [4]p.TeamMemberData = .{
        .{ .member_slot_id = 1, .inst_id = 1, .gem_slots = &.{.{ .gem_slot_id = 3, .gem_itemid = 21501001, .gem_state = .EMPTY }} },
        .{ .member_slot_id = 2 },
        .{ .member_slot_id = 3 },
        .{ .member_slot_id = 4 },
    };
    try f.send(.CS_CHARACTER_UPDATE_TEAM, @as(p.CS_Character_Update_Team, .{ .team_data = .{ .team_id = 1, .member_data = &members } }));
    var result = try f.body(.SC_CHARACTER_UPDATE_TEAM, p.SC_Character_Update_Team.Decoded);
    try t.expectEqual(@as(i32, 0), result.result);
    try t.expect(f.save_requested);
    var member = (try result.team_data.?.member_data.next()).?;
    try t.expectEqual(@as(u32, 0), (try member.gem_slots.next()).?.gem_itemid);
    try t.expectEqual(@as(u32, 0), (try member.gem_slots.next()).?.gem_itemid);
    const gem = (try member.gem_slots.next()).?;
    try t.expectEqual(@as(u32, 3), gem.gem_slot_id);
    try t.expectEqual(@as(u32, 21501001), gem.gem_itemid);
    try t.expectEqual(p.EnmGemStatus.VALID, gem.gem_state.?);
    try f.send(.CS_CHARACTER_TEAMS, @as(p.CS_Character_Teams, .{}));
    var current = (try f.body(.SC_CHARACTER_TEAMS, p.SC_Character_Teams.Decoded)).cur_team.?;
    member = (try current.team_data.?.member_data.next()).?;
    _ = try member.gem_slots.next();
    _ = try member.gem_slots.next();
    try t.expectEqual(@as(u32, 21501001), (try member.gem_slots.next()).?.gem_itemid);
    try f.send(.CS_CHARACTER_UPDATE_TEAM, @as(p.CS_Character_Update_Team, .{ .team_data = .{ .team_id = 1, .member_data = &.{.{ .member_slot_id = 1, .inst_id = 1, .gem_slots = &.{.{ .gem_slot_id = 3 }} }} } }));
    try t.expectEqualDeep(roze.Gameplay.Catalysts.empty, f.gameplay.catalysts.normal[0]);
}

test "reactor temporary gem updates survive side changes and reject character replacement atomically" {
    var f: Fixture = .{};
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try f.index.init(arena.allocator());
    try f.send(.CS_CHARACTER_UPDATE_TMP_TEAM, @as(p.CS_Character_Update_Tmp_Team, .{
        .team_type = 5,
        .tmp_team_data = &.{
            .{ .team_src = .{ .src = 100501 }, .team_data = .{ .member_data = &.{.{ .member_slot_id = 2, .inst_id = 3 }} } },
            .{ .team_src = .{ .src = 100502 }, .team_data = .{ .member_data = &.{.{ .member_slot_id = 4, .inst_id = 4, .gem_slots = &.{.{ .gem_slot_id = 1, .gem_itemid = 21501002 }} }} } },
        },
    }));
    const req: p.CS_Tmp_Team_Update_Gem_Req = .{ .team_type = 5, .tmp_team_data = .{ .team_src = .{ .src = 100501 }, .team_data = .{ .member_data = &.{.{ .member_slot_id = 2, .inst_id = 3, .gem_slots = &.{.{ .gem_slot_id = 2, .gem_itemid = 21501001 }} }} } } };
    const state = f.gameplay.catalysts;
    f.capacity = 1;
    try t.expectError(error.SinkBufferOverflow, f.send(.CS_TMP_TEAM_UPDATE_GEM_REQ, req));
    try t.expectEqualDeep(state, f.gameplay.catalysts);
    try t.expect(!f.save_requested);
    f.capacity = f.output.len;
    try f.send(.CS_TMP_TEAM_UPDATE_GEM_REQ, req);
    var response = try f.body(.SC_TMP_TEAM_UPDATE_GEM_RSP, p.SC_Tmp_Team_Update_Gem_Rsp.Decoded);
    try t.expectEqual(@as(i32, 0), response.result);
    var member = (try response.tmp_team_data.?.team_data.?.member_data.next()).?;
    _ = try member.gem_slots.next();
    try t.expectEqual(@as(u32, 21501001), (try member.gem_slots.next()).?.gem_itemid);
    try t.expect(f.save_requested);
    try f.send(.CS_CHARACTER_TMP_TEAM_QUERY, @as(p.CS_Character_Tmp_Team_Query, .{ .team_type = 5, .team_src = &.{.{ .src = 100501 }} }));
    var query = try f.body(.SC_CHARACTER_TMP_TEAM_QUERY, p.SC_Character_Tmp_Team_Query.Decoded);
    var room = (try query.tmp_team_data.next()).?;
    member = (try room.team_data.?.member_data.next()).?;
    _ = try member.gem_slots.next();
    try t.expectEqual(@as(u32, 21501001), (try member.gem_slots.next()).?.gem_itemid);
    try f.send(.CS_REQ_ABYSS_ENTER, @as(p.CS_Req_Abyss_Enter, .{ .abyss_id = 1000, .layer = 5, .room = 1 }));
    try f.send(.CS_CHARACTER_TEAMS, @as(p.CS_Character_Teams, .{}));
    var current = (try f.body(.SC_CHARACTER_TEAMS, p.SC_Character_Teams.Decoded)).cur_team.?;
    member = (try current.team_data.?.member_data.next()).?;
    _ = try member.gem_slots.next();
    try t.expectEqual(@as(u32, 21501001), (try member.gem_slots.next()).?.gem_itemid);
    try f.send(.CS_REQ_ABYSS_PROGRESS_UPDATE, @as(p.CS_Req_Abyss_Progress_Update, .{ .abyss_id = 1000, .layer = 5, .room = 1, .finish_time = 40_000 }));
    current = (try f.body(.SC_CHARACTER_TEMP_TEAM_NTF, p.SC_Character_Temp_Team_Ntf.Decoded)).cur_team.?;
    member = (try current.team_data.?.member_data.next()).?;
    try t.expectEqual(@as(u32, 21501002), (try member.gem_slots.next()).?.gem_itemid);
    const before = f.gameplay.catalysts;
    try f.send(.CS_TMP_TEAM_UPDATE_GEM_REQ, @as(p.CS_Tmp_Team_Update_Gem_Req, .{ .team_type = 5, .tmp_team_data = .{ .team_src = .{ .src = 100501 }, .team_data = .{ .member_data = &.{.{ .member_slot_id = 2, .inst_id = 4 }} } } }));
    try t.expectEqual(@as(i32, 207), (try f.body(.SC_TMP_TEAM_UPDATE_GEM_RSP, p.SC_Tmp_Team_Update_Gem_Rsp.Decoded)).result);
    try t.expectEqualDeep(before, f.gameplay.catalysts);
    try t.expect(!f.save_requested);
}

test "reactor rejects duplicate catalysts, unknown items, bad slots and excess power" {
    var f: Fixture = .{};
    const invalid_gems: []const []const p.GemSlotData = &.{
        &.{.{ .gem_slot_id = 1, .gem_itemid = 999 }},
        &.{.{ .gem_slot_id = 0, .gem_itemid = 21501001 }},
        &.{.{ .gem_slot_id = 4, .gem_itemid = 21501001 }},
        &.{ .{ .gem_slot_id = 1, .gem_itemid = 21501001 }, .{ .gem_slot_id = 1, .gem_itemid = 21501002 } },
        &.{ .{ .gem_slot_id = 1, .gem_itemid = 21501001 }, .{ .gem_slot_id = 2, .gem_itemid = 21501001 } },
    };
    for (invalid_gems) |gems| {
        try f.send(.CS_CHARACTER_UPDATE_TEAM, @as(p.CS_Character_Update_Team, .{ .team_data = .{ .team_id = 1, .member_data = &.{.{ .member_slot_id = 1, .inst_id = 1, .gem_slots = gems }} } }));
        try t.expectEqual(@as(i32, -1), (try f.body(.SC_CHARACTER_UPDATE_TEAM, p.SC_Character_Update_Team.Decoded)).result);
        try t.expect(!f.save_requested);
    }
    const over: [3]p.TeamMemberData = .{
        .{ .member_slot_id = 1, .inst_id = 1, .gem_slots = &.{ .{ .gem_slot_id = 1, .gem_itemid = 21501001 }, .{ .gem_slot_id = 2, .gem_itemid = 21501002 }, .{ .gem_slot_id = 3, .gem_itemid = 21501003 } } },
        .{ .member_slot_id = 2, .inst_id = 2, .gem_slots = &.{ .{ .gem_slot_id = 1, .gem_itemid = 21501004 }, .{ .gem_slot_id = 2, .gem_itemid = 21501005 }, .{ .gem_slot_id = 3, .gem_itemid = 21501006 } } },
        .{ .member_slot_id = 3, .inst_id = 3, .gem_slots = &.{.{ .gem_slot_id = 1, .gem_itemid = 21501007 }} },
    };
    try f.send(.CS_CHARACTER_UPDATE_TEAM, @as(p.CS_Character_Update_Team, .{ .team_data = .{ .team_id = 1, .member_data = &over } }));
    try t.expectEqual(@as(i32, -1), (try f.body(.SC_CHARACTER_UPDATE_TEAM, p.SC_Character_Update_Team.Decoded)).result);
    try t.expectEqualDeep(roze.Gameplay.Catalysts.init, f.gameplay.catalysts);
}

test "reactor accepts exactly fourteen power and leaves normal equipment unchanged on response overflow" {
    var f: Fixture = .{};
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try f.index.init(arena.allocator());
    const request: p.CS_Character_Update_Team = .{ .team_data = .{ .team_id = 1, .member_data = &.{
        .{ .member_slot_id = 1, .inst_id = 1, .gem_slots = &.{ .{ .gem_slot_id = 1, .gem_itemid = 21501001 }, .{ .gem_slot_id = 2, .gem_itemid = 21501002 }, .{ .gem_slot_id = 3, .gem_itemid = 21501003 } } },
        .{ .member_slot_id = 2, .inst_id = 2, .gem_slots = &.{ .{ .gem_slot_id = 1, .gem_itemid = 21501004 }, .{ .gem_slot_id = 2, .gem_itemid = 21501005 }, .{ .gem_slot_id = 3, .gem_itemid = 21501006 } } },
    } } };
    const before = f.gameplay.character_team;
    f.capacity = 1;
    try t.expectError(error.SinkBufferOverflow, f.send(.CS_CHARACTER_UPDATE_TEAM, request));
    try t.expectEqualDeep(before, f.gameplay.character_team);
    try t.expectEqualDeep(roze.Gameplay.Catalysts.init, f.gameplay.catalysts);
    try t.expect(!f.save_requested);
    f.capacity = f.output.len;
    try f.send(.CS_CHARACTER_UPDATE_TEAM, request);
    try t.expectEqual(@as(i32, 0), (try f.body(.SC_CHARACTER_UPDATE_TEAM, p.SC_Character_Update_Team.Decoded)).result);
    try t.expectEqual(@as(u32, 21501006), f.gameplay.catalysts.normal[0][1][2]);
}

test "battle log reporting is enabled and reports are acknowledged and counted" {
    var f: Fixture = .{};
    try f.send(.CS_BATTLE_VERIFY_SWITCH_QUERY_REQ, @as(p.CS_Battle_Verify_Switch_Query_Req, .{}));
    const switch_rsp = try f.body(.SC_BATTLE_VERIFY_SWITCH_QUERY_RSP, p.SC_Battle_Verify_Switch_Query_Rsp.Decoded);
    try t.expect(switch_rsp.report_enabled);

    const report: p.CS_Battle_Log_Report = .{
        .battle_uid = 77,
        .segment_id = 3,
        .start_frame = 10,
        .end_frame = 20,
        .events = &.{
            .{
                .frame_id = 12,
                .ts_ms = 1_700_000_000_000,
                .event_data = .{ .attack_hit = .{ .inst_id = 13, .attack_uid = -1, .attack_info_id = 1003200101, .target_inst_ids = &.{ 76002, 92390 } } },
            },
            .{ .frame_id = 13, .event_data = .{ .skill_cast = .{ .inst_id = 13, .skill_id = 10032001, .skill_level = 1 } } },
            .{ .frame_id = 13, .event_data = .{ .add_buff = .{ .inst_id = 12, .buff_id = 10517, .buff_level = 1, .expected_attr_types = &.{144} } } },
        },
        .state = .{ .frame_id = 20, .characters = &.{.{ .inst_id = 12, .attrib_data = &.{.{ .attrib_type = 2, .value = 147435117 }} }} },
    };
    try f.send(.CS_BATTLE_LOG_REPORT, report);
    try f.expectCommands(&.{.SC_BATTLE_LOG_REPORT});
    const ack = try f.body(.SC_BATTLE_LOG_REPORT, p.SC_Battle_Log_Report.Decoded);
    try t.expectEqual(@as(i32, 0), ack.ret);
    try t.expectEqual(@as(u64, 77), ack.battle_uid);
    try t.expectEqual(@as(u32, 3), ack.segment_id);

    var encoded: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try roze.protobuf.encode(p.CS_Battle_Log_Report, &report, &writer);
    var decoded = try roze.protobuf.decode(p.CS_Battle_Log_Report.Decoded, writer.buffered());
    var counts: @import("battle_log.zig").SegmentCounts = .{};
    while (try decoded.events.next()) |event| counts.add(&event);
    try t.expectEqual(@as(u32, 1), counts.attack_hits);
    try t.expectEqual(@as(u32, 1), counts.skill_casts);
    try t.expectEqual(@as(u32, 1), counts.buffs);
}

fn attribBase(data: anytype, inst_id: u64, attrib_type: i32) !?i64 {
    var list = data;
    while (try list.next()) |character| {
        if (character.inst_id != inst_id) continue;
        var attribs = character.attrib_data;
        while (try attribs.next()) |attrib| if (attrib.attrib_type == attrib_type) return attrib.total_base;
    }
    return null;
}

test "Thought Experiment teams start with full HP and ultimate instead of the saved values" {
    var f: Fixture = .{};
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try f.index.init(arena.allocator());
    const Gameplay = roze.Gameplay;
    const packers = roze.protobuf.packers;
    const hp: i32 = @intFromEnum(Gameplay.Attr.hp);
    const liquid: i32 = @intFromEnum(Gameplay.Attr.permanent_liquid);

    // Both left their previous battle hurt and with a third of a gauge.
    for ([_]u64{ 3, 4 }) |inst_id| {
        const index = Gameplay.Character.Index.fromInstId(inst_id).?;
        f.gameplay.character.snapshots[index.toInt()] = .wrap(.{ .hp = 456, .permanent_liquid = 25 });
    }
    const max_hp_3 = roze.stats.maxHp(&f.index, &f.gameplay, Gameplay.Character.Index.fromInstId(3).?);
    const max_hp_4 = roze.stats.maxHp(&f.index, &f.gameplay, Gameplay.Character.Index.fromInstId(4).?);

    try f.send(.CS_CHARACTER_UPDATE_TMP_TEAM, @as(p.CS_Character_Update_Tmp_Team, .{
        .team_type = 5,
        .tmp_team_data = &.{
            .{ .team_src = .{ .src = 100501 }, .team_data = .{ .member_data = &.{.{ .member_slot_id = 1, .inst_id = 3 }} } },
            .{ .team_src = .{ .src = 100502 }, .team_data = .{ .member_data = &.{.{ .member_slot_id = 1, .inst_id = 4 }} } },
        },
    }));
    try t.expectEqual(@as(i32, 0), (try f.body(.SC_CHARACTER_UPDATE_TMP_TEAM, p.SC_Character_Update_Tmp_Team.Decoded)).result);

    // Selecting the room team before entry.
    try f.send(.CS_SET_TMP_TEAM_REQ, @as(p.CS_Set_Tmp_Team_Req, .{ .team_type = 5, .team_src = .{ .src = 100501 } }));
    const selected = (try f.body(.SC_SET_TMP_TEAM_RSP, p.SC_Set_Tmp_Team_Rsp.Decoded)).cur_team.?;
    try t.expectEqual(@as(?i64, packers.permanent_liquid_full), try attribBase(selected.attrib_data, 3, liquid));
    try t.expectEqual(@as(?i64, max_hp_3), try attribBase(selected.attrib_data, 3, hp));

    // Room entry, then the switch to the second side.
    try f.send(.CS_REQ_ABYSS_ENTER, @as(p.CS_Req_Abyss_Enter, .{ .abyss_id = 1000, .layer = 5, .room = 1 }));
    try f.send(.CS_CHARACTER_TEAMS, @as(p.CS_Character_Teams, .{}));
    const entry = (try f.body(.SC_CHARACTER_TEAMS, p.SC_Character_Teams.Decoded)).cur_team.?;
    try t.expectEqual(@as(?i64, packers.permanent_liquid_full), try attribBase(entry.attrib_data, 3, liquid));
    try t.expectEqual(@as(?i64, max_hp_3), try attribBase(entry.attrib_data, 3, hp));
    try f.send(.CS_REQ_ABYSS_PROGRESS_UPDATE, @as(p.CS_Req_Abyss_Progress_Update, .{ .abyss_id = 1000, .layer = 5, .room = 1, .finish_time = 40_000 }));
    const next = (try f.body(.SC_CHARACTER_TEMP_TEAM_NTF, p.SC_Character_Temp_Team_Ntf.Decoded)).cur_team.?;
    try t.expectEqual(@as(?i64, packers.permanent_liquid_full), try attribBase(next.attrib_data, 4, liquid));
    try t.expectEqual(@as(?i64, max_hp_4), try attribBase(next.attrib_data, 4, hp));

    // The client asks for its current team after entry: it must not get the
    // saved values back.
    try f.send(.CS_CHARACTER_TEAMS, @as(p.CS_Character_Teams, .{}));
    const teams = (try f.body(.SC_CHARACTER_TEAMS, p.SC_Character_Teams.Decoded)).cur_team.?;
    try t.expectEqual(@as(?i64, packers.permanent_liquid_full), try attribBase(teams.attrib_data, 4, liquid));
    try t.expectEqual(@as(?i64, max_hp_4), try attribBase(teams.attrib_data, 4, hp));

    // Leaving a battle (a retry) saves what was left, but the notify sent for
    // the room team still says full.
    try f.send(.CS_START_BATTLE, @as(p.CS_Start_Battle, .{ .battle_uid = 9, .battle_type = .ENM_BATTLE_TYPE_ABYSS, .battle_field_id = 100502 }));
    try f.send(.CS_LEAVE_BATTLE, @as(p.CS_Leave_Battle, .{
        .battle_uid = 9,
        .battle_type = .ENM_BATTLE_TYPE_ABYSS,
        .battle_field_id = 100502,
        .battle_result = .ENM_BATTLE_RESULT_TYPE_SUCCESS,
        .character_data = &.{.{ .inst_id = 4, .current_hp = 77, .permanent_liquid = 30 }},
    }));
    const notify = (try f.body(.SC_OUTSIDE_ATTRIB_NTF, p.SC_Outside_Attrib_Ntf.Decoded)).data.?;
    var notify_attribs = notify.attrib_data;
    var notified: ?i64 = null;
    while (try notify_attribs.next()) |attrib| if (attrib.attrib_type == liquid) {
        notified = attrib.total_base;
    };
    try t.expectEqual(@as(?i64, packers.permanent_liquid_full), notified);
    const left = f.gameplay.character.snapshots[Gameplay.Character.Index.fromInstId(4).?.toInt()].unwrap().?;
    try t.expectEqual(@as(i32, 30), left.permanent_liquid);

    // Back on the ordinary team, the saved values apply again.
    try f.send(.CS_SET_TMP_TEAM_REQ, @as(p.CS_Set_Tmp_Team_Req, .{ .team_type = 0 }));
    try t.expectEqual(@as(u32, 0), f.gameplay.transient.abyss_team_room);
    var list: packers.Buffer(packers.CharacterAttribDataBuffer, 1) = undefined;
    var attrib = list.toList();
    packers.packCharacterAttribData(&f.index, &attrib, &f.gameplay, Gameplay.Character.Index.fromInstId(4).?);
    var carried: ?i64 = null;
    for (attrib.items(.data)[0].attrib_data) |elem| if (elem.attrib_type == liquid) {
        carried = elem.total_base;
    };
    try t.expectEqual(@as(?i64, 30), carried);
}

//! Temporary teams are keyed by P_AbyssRoomTable IDs (TeamSrc.src), not room indexes.
const std = @import("std");
const roze = @import("../roze.zig");
const p = roze.protobuf.gen;
const packers = roze.protobuf.packers;
const Gameplay = roze.Gameplay;
const Abyss = Gameplay.Abyss;
const Scope = roze.Scope;
const team_type = 5;

fn indexOf(src: p.TeamSrc.Decoded) ?usize {
    if (src.src_ext != 0) return null;
    return Abyss.roomIndex(src.src);
}

fn pack(buffer: *packers.Buffer(packers.TeamDataBuffer, Abyss.room_count), i: usize, room: u64, members: Gameplay.Character.Team.Members, gems: Gameplay.Catalysts.Team) p.TmpTeamData {
    var list = buffer.toList();
    list.count = @intCast(i);
    packers.packTeamData(&list, @fromBackingInt(0), members, gems);
    list.items(.data)[i].team_id = @intCast(room);
    return .{ .team_src = .{ .src = room }, .team_data = list.items(.data)[i] };
}

pub fn CS_CHARACTER_TMP_TEAM_QUERY(scope: *Scope) Scope.Error!void {
    var req = try scope.command.take(p.CS_Character_Tmp_Team_Query.Decoded);
    var buffer: packers.Buffer(packers.TeamDataBuffer, Abyss.room_count) = undefined;
    var out: [Abyss.room_count]p.TmpTeamData = undefined;
    var seen: [Abyss.room_count]bool = @splat(false);
    var n: usize = 0;
    if (req.team_type != team_type) return scope.sink.send(.SC_CHARACTER_TMP_TEAM_QUERY, @as(p.SC_Character_Tmp_Team_Query, .{ .result = 207, .team_type = req.team_type }));
    while (try req.team_src.next()) |src| {
        const i = indexOf(src) orelse return scope.sink.send(.SC_CHARACTER_TMP_TEAM_QUERY, @as(p.SC_Character_Tmp_Team_Query, .{ .result = 207, .team_type = req.team_type }));
        if (seen[i]) continue;
        seen[i] = true;
        out[n] = pack(&buffer, n, src.src, scope.gameplay.abyss_teams[i], scope.gameplay.catalysts.abyss[i]);
        n += 1;
    }
    try scope.sink.send(.SC_CHARACTER_TMP_TEAM_QUERY, @as(p.SC_Character_Tmp_Team_Query, .{ .team_type = req.team_type, .tmp_team_data = out[0..n] }));
}

pub fn CS_CHARACTER_UPDATE_TMP_TEAM(scope: *Scope) Scope.Error!void {
    var req = try scope.command.take(p.CS_Character_Update_Tmp_Team.Decoded);
    var updated = scope.gameplay.abyss_teams;
    var updated_gems = scope.gameplay.catalysts.abyss;
    var room_ids: [Abyss.room_count]u64 = undefined;
    var indexes: [Abyss.room_count]usize = undefined;
    var seen: [Abyss.room_count]bool = @splat(false);
    var n: usize = 0;
    var valid = req.team_type == team_type;
    while (try req.tmp_team_data.next()) |entry| {
        const src = entry.team_src orelse {
            valid = false;
            break;
        };
        const i = indexOf(src) orelse {
            valid = false;
            break;
        };
        if (n == room_ids.len or seen[i]) {
            valid = false;
            break;
        }
        const team = entry.team_data orelse {
            valid = false;
            break;
        };
        const parsed = Gameplay.Catalysts.readTeam(scope.gameplay, team) catch |err| switch (err) {
            error.InvalidTeam => {
                valid = false;
                break;
            },
            else => |decode_err| return decode_err,
        };
        updated[i] = parsed.members;
        updated_gems[i] = parsed.gems;
        seen[i] = true;
        indexes[n] = i;
        room_ids[n] = src.src;
        n += 1;
    }
    // A character can participate in only one of a layer's separate room teams.
    var ri: usize = 0;
    for (roze.assets.tables.abyss) |mode| for (mode.layers) |layer| {
        var chars: Gameplay.Character.Set = .empty;
        for (layer.rooms) |_| {
            for (updated[ri]) |maybe| if (maybe.unwrap()) |ci| {
                if (chars.isSet(ci.toInt())) valid = false;
                chars.set(ci.toInt());
            };
            ri += 1;
        }
    };
    if (!valid) return scope.sink.send(.SC_CHARACTER_UPDATE_TMP_TEAM, @as(p.SC_Character_Update_Tmp_Team, .{ .result = 207, .team_type = req.team_type }));
    var buffer: packers.Buffer(packers.TeamDataBuffer, Abyss.room_count) = undefined;
    var out: [Abyss.room_count]p.TmpTeamData = undefined;
    for (out[0..n], 0..) |*entry, j| entry.* = pack(&buffer, j, room_ids[j], updated[indexes[j]], updated_gems[indexes[j]]);
    try scope.sink.send(.SC_CHARACTER_UPDATE_TMP_TEAM, @as(p.SC_Character_Update_Tmp_Team, .{ .team_type = req.team_type, .tmp_team_data = out[0..n] }));
    scope.gameplay.abyss_teams = updated;
    scope.gameplay.catalysts.abyss = updated_gems;
    scope.store.requestGameplayStateSave();
}

pub fn CS_SET_TMP_TEAM_REQ(scope: *Scope) Scope.Error!void {
    const req = try scope.command.take(p.CS_Set_Tmp_Team_Req.Decoded);
    const src = req.team_src;
    var members: Gameplay.Character.Team.Members = undefined;
    var room: u32 = 0;
    var gems = scope.gameplay.catalysts.normal[@backingInt(scope.gameplay.character_team.bits.current_team)];
    if (req.team_type == team_type and src != null) {
        const i = indexOf(src.?) orelse return scope.sink.send(.SC_SET_TMP_TEAM_RSP, @as(p.SC_Set_Tmp_Team_Rsp, .{ .result = 207, .team_type = req.team_type }));
        room = @intCast(src.?.src);
        members = scope.gameplay.abyss_teams[i];
        gems = scope.gameplay.catalysts.abyss[i];
    } else if (req.team_type == 0) {
        members = scope.gameplay.character_team.members[@backingInt(scope.gameplay.character_team.bits.current_team)];
    } else return scope.sink.send(.SC_SET_TMP_TEAM_RSP, @as(p.SC_Set_Tmp_Team_Rsp, .{ .result = 207, .team_type = req.team_type }));
    const first = for (members, 0..) |ci, i| {
        if (ci != .none) break i;
    } else return scope.sink.send(.SC_SET_TMP_TEAM_RSP, @as(p.SC_Set_Tmp_Team_Rsp, .{ .result = 207, .team_type = req.team_type }));
    var data_buffer: packers.Buffer(packers.TeamDataBuffer, 1) = undefined;
    const ordinary_slot = @backingInt(scope.gameplay.character_team.bits.using_slot);
    const selected_slot = if (room == 0 and members[ordinary_slot] != .none) ordinary_slot else first;
    var list = data_buffer.toList();
    packers.packTeamData(&list, scope.gameplay.character_team.bits.current_team, members, gems);
    if (room != 0) list.items(.data)[0].team_id = room;
    var attrib_buffer: packers.Buffer(packers.CharacterAttribDataBuffer, 4) = undefined;
    var attrib = attrib_buffer.toList();
    // A Thought Experiment room team starts full (see packers.Resources.full).
    const resources: packers.Resources = if (room != 0) .full else .saved;
    for (members) |maybe| if (maybe.unwrap()) |ci| packers.packCharacterAttribDataWith(scope.asset_index, &attrib, scope.gameplay, ci, resources);
    try scope.sink.send(.SC_SET_TMP_TEAM_RSP, @as(p.SC_Set_Tmp_Team_Rsp, .{
        .team_type = req.team_type,
        .team_src = if (room != 0) .{ .src = room } else .{},
        .cur_team = .{ .team_type = req.team_type, .team_src = if (room != 0) .{ .src = room } else .{}, .team_data = list.items(.data)[0], .using_member_slot = @intCast(selected_slot + 1), .temporary_liquid = .init, .attrib_data = attrib.items(.data) },
    }));
    scope.gameplay.transient.abyss_team_room = room;
    scope.gameplay.transient.abyss_using_slot = @fromBackingInt(@intCast(selected_slot));
}

/// The reactor UI updates gems independently of the room's character selection.
pub fn CS_TMP_TEAM_UPDATE_GEM_REQ(scope: *Scope) Scope.Error!void {
    const req = try scope.command.take(p.CS_Tmp_Team_Update_Gem_Req.Decoded);
    const entry = req.tmp_team_data;
    const index = if (entry) |e| (if (e.team_src) |src| indexOf(src) else null) else null;
    if (req.team_type != team_type or index == null or entry.?.team_data == null)
        return scope.sink.send(.SC_TMP_TEAM_UPDATE_GEM_RSP, @as(p.SC_Tmp_Team_Update_Gem_Rsp, .{ .result = 207, .team_type = req.team_type }));
    const i = index.?;
    const parsed = Gameplay.Catalysts.readTeam(scope.gameplay, entry.?.team_data.?) catch |err| switch (err) {
        error.InvalidTeam => return scope.sink.send(.SC_TMP_TEAM_UPDATE_GEM_RSP, @as(p.SC_Tmp_Team_Update_Gem_Rsp, .{ .result = 207, .team_type = req.team_type })),
        else => |decode_err| return decode_err,
    };
    // Gem-only changes must not replace characters or bypass cross-side restrictions.
    if (!std.mem.eql(Gameplay.Character.Index.Optional, &parsed.members, &scope.gameplay.abyss_teams[i]))
        return scope.sink.send(.SC_TMP_TEAM_UPDATE_GEM_RSP, @as(p.SC_Tmp_Team_Update_Gem_Rsp, .{ .result = 207, .team_type = req.team_type }));
    var buffer: packers.Buffer(packers.TeamDataBuffer, Abyss.room_count) = undefined;
    const response = pack(&buffer, 0, entry.?.team_src.?.src, parsed.members, parsed.gems);
    try scope.sink.send(.SC_TMP_TEAM_UPDATE_GEM_RSP, @as(p.SC_Tmp_Team_Update_Gem_Rsp, .{ .team_type = req.team_type, .tmp_team_data = response }));
    scope.gameplay.catalysts.abyss[i] = parsed.gems;
    scope.store.requestGameplayStateSave();
}

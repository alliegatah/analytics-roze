const std = @import("std");
const ArrayList = std.ArrayList;

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const packers = roze.protobuf.packers;
const Gameplay = roze.Gameplay;
const Scope = roze.Scope;

pub fn CS_CHARACTER_TEAMS(scope: *Scope) Scope.Error!void {
    var team_data_buffer: packers.Buffer(
        packers.TeamDataBuffer,
        Gameplay.Character.Team.count,
    ) = undefined;
    var team_data_list = team_data_buffer.toList();

    for (scope.gameplay.character_team.members, 0..) |character_indexes, team_index_int| {
        const team_index: Gameplay.Character.Team.Index = @fromBackingInt(@intCast(team_index_int));
        packers.packTeamData(&team_data_list, team_index, character_indexes, scope.gameplay.catalysts.normal[team_index_int]);
    }

    var team_character_attrib_buffer: packers.Buffer(
        packers.CharacterAttribDataBuffer,
        Gameplay.Character.Team.members_per_team,
    ) = undefined;
    var team_character_attrib_list = team_character_attrib_buffer.toList();
    packCharacterAttribListForCurrentTeam(&team_character_attrib_list, scope);
    var active_buffer: packers.Buffer(packers.TeamDataBuffer, 1) = undefined;
    var active_list = active_buffer.toList();
    packers.packTeamData(&active_list, scope.gameplay.character_team.bits.current_team, scope.gameplay.activeTeamMembers(), scope.gameplay.activeTeamGems());
    const room = scope.gameplay.transient.abyss_team_room;
    if (room != 0) active_list.items(.data)[0].team_id = room;

    const response: protobuf.gen.SC_Character_Teams = .{
        .teams = team_data_list.items(.data),
        .cur_team = .{
            .team_data = active_list.items(.data)[0],
            .team_type = if (room != 0) 5 else 0,
            .using_member_slot = scope.gameplay.activeTeamSlot().toSlotId(),
            .attrib_data = team_character_attrib_list.items(.data),
            .team_src = .{ .src = room, .src_ext = 0 },
            .temporary_liquid = .init,
        },
    };

    try scope.sink.send(.SC_CHARACTER_TEAMS, response);
}

pub fn CS_CHARACTER_UPDATE_TEAM(scope: *Scope) Scope.Error!void {
    const log = std.log.scoped(.@"roze::commands::character_update_team");

    const request = try scope.command.take(protobuf.gen.CS_Character_Update_Team.Decoded);
    const team_data_in = request.team_data orelse {
        log.debug("team_data is null", .{});
        return try scope.sink.send(
            .SC_CHARACTER_UPDATE_TEAM,
            @as(protobuf.gen.SC_Character_Update_Team, .{ .result = -1 }),
        );
    };

    const team_index = Gameplay.Character.Team.Index.fromTeamId(team_data_in.team_id) orelse {
        log.debug("invalid team id: {d}", .{team_data_in.team_id});
        return try scope.sink.send(
            .SC_CHARACTER_UPDATE_TEAM,
            @as(protobuf.gen.SC_Character_Update_Team, .{ .result = -1 }),
        );
    };

    const parsed = Gameplay.Catalysts.readTeam(scope.gameplay, team_data_in) catch |err| switch (err) {
        error.InvalidTeam => return scope.sink.send(.SC_CHARACTER_UPDATE_TEAM, @as(protobuf.gen.SC_Character_Update_Team, .{ .result = -1 })),
        else => |decode_err| return decode_err,
    };
    const first_used_slot: Gameplay.Character.Team.Slot = for (parsed.members, 0..) |ci, i| {
        if (ci != .none) break @fromBackingInt(@intCast(i));
    } else return scope.sink.send(.SC_CHARACTER_UPDATE_TEAM, @as(protobuf.gen.SC_Character_Update_Team, .{ .result = -1 }));

    var using_slot = scope.gameplay.character_team.bits.using_slot;
    var attrib_buffer: packers.Buffer(packers.CharacterAttribDataBuffer, Gameplay.Character.Team.members_per_team) = undefined;
    var attrib = attrib_buffer.toList();
    if (scope.gameplay.character_team.bits.current_team == team_index) {
        if (parsed.members[@backingInt(using_slot)] == .none) using_slot = first_used_slot;
        const members = if (scope.gameplay.transient.abyss_team_room == 0) parsed.members else scope.gameplay.activeTeamMembers();
        for (members) |maybe| if (maybe.unwrap()) |ci|
            packers.packCharacterAttribData(scope.asset_index, &attrib, scope.gameplay, ci);
    }
    var team_data_buffer: packers.Buffer(packers.TeamDataBuffer, 1) = undefined;
    var team_data_list = team_data_buffer.toList();
    packers.packTeamData(&team_data_list, team_index, parsed.members, parsed.gems);
    try scope.sink.send(.SC_CHARACTER_UPDATE_TEAM, @as(protobuf.gen.SC_Character_Update_Team, .{
        .team_data = team_data_list.items(.data)[0],
        .using_member_slot = using_slot.toSlotId(),
        .attrib_data = attrib.items(.data),
    }));
    scope.gameplay.character_team.members[@backingInt(team_index)] = parsed.members;
    scope.gameplay.catalysts.normal[@backingInt(team_index)] = parsed.gems;
    scope.gameplay.character_team.bits.using_slot = using_slot;
    scope.store.requestGameplayStateSave();
}

pub fn CS_CHARACTER_SWITCH_TEAM(scope: *Scope) Scope.Error!void {
    const log = std.log.scoped(.@"roze::commands::character_switch_team");

    const request = try scope.command.take(protobuf.gen.CS_Character_Switch_Team.Decoded);
    const team_index = Gameplay.Character.Team.Index.fromTeamId(request.team_id) orelse {
        log.debug("invalid team id: {d}", .{request.team_id});
        return try scope.sink.send(
            .SC_CHARACTER_SWITCH_TEAM,
            @as(protobuf.gen.SC_Character_Switch_Team, .{ .result = -1 }),
        );
    };

    if (team_index == scope.gameplay.character_team.bits.current_team and scope.gameplay.transient.abyss_team_room == 0) {
        log.debug("team with specified id is already active", .{});
        return try scope.sink.send(
            .SC_CHARACTER_SWITCH_TEAM,
            @as(protobuf.gen.SC_Character_Switch_Team, .{ .result = -1 }),
        );
    }

    const prev_using_slot = scope.gameplay.character_team.bits.using_slot;
    const switch_to_team_members = scope.gameplay.character_team.members[@backingInt(team_index)];

    const new_using_slot: Gameplay.Character.Team.Slot =
        if (switch_to_team_members[@backingInt(prev_using_slot)] != .none)
            prev_using_slot
        else find_new: for (switch_to_team_members, 0..) |character_index_maybe, slot_index| {
            if (character_index_maybe != .none)
                break :find_new @fromBackingInt(@intCast(slot_index));
        } else {
            log.debug(
                "tried to switch to team with id {d} while it doesn't have any members",
                .{request.team_id},
            );

            return try scope.sink.send(
                .SC_CHARACTER_SWITCH_TEAM,
                @as(protobuf.gen.SC_Character_Switch_Team, .{ .result = -1 }),
            );
        };

    scope.gameplay.character_team.bits.current_team = team_index;
    scope.gameplay.transient.abyss_team_room = 0;
    scope.gameplay.character_team.bits.using_slot = new_using_slot;

    var team_character_attrib_buffer: packers.Buffer(
        packers.CharacterAttribDataBuffer,
        Gameplay.Character.Team.members_per_team,
    ) = undefined;
    var team_character_attrib_list = team_character_attrib_buffer.toList();
    packCharacterAttribListForCurrentTeam(&team_character_attrib_list, scope);

    const response: protobuf.gen.SC_Character_Switch_Team = .{
        .team_id = team_index.toTeamId(),
        .using_member_slot = new_using_slot.toSlotId(),
        .attrib_data = team_character_attrib_list.items(.data),
    };

    try scope.sink.send(.SC_CHARACTER_SWITCH_TEAM, response);

    errdefer comptime unreachable; // Ensure that it's safe to request save.
    scope.store.requestGameplayStateSave();
}

fn packCharacterAttribListForCurrentTeam(
    list: *packers.List(packers.CharacterAttribDataBuffer),
    scope: *Scope,
) void {
    for (scope.gameplay.activeTeamMembers()) |character_index_maybe| {
        const character_index = character_index_maybe.unwrap() orelse continue;

        protobuf.packers.packCharacterAttribData(
            scope.asset_index,
            list,
            scope.gameplay,
            character_index,
        );
    }
}

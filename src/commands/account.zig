const std = @import("std");

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const packers = roze.protobuf.packers;
const Scope = roze.Scope;
const assets = roze.assets;

const log = std.log.scoped(.@"roze::commands::account");

pub fn CS_SCHEMA_INFO_SYNC(scope: *Scope) Scope.Error!void {
    const response: protobuf.gen.SC_Schema_Info_Sync = .{
        .result = 0,
        .login_id = scope.store.role_id,
    };

    try scope.sink.send(.SC_SCHEMA_INFO_SYNC, response);
}

pub fn CS_ROLE_LOGIN(scope: *Scope) Scope.Error!void {
    const response: protobuf.gen.SC_Role_Login = .{
        .result = 0,
        .game_svr_url = "",
        .port = 0,
        .map_id = scope.gameplay.map.id,
        .today_first_login = true,
        .current_savepoint = assets.npc_lists.save_point_npc_ids[scope.gameplay.map.save_point_index],
        .is_inited_name = true,
        .time_zone_offset_seconds = 0,
    };

    try scope.sink.send(.SC_ROLE_LOGIN, response);
}

pub fn CS_ENTER_MAP(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Enter_Map.Decoded);
    log.info("received enter map request: {any}", .{request});

    var unlocked_savepoints_buffer: packers.UnlockedSavepointsBuffer = undefined;
    const unlocked_savepoints = packers.packUnlockedSavepoints(
        &unlocked_savepoints_buffer,
        &scope.gameplay.save_point_unlock,
    );

    var unlocked_teleport_id_list_buffer: packers.UnlockedTeleportsBuffer = undefined;
    const unlocked_teleport_id_list = packers.packUnlockedTeleportIdList(
        &unlocked_teleport_id_list_buffer,
        &scope.gameplay.teleport_point_unlock,
    );

    const current_savepoint = assets.npc_lists.save_point_npc_ids[scope.gameplay.map.save_point_index];

    // Entering the world map at the current save point is what happens on login.
    // Anything else is the client moving somewhere on its own accord (a dungeon map,
    // a teleport point, another save point), in which case we send it where it asked to go.
    const is_transition = (request.map_id != 0 and request.map_id != scope.gameplay.map.id) or
        request.teleport_id != 0 or
        (request.savepoint_id != 0 and request.savepoint_id != current_savepoint);

    const readiness: protobuf.gen.SC_Map_Ready_Ntf = if (is_transition) .{
        .map_id = if (request.map_id != 0) request.map_id else scope.gameplay.map.id,
        .last_logout_location = .init,
        .born_pos_type = if (request.teleport_id != 0)
            .ENM_BORN_TELEPORT
        else if (request.savepoint_id != 0)
            .ENM_BORN_SAVE_POINT
        else
            .ENM_BORN_DEFAULT_POS,
        .rotation = .{ .x = 0, .y = 0, .z = 0 },
        .current_savepoint = current_savepoint,
        .unlocked_savepoints = unlocked_savepoints,
        .unlocked_teleport_id_list = unlocked_teleport_id_list,
        .teleport_id = request.teleport_id,
        .savepoint_id = request.savepoint_id,
    } else .{
        .map_id = scope.gameplay.map.id,
        .last_logout_location = .init,
        .born_pos_type = .ENM_BORN_SAVE_POINT,
        .rotation = .{ .x = 0, .y = 0, .z = 0 },
        .current_savepoint = current_savepoint,
        .unlocked_savepoints = unlocked_savepoints,
        .unlocked_teleport_id_list = unlocked_teleport_id_list,
    };

    try scope.sink.send(.SC_MAP_READY_NTF, readiness);

    const response: protobuf.gen.SC_Enter_Map = .{
        .role_id = request.role_id,
        .map_id = request.map_id,
        .teleport_id = if (is_transition) request.teleport_id else 0,
        .map_info = .{
            .current_gametime = @backingInt(scope.gameplay.map.bits.time),
            .current_weather = scope.gameplay.map.bits.weather.toWeatherTypeInt(),
        },
        .savepoint_id = if (is_transition and request.savepoint_id != 0)
            request.savepoint_id
        else
            current_savepoint,
    };

    try scope.sink.send(.SC_ENTER_MAP, response);
}

pub fn CS_FIN_ENTER_MAP(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Fin_Enter_Map.Decoded);
    log.info("received fin enter map request: {any}", .{request});

    var base_info: protobuf.gen.RoleBaseInfo = .{
        .role_id = scope.store.role_id,
        .role_name = "analytics.moe",
        .role_level = @intCast(scope.level.team),
        .gender = .ENM_GENDER_FEMALE,
        .role_name_inited = true,
        .level_Data = .{
            .world_level_max = scope.level.world,
            .world_level_cur = scope.level.world,
            .team_level = scope.level.team,
            .team_exp = 0,
        },
        .second_role_name = "analytics.moe",
    };

    base_info.player_attr = &.{
        .{
            .attr_type = @backingInt(protobuf.gen.PlayerAttrType.ENM_PLAYER_ATTR_COIN),
            .value = .{ .value_uint32 = 1337 },
        },
        .{
            .attr_type = @backingInt(protobuf.gen.PlayerAttrType.ENM_PLAYER_ATTR_SATIETY),
            .value = .{ .value_uint32 = 100 },
        },
        .{
            .attr_type = @backingInt(protobuf.gen.PlayerAttrType.ENM_PLAYER_ATTR_STAMINA_CUR),
            .value = .{ .value_uint32 = 100 },
        },
        .{
            .attr_type = @backingInt(protobuf.gen.PlayerAttrType.ENM_PLAYER_ATTR_STAMINA_FULLTIME),
            .value = .{ .value_uint32 = 100 },
        },
    };

    var unlocked_savepoints_buffer: packers.UnlockedSavepointsBuffer = undefined;
    const unlocked_savepoints = packers.packUnlockedSavepoints(
        &unlocked_savepoints_buffer,
        &scope.gameplay.save_point_unlock,
    );

    var unlocked_teleport_id_list_buffer: packers.UnlockedTeleportsBuffer = undefined;
    const unlocked_teleport_id_list = packers.packUnlockedTeleportIdList(
        &unlocked_teleport_id_list_buffer,
        &scope.gameplay.teleport_point_unlock,
    );

    const response: protobuf.gen.SC_Fin_Enter_Map = .{
        .role_id = request.role_id,
        .map_id = request.map_id,
        .role_info = .{
            .base_info = base_info,
            .map_info = .{
                .current_gametime = @backingInt(scope.gameplay.map.bits.time),
                .current_weather = scope.gameplay.map.bits.weather.toWeatherTypeInt(),
            },
            .global_conf = .{
                .satiety_limit = 100,
                .stamina_regen_max = 100,
                .stamina_regen_interval = 100,
                .max_silver_creature_cost = 100,
                .max_silver_creature_num = 1,
                .unlock_collection_range = 1,
                .launch_date = "2026-06-06T06:06:06",
                .launch_date_type = 0,
            },
        },
        .last_logout_location = .init,
        .current_savepoint = assets.npc_lists.save_point_npc_ids[scope.gameplay.map.save_point_index],
        .born_pos_type = .ENM_BORN_POSITION,
        .task_data = .init,
        .world_map_id = scope.gameplay.map.id,
        .unlocked_savepoints = unlocked_savepoints,
        .unlocked_teleport_id_list = unlocked_teleport_id_list,
    };

    try scope.sink.send(.SC_FIN_ENTER_MAP, response);
}

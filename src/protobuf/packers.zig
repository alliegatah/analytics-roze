const std = @import("std");
const assert = std.debug.assert;
const ArrayList = std.ArrayList;

const roze = @import("../roze.zig");
const assets = roze.assets;
const protobuf = roze.protobuf;
const Gameplay = roze.Gameplay;

pub fn Buffer(comptime Struct: type, comptime n: usize) type {
    return struct {
        const struct_info = @typeInfo(Struct).@"struct";

        pub const Data = Data: {
            var array_types: [struct_info.field_types.len]type = undefined;
            for (&array_types, struct_info.field_types) |*ArrayType, FieldType|
                ArrayType.* = [n]FieldType;

            break :Data @Struct(.auto, null, struct_info.field_names, &array_types, &@splat(.{}));
        };

        data: Data,

        pub fn toList(b: *@This()) List(Struct) {
            var list: List(Struct) = .{
                .ptrs = undefined,
                .capacity = n,
                .count = 0,
            };

            inline for (&list.ptrs, struct_info.field_names) |*ptr, field_name| {
                ptr.* = @ptrCast(&@field(b.data, field_name));
            }

            return list;
        }
    };
}

pub fn List(comptime Struct: type) type {
    const struct_info = @typeInfo(Struct).@"struct";

    return struct {
        ptrs: [struct_info.field_names.len][*]u8,
        capacity: u32,
        count: u32,

        pub fn items(
            list: *@This(),
            comptime field: std.meta.FieldEnum(Struct),
        ) []struct_info.field_types[@backingInt(field)] {
            const T = struct_info.field_types[@backingInt(field)];

            return @as([*]T, @ptrCast(@alignCast(list.ptrs[@backingInt(field)])))[0..list.count];
        }

        pub fn addOneAssumeCapacity(list: *@This()) Handle {
            const i = list.count;
            list.count += 1;

            var handle: Handle = undefined;

            inline for (struct_info.field_names, 0..) |field_name, field_index| {
                @field(handle, field_name) = &list.items(@fromBackingInt(field_index))[i];
            }

            return handle;
        }

        pub const Handle = Handle: {
            var pointer_types: [struct_info.field_types.len]type = undefined;
            for (&pointer_types, struct_info.field_types) |*PointerType, FieldType|
                PointerType.* = *FieldType;

            break :Handle @Struct(.auto, null, struct_info.field_names, &pointer_types, &@splat(.{}));
        };
    };
}

pub fn packVector3Int(values: *const [3]i32) protobuf.gen.Vector3Int {
    return .{ .x = values[0], .y = values[1], .z = values[2] };
}

pub const CharacterAttribDataBuffer = struct {
    data: protobuf.gen.PBCharacterAttribData,
    list: [Gameplay.Attr.count]protobuf.gen.PBAttribDataElem,
};

/// How the current-state attributes (HP and ultimate) are filled.
pub const Resources = enum {
    /// What the character had when it last left a battle (CS_LEAVE_BATTLE).
    saved,
    /// Full HP and ultimate. p_dungeonstypetable sets CharacterHpRatio and
    /// CharacterPermanentLiquidRatio to 10000 (100%) for dungeon type 1, which
    /// Thought Experiment uses, so its teams start every battle full.
    full,
};

/// Sent for a full ultimate. Roze does not compute PERMANENT_LIQUID_MAX (1151);
/// the client caps the current value at each character's own maximum, so this
/// is the attribute's table maximum (s_battleattributetable 1150) rather than a
/// per-character value.
pub const permanent_liquid_full: i32 = 1_000_000_000;

/// Packs a character's attributes. Members of an active Thought Experiment
/// room team always get full HP and ultimate: the client applies whichever
/// attribute packet arrives last (team queries, team edits, the notify after a
/// battle), so every one of them has to agree with the room's start values.
pub fn packCharacterAttribData(
    asset_index: *const assets.Index,
    list: *List(CharacterAttribDataBuffer),
    gameplay: *const Gameplay,
    index: Gameplay.Character.Index,
) void {
    packCharacterAttribDataWith(asset_index, list, gameplay, index, resourcesFor(gameplay, index));
}

pub fn resourcesFor(gameplay: *const Gameplay, index: Gameplay.Character.Index) Resources {
    if (gameplay.transient.abyss_team_room == 0) return .saved;
    for (gameplay.activeTeamMembers()) |member| {
        if (member.unwrap()) |ci| if (ci == index) return .full;
    }
    return .saved;
}

pub fn packCharacterAttribDataWith(
    asset_index: *const assets.Index,
    list: *List(CharacterAttribDataBuffer),
    gameplay: *const Gameplay,
    index: Gameplay.Character.Index,
    resources: Resources,
) void {
    const handle = list.addOneAssumeCapacity();
    var attrib_data: std.ArrayList(protobuf.gen.PBAttribDataElem) = .initBuffer(handle.list);

    const sheet = roze.stats.compute(asset_index, gameplay, index);
    const optional_snapshot = gameplay.character.snapshots[index.toInt()];

    for (std.enums.values(Gameplay.Attr), sheet.values) |attrib_type, value| {
        switch (attrib_type) {
            // These two are the current state, not something to compute. See below.
            .hp, .permanent_liquid => continue,
            // Characters don't have these on their own, only gear grants them.
            .atk_damage_add_rate, .atk_basic_attack_damage_add_rate => {
                if (value.base == 0 and value.multi == 0 and value.add == 0) continue;
            },
            else => {},
        }

        attrib_data.appendAssumeCapacity(.{
            .attrib_type = @backingInt(attrib_type),
            .total_base = value.base,
            .total_multi = value.multi,
            .total_add = value.add,
        });
    }

    if (resources == .full) {
        attrib_data.appendAssumeCapacity(.{
            .attrib_type = @backingInt(Gameplay.Attr.hp),
            .total_base = sheet.total(.maxhp),
        });

        attrib_data.appendAssumeCapacity(.{
            .attrib_type = @backingInt(Gameplay.Attr.permanent_liquid),
            .total_base = permanent_liquid_full,
        });
    } else if (optional_snapshot.unwrap()) |snapshot| {
        attrib_data.appendAssumeCapacity(.{
            .attrib_type = @backingInt(Gameplay.Attr.hp),
            .total_base = snapshot.hp,
        });

        attrib_data.appendAssumeCapacity(.{
            .attrib_type = @backingInt(Gameplay.Attr.permanent_liquid),
            .total_base = snapshot.permanent_liquid,
        });
    } else {
        attrib_data.appendAssumeCapacity(.{
            .attrib_type = @backingInt(Gameplay.Attr.hp),
            .total_base = sheet.total(.maxhp),
        });
    }

    handle.data.* = .{
        .inst_id = index.toInstId(),
        .attrib_data = attrib_data.items,
    };
}

pub fn packCharacterData(
    gameplay: *const Gameplay,
    index: Gameplay.Character.Index,
) protobuf.gen.CharacterData {
    const bits = gameplay.character.bits[index.toInt()];

    return .{
        .level = bits.level.toInt(),
        .exp = bits.exp.toInt(),
        .break_level = bits.break_level.toInt(),
        .inst_id = index.toInstId(),
        .character_id = @backingInt(index.toId()),
        .motive_uniq_id = @backingInt(gameplay.character.motives[index.toInt()]),
    };
}

pub fn packMotiveElem(
    gameplay: *const Gameplay,
    uid: Gameplay.Character.MotiveUniqueId,
    claim_time_ms: u64,
) protobuf.gen.CSMotiveElem {
    const config = uid.config();

    return .{
        .uniq_id = uid.toInt(),
        .motive_id = config.id,
        .claim_time = claim_time_ms,
        .lv = @intCast(config.level),
        .refinelv = gameplay.transient.sandbox.refineOf(uid),
        .equiped_target = if (gameplay.character.motiveOwner(uid)) |owner| owner.toInstId() else 0,
        .locked = false,
        .item_id = config.item_id,
    };
}

pub fn packEquipmentData(
    gameplay: *const Gameplay,
    uid: Gameplay.Equipment.UniqueId,
) protobuf.gen.CmdEquipmentData {
    const config = uid.config();

    return .{
        .tid = config.id,
        .uid = uid.toInt(),
        .owner_uid = if (gameplay.equipment.owner(uid)) |owner| owner.toInstId() else 0,
        .refine_level_array = config.refine_levels,
    };
}

pub const TeamDataBuffer = struct {
    data: protobuf.gen.TeamData,
    members: [Gameplay.Character.Team.members_per_team]protobuf.gen.TeamMemberData,
    gems: [Gameplay.Character.Team.members_per_team][Gameplay.Catalysts.slots_per_member]protobuf.gen.GemSlotData,
};

pub fn packTeamData(
    list: *List(TeamDataBuffer),
    team_index: Gameplay.Character.Team.Index,
    character_indexes: Gameplay.Character.Team.Members,
    gems: Gameplay.Catalysts.Team,
) void {
    const handle = list.addOneAssumeCapacity();
    var member_slots: ArrayList(protobuf.gen.TeamMemberData) = .initBuffer(handle.members);

    for (character_indexes, 0..) |character_index_maybe, slot_int| {
        const character_index = character_index_maybe.unwrap() orelse continue;
        const slot: Gameplay.Character.Team.Slot = @fromBackingInt(@intCast(slot_int));

        for (gems[slot_int], 0..) |id, gem_slot| {
            handle.gems[slot_int][gem_slot] = .{
                .gem_slot_id = @intCast(gem_slot + 1),
                .gem_itemid = id,
                .gem_state = if (id == 0) .EMPTY else .VALID,
            };
        }
        member_slots.appendAssumeCapacity(.{
            .member_slot_id = slot.toSlotId(),
            .inst_id = character_index.toInstId(),
            .character_id = @backingInt(character_index.toId()),
            .gem_slots = handle.gems[slot_int][0..],
        });
    }

    handle.data.* = .{
        .team_id = team_index.toTeamId(),
        .member_data = member_slots.items,
        .name = "analytics.moe",
    };
}

pub const UnlockedSavepointsBuffer = [assets.npc_lists.save_point_npc_ids.len]u64;

pub fn packUnlockedSavepoints(
    buffer: *UnlockedSavepointsBuffer,
    set: *const Gameplay.SavePointSet,
) []const u64 {
    var count: usize = 0;
    var iterator = set.iterator(.{});

    while (iterator.next()) |index| {
        defer count += 1;
        buffer[count] = assets.npc_lists.save_point_npc_ids[index];
    }

    return buffer[0..count];
}

pub const UnlockedTeleportsBuffer = [assets.npc_lists.teleport_point_npc_ids.len]u64;

pub fn packUnlockedTeleportIdList(
    buffer: *UnlockedTeleportsBuffer,
    set: *const Gameplay.TeleportPointSet,
) []const u64 {
    var count: usize = 0;
    var iterator = set.iterator(.{});

    while (iterator.next()) |index| {
        defer count += 1;
        buffer[count] = assets.npc_lists.teleport_point_npc_ids[index];
    }

    return buffer[0..count];
}

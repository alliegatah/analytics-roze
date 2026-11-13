const Gameplay = @This();
const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const IntegerBitSet = std.bit_set.IntegerBitSet;

const roze = @import("roze.zig");
const Io = roze.Io;
const assets = roze.assets;

const log = std.log.scoped(.@"roze::Gameplay");

map: Map,
save_point_unlock: SavePointSet,
teleport_point_unlock: TeleportPointSet,
character: Character,
character_team: Character.Team,
equipment: Equipment,
abyss: Abyss.State,
abyss_teams: [Abyss.room_count]Character.Team.Members,
catalysts: Catalysts,
/// Not persisted, starts over on every login.
transient: Transient,

pub const init: Gameplay = init: {
    @setEvalBranchQuota(1_000_000);

    var gameplay: Gameplay = .{
        .map = .init,
        // Sandbox: the whole world is reachable by fast travel from the start.
        .save_point_unlock = .full,
        .teleport_point_unlock = .full,
        .character = .init,
        .character_team = .init,
        .equipment = .init,
        .abyss = .init,
        .abyss_teams = @splat(@splat(.none)),
        .catalysts = .init,
        .transient = .init,
    };
    gameplay.equipDefaults();

    break :init gameplay;
};

pub const Transient = struct {
    abyss_team_room: u32,
    abyss_using_slot: Character.Team.Slot,
    /// The dungeon the player has asked to enter and not finished yet, 0 if none.
    dungeon_id: u64,
    /// The last battle the client reported as completed inside `dungeon_id`.
    dungeon_battle_id: u32,
    /// Unique id of the silver creature taken into battle, 0 if none.
    silver_creature_uniq_id: u64,
    /// Weapon refine and psyche levels from `sandbox.zon`, read at login.
    sandbox: roze.sandbox.Levels,

    pub const init: Transient = .{
        .abyss_team_room = 0,
        .abyss_using_slot = @fromBackingInt(0),
        .dungeon_id = 0,
        .dungeon_battle_id = 0,
        .silver_creature_uniq_id = 0,
        .sandbox = .default,
    };
};

pub const Abyss = @import("Abyss.zig");
pub const Catalysts = @import("Catalysts.zig");

pub fn activeTeamGems(gameplay: *const Gameplay) Catalysts.Team {
    if (Abyss.roomIndex(gameplay.transient.abyss_team_room)) |i|
        return gameplay.catalysts.abyss[i];
    return gameplay.catalysts.normal[@backingInt(gameplay.character_team.bits.current_team)];
}

pub fn activeTeamMembers(gameplay: *const Gameplay) Character.Team.Members {
    if (Abyss.roomIndex(gameplay.transient.abyss_team_room)) |i|
        return gameplay.abyss_teams[i];
    return gameplay.character_team.members[@backingInt(gameplay.character_team.bits.current_team)];
}

pub fn activeTeamSlot(gameplay: *const Gameplay) Character.Team.Slot {
    return if (gameplay.transient.abyss_team_room != 0)
        gameplay.transient.abyss_using_slot
    else
        gameplay.character_team.bits.using_slot;
}

/// Rebuild the active temporary team when a saved Abyss attempt is resumed.
fn restoreAbyssTeam(gameplay: *Gameplay) void {
    const run = gameplay.abyss.run;
    if (run.abyss_id == 0) return;
    const location = Abyss.locate(run.abyss_id, run.layer) catch return;
    if (run.room == 0 or run.room > location.config.rooms.len) return;
    const room = location.config.rooms[run.room - 1];
    const index = Abyss.roomIndex(room) orelse return;
    for (gameplay.abyss_teams[index], 0..) |member, i| {
        if (member == .none) continue;
        gameplay.transient.abyss_team_room = room;
        gameplay.transient.abyss_using_slot = @fromBackingInt(@intCast(i));
        return;
    }
}

/// Gives every playable character that has nothing equipped a weapon and a core gear piece,
/// preferring the ones the trial presets pair it with.
pub fn equipDefaults(gameplay: *Gameplay) void {
    for (assets.tables.character_growth) |*growth| {
        const id = Character.Id.fromInt(growth.character_id) orelse continue;
        const i = id.toIndex().toInt();

        if (gameplay.character.motives[i] == .none) {
            const identity_type = assets.tables.character[i].identity_type;

            const free: ?Character.MotiveUniqueId = free: {
                for (growth.preferred_motives) |motive_id| {
                    if (gameplay.character.freeMotive(motive_id)) |uid| break :free uid;
                }
                for (assets.tables.motive) |config| {
                    if (config.identity_type != identity_type) continue;
                    if (gameplay.character.freeMotive(config.id)) |uid| break :free uid;
                }
                break :free null;
            };

            if (free) |uid| gameplay.character.motives[i] = .wrap(uid);
        }

        for (growth.preferred_equipment) |equipment_id| {
            const uid = gameplay.equipment.free(equipment_id) orelse continue;
            const slot = uid.slot() orelse continue;
            if (gameplay.equipment.worn[i][slot] != .none) continue;

            gameplay.equipment.worn[i][slot] = .wrap(uid);
            break;
        }
    }
}

/// Drops references to weapons and gear that don't exist (anymore).
fn sanitize(gameplay: *Gameplay) void {
    for (&gameplay.character.motives) |*motive| {
        if (@backingInt(motive.*) > Character.MotiveUniqueId.count) motive.* = .none;
    }

    for (&gameplay.equipment.worn) |*worn| for (worn) |*uid| {
        if (@backingInt(uid.*) > Equipment.UniqueId.count) uid.* = .none;
    };
}

/// Gear. The player owns `UniqueId.copies` of every piece in `assets.tables.equipment`,
/// so the only thing to keep track of is who wears what.
pub const Equipment = struct {
    /// See `P_EquipmentSlotTable`. Slot ids start at 1, the indexes here at 0.
    pub const slot_count = 6;

    worn: [Character.count]Worn,

    pub const Worn = [slot_count]UniqueId.Optional;

    pub const init: Equipment = .{
        .worn = @splat(@splat(.none)),
    };

    /// The character wearing `uid`, if any.
    pub fn owner(equipment: *const Equipment, uid: UniqueId) ?Character.Index {
        const slot = uid.slot() orelse return null;
        for (&equipment.worn, 0..) |*worn, character_index| {
            if (worn[slot] == UniqueId.Optional.wrap(uid))
                return .fromInt(character_index);
        }

        return null;
    }

    /// A copy of the piece with table id `equipment_id` that nobody wears.
    pub fn free(equipment: *const Equipment, equipment_id: u32) ?UniqueId {
        for (assets.tables.equipment, 0..) |config, table_index| {
            if (config.id != equipment_id) continue;

            for (0..UniqueId.copies) |copy| {
                const uid: UniqueId = .fromInstance(table_index * UniqueId.copies + copy);
                if (equipment.owner(uid) == null) return uid;
            }
        }

        return null;
    }

    pub const UniqueId = enum(u16) {
        _,

        /// Enough for a whole team to wear the same set.
        pub const copies = Character.Team.members_per_team;
        pub const count = assets.tables.equipment.len * copies;

        /// Asserts bounds.
        pub fn fromInstance(instance: usize) UniqueId {
            assert(instance < count);
            return @fromBackingInt(@intCast(instance + 1));
        }

        pub fn fromInt(int: u64) ?UniqueId {
            if (int == 0 or int > count) return null;
            return @fromBackingInt(@intCast(int));
        }

        pub fn toInt(uid: UniqueId) u64 {
            return @backingInt(uid);
        }

        pub fn config(uid: UniqueId) *const assets.tables.S_Equipment {
            return &assets.tables.equipment[(@backingInt(uid) - 1) / copies];
        }

        /// Index into `Worn`. Null if the table has a slot id we don't know about.
        pub fn slot(uid: UniqueId) ?usize {
            const slot_id = uid.config().slot;
            if (slot_id == 0 or slot_id > slot_count) return null;
            return slot_id - 1;
        }

        pub const Optional = enum(u16) {
            none = 0,
            _,

            pub fn wrap(uid: UniqueId) UniqueId.Optional {
                return @fromBackingInt(@backingInt(uid));
            }

            pub fn unwrap(o: UniqueId.Optional) ?UniqueId {
                return switch (o) {
                    .none => null,
                    _ => @fromBackingInt(@backingInt(o)),
                };
            }
        };
    };
};

pub const SavePointSet = IntegerBitSet(assets.npc_lists.save_point_npc_ids.len);

pub const TeleportPointSet = IntegerBitSet(assets.npc_lists.teleport_point_npc_ids.len);

pub const Map = extern struct {
    id: u64,
    save_point_index: u32,
    bits: Bits,

    comptime {
        assert(std.meta.hasUniqueRepresentation(Map));
    }

    pub const starting_save_point_id = 12020019;

    pub const starting_save_point_index: u32 = assets.npc_lists.getSavePointIndexByNpcId(
        starting_save_point_id,
    ).?;

    pub const init: Map = .{
        .id = 100001001002,
        .save_point_index = Map.starting_save_point_index,
        .bits = .{
            .weather = .rainy,
            .time = @fromBackingInt(0),
        },
    };

    pub const Bits = packed struct(u32) {
        weather: Weather,
        time: Time,
        _: u19 = 0,
    };

    pub const Weather = enum(u2) {
        pub const count = @typeInfo(Map.Weather).@"enum".field_names.len;

        sunny = 0,
        rainy = 1,
        after_rain = 2,
        foggy = 3,

        pub fn toWeatherTypeInt(weather: Map.Weather) u32 {
            return @as(u32, @backingInt(weather)) + 1;
        }

        pub fn fromWeatherTypeInt(int: u32) ?Map.Weather {
            if (int == 0) return null;
            if (int > Map.Weather.count) return null;

            const casted = std.math.cast(u2, int - 1) orelse return null;
            return @fromBackingInt(casted);
        }
    };

    pub const Time = enum(u11) {
        pub const base = 1440;

        _,
    };
};

pub const Character = struct {
    pub const count = assets.tables.character.len;
    pub const Set = IntegerBitSet(Character.count);

    unlocked: Character.Set,
    bits: [Character.count]Bits,
    motives: [Character.count]MotiveUniqueId.Optional,
    snapshots: [Character.count]Snapshot.Optional,

    pub const init: Character = .{
        .unlocked = .full,
        .bits = @splat(.max),
        .motives = @splat(.none),
        .snapshots = @splat(.none),
    };

    /// Yields unlocked character indexes.
    pub fn iterator(character: *Character) Character.Iterator {
        return .{ .inner = character.unlocked.iterator(.{}) };
    }

    /// The character holding the weapon `uid`, if any.
    pub fn motiveOwner(character: *const Character, uid: MotiveUniqueId) ?Character.Index {
        for (&character.motives, 0..) |motive, character_index| {
            if (motive == MotiveUniqueId.Optional.wrap(uid))
                return .fromInt(character_index);
        }

        return null;
    }

    /// A copy of the weapon with table id `motive_id` that nobody holds.
    pub fn freeMotive(character: *const Character, motive_id: u32) ?MotiveUniqueId {
        for (assets.tables.motive, 0..) |config, table_index| {
            if (config.id != motive_id) continue;

            for (0..MotiveUniqueId.copies) |copy| {
                const uid: MotiveUniqueId = .fromInstance(table_index * MotiveUniqueId.copies + copy);
                if (character.motiveOwner(uid) == null) return uid;
            }
        }

        return null;
    }

    pub const Index = enum(u32) {
        _,

        pub const default = Character.Id.default.toIndex();

        /// Asserts bounds.
        pub fn fromInt(int: usize) Index {
            assert(int < Character.count);
            return @fromBackingInt(@intCast(int));
        }

        pub fn toInt(index: Character.Index) u32 {
            return @backingInt(index);
        }

        pub fn toId(index: Character.Index) Character.Id {
            return Id.list[@backingInt(index)];
        }

        /// We're using `index + 1` value as an "inst id"
        pub fn toInstId(index: Character.Index) u64 {
            return @backingInt(index) + 1;
        }

        pub fn fromInstId(inst_id: u64) ?Character.Index {
            if (inst_id == 0 or (inst_id - 1) >= Character.count) return null;
            return @fromBackingInt(@intCast(inst_id - 1));
        }

        pub const Optional = enum(u32) {
            none = std.math.maxInt(u32),
            _,

            pub fn wrap(index: Character.Index) Character.Index.Optional {
                assert(@backingInt(index) != @backingInt(Optional.none));
                return @fromBackingInt(@backingInt(index));
            }

            pub fn unwrap(optional: Character.Index.Optional) ?Character.Index {
                return switch (optional) {
                    .none => null,
                    _ => @fromBackingInt(@backingInt(optional)),
                };
            }
        };
    };

    pub const Id = enum(u32) {
        _,

        pub const default = Character.Id.fromInt(1504).?;

        pub const list: []const Id = list: {
            @setEvalBranchQuota(assets.tables.character.len);
            var result: [assets.tables.character.len]Id = undefined;
            for (&result, assets.tables.character) |*id, config|
                id.* = @fromBackingInt(config.id);

            const final = result;
            break :list &final;
        };

        pub fn fromInt(int: usize) ?Character.Id {
            // See `std.enums.fromInt` implementation
            for (Id.list) |id| if (@backingInt(id) == int)
                return id;

            return null;
        }

        pub fn toIndex(id: Character.Id) Character.Index {
            return @fromBackingInt(@intCast(mem.findScalar(Id, list, id).?));
        }
    };

    pub const Iterator = struct {
        inner: IntegerBitSet(Character.count).Iterator(.{}),

        pub fn next(it: *Character.Iterator) ?Character.Index {
            return @fromBackingInt(@intCast(it.inner.next() orelse return null));
        }
    };

    pub const Bits = packed struct(u32) {
        level: Level,
        break_level: BreakLevel,
        exp: Exp,
        _: u6 = 0,

        pub const init: Bits = .{
            .level = .init,
            .break_level = .init,
            .exp = .zero,
        };

        /// The highest level and break level `P_LevelUpTemplateTable` has a row for.
        pub const max: Bits = max: {
            @setEvalBranchQuota(assets.tables.level_up_template.len * 10);

            var level: u32 = 0;
            var break_level: u32 = 0;
            for (assets.tables.level_up_template) |template| {
                level = @max(level, template.level);
                break_level = @max(break_level, template.break_level);
            }

            break :max .{
                .level = @fromBackingInt(@intCast(level)),
                .break_level = @fromBackingInt(@intCast(break_level)),
                .exp = .zero,
            };
        };
    };

    pub const Level = enum(u7) {
        init = 1,
        _,

        pub fn toInt(l: Level) u7 {
            return @backingInt(l);
        }
    };

    pub const BreakLevel = enum(u3) {
        init = 0,
        _,

        pub fn toInt(bl: BreakLevel) u3 {
            return @backingInt(bl);
        }
    };

    pub const Exp = enum(u16) {
        zero = 0,
        _,

        pub fn toInt(e: Exp) u16 {
            return @backingInt(e);
        }
    };

    /// The player owns `copies` of every weapon in `assets.tables.motive`,
    /// a weapon's unique id is its position in that list.
    pub const MotiveUniqueId = enum(u64) {
        _,

        pub const copies = 2;
        pub const count = assets.tables.motive.len * copies;

        /// Asserts bounds.
        pub fn fromInstance(instance: usize) MotiveUniqueId {
            assert(instance < MotiveUniqueId.count);
            return @fromBackingInt(instance + 1);
        }

        pub fn fromInt(int: u64) ?MotiveUniqueId {
            if (int == 0 or int > MotiveUniqueId.count) return null;
            return @fromBackingInt(int);
        }

        pub fn toInt(uid: MotiveUniqueId) u64 {
            return @backingInt(uid);
        }

        pub fn config(uid: MotiveUniqueId) *const assets.tables.S_Motive {
            return &assets.tables.motive[uid.tableIndex()];
        }

        /// The weapon's row in `assets.tables.motive`.
        pub fn tableIndex(uid: MotiveUniqueId) usize {
            return @intCast((@backingInt(uid) - 1) / copies);
        }

        pub const Optional = enum(u64) {
            none = 0,
            _,

            pub fn wrap(uid: MotiveUniqueId) MotiveUniqueId.Optional {
                assert(@backingInt(uid) != 0);
                return @fromBackingInt(@backingInt(uid));
            }

            pub fn unwrap(o: Optional) ?MotiveUniqueId {
                return switch (o) {
                    .none => null,
                    else => @fromBackingInt(@backingInt(o)),
                };
            }
        };
    };

    pub const Snapshot = packed struct(u64) {
        hp: i32,
        permanent_liquid: i32,

        pub const Optional = enum(u64) {
            none = 0,
            _,

            pub fn wrap(snapshot: Character.Snapshot) Character.Snapshot.Optional {
                return @fromBackingInt(@backingInt(snapshot));
            }

            pub fn unwrap(o: Character.Snapshot.Optional) ?Character.Snapshot {
                return switch (o) {
                    .none => null,
                    _ => @as(Character.Snapshot, @fromBackingInt(@backingInt(o))),
                };
            }
        };
    };

    pub const Team = struct {
        pub const count = 15;
        pub const members_per_team = 4;

        members: [Character.Team.count]Members,
        bits: Character.Team.Bits,

        pub const init: Character.Team = .{
            .members = @splat(
                .{ .wrap(.default), .none, .none, .none },
            ),
            .bits = .{
                .current_team = @fromBackingInt(0),
                .using_slot = @fromBackingInt(0),
            },
        };

        pub const Members = [Character.Team.members_per_team]Character.Index.Optional;

        pub const Bits = packed struct(u8) {
            current_team: Character.Team.Index,
            using_slot: Character.Team.Slot,
            _: u2 = 0,
        };

        pub const Slot = enum(u2) {
            _,

            pub fn fromSlotId(id: u32) ?Character.Team.Slot {
                if (id == 0) return null;
                if ((id - 1) >= Character.Team.members_per_team) return null;

                return @fromBackingInt(@intCast(id - 1));
            }

            pub fn toSlotId(slot: Character.Team.Slot) u8 {
                return @as(u8, @backingInt(slot)) + 1;
            }
        };

        pub const Index = enum(u4) {
            _,

            pub fn fromTeamId(id: u32) ?Character.Team.Index {
                if (id == 0) return null;
                if ((id - 1) >= Character.Team.count) return null;

                return @fromBackingInt(@intCast(id - 1));
            }

            pub fn toTeamId(index: Character.Team.Index) u8 {
                return @backingInt(index) + 1;
            }
        };
    };
};

pub const Attr = enum(i32) {
    pub const count = @typeInfo(Attr).@"enum".field_names.len;

    maxhp = 101,
    atk = 102,
    def = 103,
    atk_critical_chance = 104,
    atk_critical_damage = 105,
    def_critical_damage_res = 106,
    blood_absorption_efficiency = 107,
    atk_heal_add_rate = 108,
    def_heal_add_rate = 109,
    atk_ignore_target_defence = 110,
    atk_body_part_break_add_rate = 113,
    atk_slash_spec = 121,
    atk_strike_spec = 122,
    atk_pierce_spec = 123,
    atk_fire_spec = 131,
    atk_ice_spec = 132,
    atk_thunder_spec = 133,
    atk_gravity_spec = 134,
    atk_radiation_spec = 135,
    atk_silver_spec = 136,
    atk_blackiron_spec = 137,
    atk_normal_spec = 138,
    atk_burst_spec = 141,
    atk_damage_add_rate = 301,
    atk_basic_attack_damage_add_rate = 331,
    atk_pursue_break_def = 1164,
    atk_pursue_catalyst = 1165,
    atk_abn_elem_master = 1171,
    atk_fire_damage_add_rate = 311,
    atk_ice_damage_add_rate = 313,
    atk_thunder_damage_add_rate = 315,
    atk_gravity_damage_add_rate = 317,
    atk_radiation_damage_add_rate = 319,
    atk_silver_damage_add_rate = 327,
    atk_black_iron_damage_add_rate = 329,
    liquid_absorb_rate = 1149,
    atk_abn_elem_accum_efficiency = 1185,
    atk_non_break_damage = 1207,
    atk_abn_critical_chance = 1204,
    atk_abn_critical_damage = 1205,
    horse_stamina_cost_modifier = 1220,

    hp = 1001,
    permanent_liquid = 1150,
};

/// Brings a state that was just read from a file written by an older version up to date.
/// Returns `true` if anything changed and the state has to be saved again.
pub fn migrate(gameplay: *Gameplay, header: *const Header) bool {
    gameplay.sanitize();

    if (header.state_version >= Header.version) {
        gameplay.restoreAbyssTeam();
        return false;
    }

    if (header.state_version < 2) {
        // Version 2: every character is at the maximum level.
        // The stored HP was measured against the old level, forget it.
        gameplay.character.bits = @splat(.max);
        gameplay.character.snapshots = @splat(.none);
    }

    if (header.state_version < 3) {
        // Version 3: every save point and teleport point is unlocked.
        gameplay.save_point_unlock = .full;
        gameplay.teleport_point_unlock = .full;
    }

    if (header.state_version < 4) {
        // Version 4: weapons and gear exist. Files older than that end before `equipment`.
        gameplay.equipDefaults();
    }
    if (header.state_version < 5) {
        gameplay.abyss = .init;
        gameplay.abyss_teams = @splat(@splat(.none));
    }

    if (header.state_version < 6) gameplay.catalysts = .init;

    gameplay.restoreAbyssTeam();
    return true;
}

pub const Header = extern struct {
    const version: u32 = 6;

    comptime {
        assert(std.meta.hasUniqueRepresentation(Header));
    }

    state_version: u32,

    /// Whether the file this header was read from was written by an older version.
    pub fn isOlder(header: *const Header) bool {
        return header.state_version < version;
    }
};

pub fn StateVector(comptime mut: Io.Mutability) type {
    // Increase this number when adding a new field.
    return [14]Io.Buffer(mut);
}

pub fn writableVector(gameplay: *Gameplay, header_buffer: *Header, bufs: *StateVector(.@"var")) void {
    // Increase this number when adding a new field.
    // Don't be tempted to make it a constant elsewhere,
    // as this has to be in-sync with the code below.
    comptime assert(bufs.len == 14);

    bufs[0].init(@ptrCast(header_buffer));
    bufs[1].init(@ptrCast(&gameplay.map));
    bufs[2].init(@ptrCast(&gameplay.character.unlocked));
    bufs[3].init(@ptrCast(&gameplay.character.bits));
    bufs[4].init(@ptrCast(&gameplay.character.motives));
    bufs[5].init(@ptrCast(&gameplay.character.snapshots));
    bufs[6].init(@ptrCast(&gameplay.character_team.members));
    bufs[7].init(@ptrCast(&gameplay.character_team.bits));
    bufs[8].init(@ptrCast(&gameplay.save_point_unlock));
    bufs[9].init(@ptrCast(&gameplay.teleport_point_unlock));
    bufs[10].init(@ptrCast(&gameplay.equipment.worn));
    bufs[11].init(@ptrCast(&gameplay.abyss));
    bufs[12].init(@ptrCast(&gameplay.abyss_teams));
    bufs[13].init(@ptrCast(&gameplay.catalysts));
}

pub fn readableVector(gameplay: *Gameplay, header_buffer: *Header, bufs: *StateVector(.@"const")) void {
    // Increase this number when adding a new field.
    // Don't be tempted to make it a constant elsewhere,
    // as this has to be in-sync with the code below.
    comptime assert(bufs.len == 14);

    header_buffer.* = .{ .state_version = Header.version };
    bufs[0].init(@ptrCast(header_buffer));
    bufs[1].init(@ptrCast(&gameplay.map));
    bufs[2].init(@ptrCast(&gameplay.character.unlocked));
    bufs[3].init(@ptrCast(&gameplay.character.bits));
    bufs[4].init(@ptrCast(&gameplay.character.motives));
    bufs[5].init(@ptrCast(&gameplay.character.snapshots));
    bufs[6].init(@ptrCast(&gameplay.character_team.members));
    bufs[7].init(@ptrCast(&gameplay.character_team.bits));
    bufs[8].init(@ptrCast(&gameplay.save_point_unlock));
    bufs[9].init(@ptrCast(&gameplay.teleport_point_unlock));
    bufs[10].init(@ptrCast(&gameplay.equipment.worn));
    bufs[11].init(@ptrCast(&gameplay.abyss));
    bufs[12].init(@ptrCast(&gameplay.abyss_teams));
    bufs[13].init(@ptrCast(&gameplay.catalysts));
}

test "version 4 saves gain empty Abyss progress without losing loadouts" {
    var gameplay: Gameplay = .init;
    const motives = gameplay.character.motives;
    const gear = gameplay.equipment.worn;
    const header: Header = .{ .state_version = 4 };
    try std.testing.expect(gameplay.migrate(&header));
    try std.testing.expectEqualDeep(motives, gameplay.character.motives);
    try std.testing.expectEqualDeep(gear, gameplay.equipment.worn);
    try std.testing.expectEqual(@as(u32, 0), gameplay.abyss.total(0));
}

test "save vectors preserve Abyss run, stars, claims, balances and room teams" {
    const t = std.testing;
    var original: Gameplay = .init;
    original.catalysts.normal[2][1][2] = 21501001;
    original.catalysts.abyss[Abyss.roomIndex(200102).?][2][0] = 21501002;
    original.abyss.layers[0] = .{ .star = 3, .passed = 1 };
    _ = try original.abyss.claim(1000);
    try original.abyss.enter(2000, 1, 1);
    try original.abyss.progress(2000, 1, 1, 42_000);
    original.abyss_teams[Abyss.roomIndex(200102).?][2] = .wrap(.fromInt(1));
    var header: Header = undefined;
    var output: StateVector(.@"const") = undefined;
    original.readableVector(&header, &output);
    var restored: Gameplay = .init;
    var read_header: Header = undefined;
    var input: StateVector(.@"var") = undefined;
    restored.writableVector(&read_header, &input);
    for (output, input) |src, dst| {
        try t.expectEqual(src.slice().len, dst.slice().len);
        @memcpy(dst.slice(), src.slice());
    }
    try t.expect(!restored.migrate(&read_header));
    try t.expectEqualDeep(original.abyss, restored.abyss);
    try t.expectEqualDeep(original.abyss_teams, restored.abyss_teams);
    try t.expectEqualDeep(original.catalysts, restored.catalysts);
    try t.expectEqual(@as(u32, 21501002), restored.activeTeamGems()[2][0]);
    try t.expectEqual(@as(u32, 200102), restored.transient.abyss_team_room);
    try t.expectEqual(@as(u8, 3), restored.activeTeamSlot().toSlotId());
    try t.expectEqual(@as(u64, 2), restored.activeTeamMembers()[2].unwrap().?.toInstId());
    try t.expectError(error.AlreadyClaimed, restored.abyss.claim(1000));
}

test "version 5 save vectors gain empty catalysts without losing previous progress" {
    const t = std.testing;
    var original: Gameplay = .init;
    original.abyss.layers[0] = .{ .star = 3, .passed = 1 };
    original.abyss_teams[0][0] = .wrap(.fromInt(1));
    var header: Header = undefined;
    var output: StateVector(.@"const") = undefined;
    original.readableVector(&header, &output);
    header.state_version = 5;
    var restored: Gameplay = .init;
    restored.catalysts.normal[0][0][0] = 21501001;
    var read_header: Header = undefined;
    var input: StateVector(.@"var") = undefined;
    restored.writableVector(&read_header, &input);
    // Version 5 ends after vector 12; the new field is appended to the file.
    for (output[0..13], input[0..13]) |src, dst| @memcpy(dst.slice(), src.slice());
    try t.expect(restored.migrate(&read_header));
    try t.expectEqualDeep(original.abyss, restored.abyss);
    try t.expectEqualDeep(original.abyss_teams, restored.abyss_teams);
    try t.expectEqualDeep(original.equipment, restored.equipment);
    try t.expectEqualDeep(Catalysts.init, restored.catalysts);
}

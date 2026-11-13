//! Weapon refine and psyche (constellation) levels for the sandbox.
//!
//! They come from `sandbox.zon` next to the server (see `--sandbox-file`), which
//! the scene server reads again at every login: edit the file, then log in again.
//! The levels are not saved; a missing or broken file falls back to `Settings`'
//! defaults, which are also what the file ships with.

const std = @import("std");

const roze = @import("roze.zig");
const Io = roze.Io;
const assets = roze.assets;
const Gameplay = roze.Gameplay;

const log = std.log.scoped(.@"roze::sandbox");

pub const default_path = "sandbox.zon";
pub const max_file_size = 64 * 1024;

/// Written to the settings path when no file is there, so there is one to edit.
pub const template: [:0]const u8 = @embedFile("sandbox_template.zon");

/// Creates the settings file from `template` if it does not exist yet.
pub fn ensureFile(io: *Io, path: [:0]const u8) void {
    if (Io.File.openBlocking(io, path)) |file| {
        file.closeBlocking(io);
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return log.warn("cannot open {s} ({t})", .{ path, err }),
    }
    const file = Io.File.createBlocking(io, path) catch |err|
        return log.warn("cannot create {s} ({t})", .{ path, err });
    defer file.closeBlocking(io);
    file.writeAllBlocking(io, template, 0) catch |err|
        return log.warn("cannot write {s} ({t})", .{ path, err });
    log.info("wrote the default {s}; edit it to change refine and psyche levels", .{path});
}

/// The format of `sandbox.zon`. Every field is optional.
pub const Settings = struct {
    defaults: Defaults = .{},
    /// Per-character psyche, overriding the default for its rarity.
    characters: []const Character = &.{},
    /// Per-weapon refine, overriding the default for its rarity.
    weapons: []const Weapon = &.{},

    pub const Defaults = struct {
        /// By `P_MotiveTable.Rare`: s = 5, a = 4, b = 3.
        weapon_refine: struct { s: u8 = 1, a: u8 = 5, b: u8 = 5 } = .{},
        /// By `P_CharacterTable.Rare_Type`: s = 5, a = 4.
        psyche: struct { s: u8 = 0, a: u8 = 6 } = .{},
    };

    pub const Character = struct { id: u32, psyche: u8 };
    pub const Weapon = struct { id: u32, refine: u8 };
};

/// The levels in effect, one per row of the sandbox tables.
pub const Levels = struct {
    /// Indexed like `assets.tables.character_growth`.
    psyche: [assets.tables.character_growth.len]u8,
    /// Indexed like `assets.tables.motive`.
    refine: [assets.tables.motive.len]u8,

    pub const default: Levels = default: {
        @setEvalBranchQuota(100_000);
        break :default resolve(&.{}, null);
    };

    pub fn refineOf(levels: *const Levels, uid: Gameplay.Character.MotiveUniqueId) u8 {
        return levels.refine[uid.tableIndex()];
    }

    pub fn psycheOf(levels: *const Levels, growth: *const assets.tables.S_CharacterGrowth) u8 {
        return levels.psyche[growthIndex(growth)];
    }

    /// The psyche points the character has activated.
    pub fn constellationPoints(levels: *const Levels, growth: *const assets.tables.S_CharacterGrowth) []const u32 {
        return growth.constellation_points[0..levels.psycheOf(growth)];
    }

    /// The substat contribution of the weapon at its refine.
    pub fn refineBonuses(levels: *const Levels, uid: Gameplay.Character.MotiveUniqueId) []const assets.tables.S_AttributeBonus {
        return uid.config().refine_bonuses[levels.refineOf(uid) - 1];
    }
};

fn growthIndex(growth: *const assets.tables.S_CharacterGrowth) usize {
    const table = assets.tables.character_growth;
    return @divExact(@intFromPtr(growth) - @intFromPtr(table.ptr), @sizeOf(assets.tables.S_CharacterGrowth));
}

/// Problems with the settings that were worked around.
pub const Problems = struct {
    count: usize = 0,

    fn report(problems: ?*Problems, comptime fmt: []const u8, args: anytype) void {
        const p = problems orelse return;
        p.count += 1;
        log.warn(fmt, args);
    }
};

/// Applies `settings` to every table row. Out-of-range levels are clamped and
/// unknown ids ignored; each is reported through `problems`.
pub fn resolve(settings: *const Settings, problems: ?*Problems) Levels {
    var levels: Levels = undefined;

    for (assets.tables.motive, &levels.refine) |*motive, *refine| {
        const by_rarity = settings.defaults.weapon_refine;
        refine.* = switch (motive.rarity) {
            5 => by_rarity.s,
            4 => by_rarity.a,
            else => by_rarity.b,
        };
    }
    for (settings.weapons) |weapon| {
        const i = for (assets.tables.motive, 0..) |motive, i| {
            if (motive.id == weapon.id) break i;
        } else {
            Problems.report(problems, "sandbox: unknown weapon id {d}; ignored", .{weapon.id});
            continue;
        };
        levels.refine[i] = weapon.refine;
    }
    for (assets.tables.motive, &levels.refine) |*motive, *refine| {
        const max: u8 = @intCast(motive.refine_bonuses.len);
        if (refine.* < 1 or refine.* > max) {
            Problems.report(problems, "sandbox: weapon {d} refine {d} is outside 1..{d}; clamped", .{ motive.id, refine.*, max });
            refine.* = std.math.clamp(refine.*, 1, max);
        }
    }

    for (assets.tables.character_growth, &levels.psyche) |*growth, *psyche| {
        const by_rarity = settings.defaults.psyche;
        psyche.* = if (growth.rarity == 5) by_rarity.s else by_rarity.a;
    }
    for (settings.characters) |character| {
        const i = for (assets.tables.character_growth, 0..) |growth, i| {
            if (growth.character_id == character.id) break i;
        } else {
            Problems.report(problems, "sandbox: unknown character id {d}; ignored", .{character.id});
            continue;
        };
        levels.psyche[i] = character.psyche;
    }
    for (assets.tables.character_growth, &levels.psyche) |*growth, *psyche| {
        const max: u8 = @intCast(growth.constellation_points.len);
        if (psyche.* > max) {
            Problems.report(problems, "sandbox: character {d} psyche {d} is above {d}; clamped", .{ growth.character_id, psyche.*, max });
            psyche.* = max;
        }
    }

    return levels;
}

/// Parses the text of a `sandbox.zon`. Errors are logged with `path`.
pub fn parse(source: [:0]const u8, path: []const u8, problems: ?*Problems) ?Levels {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const settings = std.zon.parse.fromSlice(Settings, .{
        .gpa = std.heap.page_allocator,
        .arena = arena.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.OutOfMemory => {
            log.err("{s}: out of memory", .{path});
            return null;
        },
        error.ParseZon => {
            if (problems) |p| {
                p.count += 1;
                log.err("{f}", .{diagnostics.fmt(path)});
            }
            return null;
        },
    };
    return resolve(&settings, problems);
}

/// Reads and applies `path`. Falls back to the defaults if it is missing or invalid.
pub fn load(io: *Io, path: [:0]const u8) Levels {
    const file = Io.File.openBlocking(io, path) catch |err| {
        switch (err) {
            error.FileNotFound => log.info("{s} not found; using default refine and psyche levels", .{path}),
            else => log.warn("cannot open {s} ({t}); using default refine and psyche levels", .{ path, err }),
        }
        return .default;
    };
    defer file.closeBlocking(io);

    // One read only: a short read means the whole file was returned. Reading again
    // at end of file is reported as an error by the Windows backend.
    var buffer: [max_file_size + 1]u8 = undefined;
    const len = file.readBlocking(io, buffer[0..max_file_size], 0) catch |err| {
        log.warn("cannot read {s} ({t}); using default refine and psyche levels", .{ path, err });
        return .default;
    };
    if (len == max_file_size) {
        log.warn("{s} is larger than {d} bytes; using default refine and psyche levels", .{ path, max_file_size });
        return .default;
    }
    buffer[len] = 0;

    var problems: Problems = .{};
    const levels = parse(buffer[0..len :0], path, &problems) orelse {
        log.err("{s} is invalid; using default refine and psyche levels", .{path});
        return .default;
    };
    log.info("applied {s} ({d} problem(s))", .{ path, problems.count });
    return levels;
}

test "defaults: S rank weapons R1, others R5; S rank characters P0, A rank P6" {
    const levels = Levels.default;
    for (assets.tables.motive, levels.refine) |motive, refine| {
        try std.testing.expectEqual(@as(u8, if (motive.rarity == 5) 1 else 5), refine);
    }
    for (assets.tables.character_growth, levels.psyche) |growth, psyche| {
        try std.testing.expectEqual(@as(u8, if (growth.rarity == 5) 0 else 6), psyche);
    }
}

test "the template matches the built-in defaults" {
    var problems: Problems = .{};
    const levels = parse(template, "sandbox_template.zon", &problems) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), problems.count);
    try std.testing.expectEqualDeep(Levels.default, levels);
}

test "overrides apply per id, and bad values are clamped or ignored" {
    const source =
        \\.{
        \\    .defaults = .{ .weapon_refine = .{ .s = 2 }, .psyche = .{ .a = 3 } },
        \\    .characters = .{ .{ .id = 1504, .psyche = 2 }, .{ .id = 1003, .psyche = 9 }, .{ .id = 42, .psyche = 1 } },
        \\    .weapons = .{ .{ .id = 12051001, .refine = 4 }, .{ .id = 12041001, .refine = 0 } },
        \\}
    ;
    const levels = resolveSource(source) orelse return error.TestUnexpectedResult;
    for (assets.tables.motive, levels.refine) |motive, refine| {
        const expected: u8 = switch (motive.id) {
            12051001 => 4,
            12041001 => 1, // 0 is clamped up to R1
            else => if (motive.rarity == 5) 2 else 5,
        };
        try std.testing.expectEqual(expected, refine);
    }
    for (assets.tables.character_growth, levels.psyche) |growth, psyche| {
        const expected: u8 = switch (growth.character_id) {
            1504 => 2,
            1003 => @intCast(growth.constellation_points.len), // 9 is clamped
            else => if (growth.rarity == 5) 0 else 3,
        };
        try std.testing.expectEqual(expected, psyche);
    }
}

test "a broken file is rejected" {
    try std.testing.expectEqual(@as(?Levels, null), parse(".{ .defaults = 3 }", "test", null));
    try std.testing.expectEqual(@as(?Levels, null), parse(".{ .weapons = .{ .{ .id = 1 } } }", "test", null));
}

fn resolveSource(source: [:0]const u8) ?Levels {
    return parse(source, "test", null);
}

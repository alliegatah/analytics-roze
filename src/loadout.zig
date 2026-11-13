//! The active team's build, written for Bloom's damage log.
//!
//! The scene server renders this after every command and rewrites
//! `<bloom dir>/loadout.json` when it changed. The dir server serves that
//! directory at `/bloom/`, and Bloom embeds the file in each battle log, the
//! counterpart of the ZZZ logger's `endbattle_<n>_loadout.json`.

const std = @import("std");

const roze = @import("roze.zig");
const Gameplay = roze.Gameplay;
const assets = roze.assets;

pub const file_name = "loadout.json";
/// The dir server refuses larger files (`bloom_file_max_size`).
pub const max_size = 12 * 1024;

pub fn write(w: *std.Io.Writer, gameplay: *const Gameplay) std.Io.Writer.Error!void {
    const members = gameplay.activeTeamMembers();
    const gems = gameplay.activeTeamGems();
    const room = gameplay.transient.abyss_team_room;
    const sandbox = &gameplay.transient.sandbox;

    try w.print(
        \\{{"format": "roze-loadout", "version": 1, "abyss_room": {d}, "using_slot": {d}, "team": [
    , .{ room, gameplay.activeTeamSlot().toSlotId() });
    var first = true;
    for (members, 0..) |optional, slot| {
        const index = optional.unwrap() orelse continue;
        const i = index.toInt();
        const id = @backingInt(index.toId());
        const bits = gameplay.character.bits[i];
        const growth = growthOf(id);

        try w.print("{s}\n  {{\"slot\": {d}, \"inst_id\": \"{d}\", \"character_id\": {d}, \"level\": {d}, \"break_level\": {d}, \"talent_nodes\": {d}, \"constellations\": {d}, ", .{
            if (first) "" else ",",
            slot + 1,
            index.toInstId(),
            id,
            bits.level.toInt(),
            bits.break_level.toInt(),
            if (growth) |g| g.talent_nodes.len else 0,
            if (growth) |g| sandbox.psycheOf(g) else 0,
        });
        first = false;

        try w.writeAll("\"weapon\": ");
        if (gameplay.character.motives[i].unwrap()) |uid| {
            const motive = uid.config();
            try w.print("{{\"id\": {d}, \"level\": {d}, \"break_level\": {d}, \"refine\": {d}}}", .{
                motive.id, motive.level, motive.break_level, sandbox.refineOf(uid),
            });
        } else try w.writeAll("null");

        try w.writeAll(", \"gear\": [");
        var first_piece = true;
        for (gameplay.equipment.worn[i]) |worn| {
            const uid = worn.unwrap() orelse continue;
            const piece = uid.config();
            try w.print("{s}{{\"id\": {d}, \"slot\": {d}, \"refine_levels\": ", .{ if (first_piece) "" else ", ", piece.id, piece.slot });
            try std.json.Stringify.value(piece.refine_levels, .{}, w);
            try w.writeByte('}');
            first_piece = false;
        }
        try w.writeAll("], \"catalysts\": [");
        var first_gem = true;
        for (gems[slot]) |gem| {
            if (gem == 0) continue;
            try w.print("{s}{d}", .{ if (first_gem) "" else ", ", gem });
            first_gem = false;
        }
        try w.writeAll("]}");
    }
    try w.writeAll("\n]}\n");
}

fn growthOf(character_id: u32) ?*const assets.tables.S_CharacterGrowth {
    for (assets.tables.character_growth) |*growth| {
        if (growth.character_id == character_id) return growth;
    }
    return null;
}

/// Renders the loadout into `buffer`; null if it does not fit.
pub fn render(buffer: []u8, gameplay: *const Gameplay) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    write(&w, gameplay) catch return null;
    return w.buffered();
}

test "the default team renders as valid JSON" {
    var gameplay: Gameplay = .init;
    var buffer: [max_size]u8 = undefined;
    const text = render(&buffer, &gameplay) orelse return error.TestUnexpectedResult;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    const team = parsed.value.object.get("team").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), team.len);
    const member = team[0].object;
    try std.testing.expectEqual(@as(i64, 1504), member.get("character_id").?.integer);
    try std.testing.expectEqual(Gameplay.Character.Id.fromInt(1504).?.toIndex().toInstId(), try std.fmt.parseInt(u64, member.get("inst_id").?.string, 10));
    try std.testing.expect(member.get("weapon").? == .object);
    try std.testing.expect(member.get("gear").?.array.items.len > 0);
}

test "a full team fits in one served file" {
    var gameplay: Gameplay = .init;
    const ids = [_]u32{ 1501, 1502, 1504, 1505 };
    for (ids, 0..) |id, slot| {
        const character = Gameplay.Character.Id.fromInt(id).?;
        gameplay.character_team.members[0][slot] = .wrap(character.toIndex());
    }
    var buffer: [max_size]u8 = undefined;
    const text = render(&buffer, &gameplay) orelse return error.TestUnexpectedResult;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 4), parsed.value.object.get("team").?.array.items.len);
}

test "the loadout reports the sandbox refine and psyche" {
    var gameplay: Gameplay = .init;
    const red_rose = Gameplay.Character.Id.fromInt(1504).?.toIndex();
    gameplay.character_team.members[0][0] = .wrap(red_rose);
    var settings: roze.sandbox.Settings = .{ .characters = &.{.{ .id = 1504, .psyche = 2 }} };
    const uid = gameplay.character.motives[red_rose.toInt()].unwrap().?;
    const weapons = [_]roze.sandbox.Settings.Weapon{.{ .id = uid.config().id, .refine = 3 }};
    settings.weapons = &weapons;
    gameplay.transient.sandbox = roze.sandbox.resolve(&settings, null);

    var buffer: [max_size]u8 = undefined;
    const text = render(&buffer, &gameplay) orelse return error.TestUnexpectedResult;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    const member = parsed.value.object.get("team").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 2), member.get("constellations").?.integer);
    try std.testing.expectEqual(@as(i64, 3), member.get("weapon").?.object.get("refine").?.integer);
}

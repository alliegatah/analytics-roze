//! Reactor assignments belong to a team, including each separate Abyss side.
const Catalysts = @This();
const std = @import("std");
const roze = @import("roze.zig");
const Gameplay = roze.Gameplay;
const p = roze.protobuf.gen;

pub const slots_per_member = 3;
pub const Team = [Gameplay.Character.Team.members_per_team][slots_per_member]u32;
pub const empty: Team = @splat(@splat(0));
normal: [Gameplay.Character.Team.count]Team,
abyss: [Gameplay.Abyss.room_count]Team,
pub const init: Catalysts = .{ .normal = @splat(empty), .abyss = @splat(empty) };

pub const Parsed = struct { members: Gameplay.Character.Team.Members, gems: Team };
pub const Error = roze.protobuf.DecodeError || error{InvalidTeam};

/// The client sends complete teams, including empty character and gem slots.
/// Ignore client-provided gem_state; all 17 CBT2 regular catalysts have no element limits.
pub fn readTeam(gameplay: *const Gameplay, data: p.TeamData.Decoded) Error!Parsed {
    var team = data;
    var result: Parsed = .{ .members = @splat(.none), .gems = empty };
    var member_slots: [4]bool = @splat(false);
    var characters: Gameplay.Character.Set = .empty;
    var gems: std.bit_set.IntegerBitSet(roze.assets.tables.catalyst.len) = .empty;
    var total_cost: u32 = 0;
    while (try team.member_data.next()) |data_in| {
        var member = data_in;
        const slot = Gameplay.Character.Team.Slot.fromSlotId(member.member_slot_id) orelse return error.InvalidTeam;
        const si = @backingInt(slot);
        if (member_slots[si]) return error.InvalidTeam;
        member_slots[si] = true;
        if (member.inst_id != 0) {
            const ci = Gameplay.Character.Index.fromInstId(member.inst_id) orelse return error.InvalidTeam;
            if (characters.isSet(ci.toInt()) or !gameplay.character.unlocked.isSet(ci.toInt()) or
                (member.character_id != 0 and member.character_id != @backingInt(ci.toId()))) return error.InvalidTeam;
            characters.set(ci.toInt());
            result.members[si] = .wrap(ci);
        } else if (member.character_id != 0) return error.InvalidTeam;
        var gem_slots: [slots_per_member]bool = @splat(false);
        var gem_count: u5 = 0;
        while (try member.gem_slots.next()) |gem| {
            if (gem.gem_slot_id == 0 or gem.gem_slot_id > slots_per_member) return error.InvalidTeam;
            const gi = gem.gem_slot_id - 1;
            if (gem_slots[gi]) return error.InvalidTeam;
            gem_slots[gi] = true;
            if (gem.gem_itemid == 0) continue;
            if (member.inst_id == 0) return error.InvalidTeam;
            const index = std.mem.indexOfScalar(u32, roze.assets.tables.catalyst, gem.gem_itemid) orelse return error.InvalidTeam;
            if (gems.isSet(index)) return error.InvalidTeam;
            gems.set(index);
            result.gems[si][gi] = gem.gem_itemid;
            // P_GemGlobalConfig.GemCost is the incremental cost: 1, 2, 4.
            total_cost += @as(u32, 1) << gem_count;
            gem_count += 1;
        }
    }
    if (total_cost > 14) return error.InvalidTeam;
    return result;
}

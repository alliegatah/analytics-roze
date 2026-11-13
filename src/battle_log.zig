//! Summaries of client battle log reports (CS_BATTLE_LOG_REPORT); see
//! commands/battle_verify.zig.
//!
//! In client 0.10.82.1 these reports carry skill casts, buffs, affix triggers,
//! deaths and attack hits (attacker, attack info, targets) but no attribute
//! deltas, so they contain no damage numbers. Damage is logged by Bloom.

const std = @import("std");
const roze = @import("roze.zig");
const p = roze.protobuf.gen;

pub const SegmentCounts = struct {
    attack_hits: u32 = 0,
    skill_casts: u32 = 0,
    buffs: u32 = 0,
    affixes: u32 = 0,
    affix_activations: u32 = 0,
    deaths: u32 = 0,
    other: u32 = 0,

    pub fn add(c: *SegmentCounts, event: *const p.PBBattleEvent.Decoded) void {
        const data = event.event_data orelse {
            c.other += 1;
            return;
        };
        switch (data) {
            .attack_hit => c.attack_hits += 1,
            .skill_cast => c.skill_casts += 1,
            .add_buff => c.buffs += 1,
            .add_affix => c.affixes += 1,
            .activate_affix => c.affix_activations += 1,
            .pawn_death => c.deaths += 1,
        }
    }
};

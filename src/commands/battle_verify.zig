//! Battle verification ("battle log") reports.
//!
//! When reporting is enabled, the client uploads its battle event log in
//! segments (CS_BATTLE_LOG_REPORT). Roze acknowledges each segment and logs a
//! one-line summary; see battle_log.zig for what the reports contain.

const std = @import("std");
const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const p = protobuf.gen;
const Scope = roze.Scope;

const battle_log = @import("../battle_log.zig");
const log = std.log.scoped(.@"roze::battle_log");

pub fn CS_BATTLE_VERIFY_SWITCH_QUERY_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_BATTLE_VERIFY_SWITCH_QUERY_RSP, @as(
        p.SC_Battle_Verify_Switch_Query_Rsp,
        .{ .report_enabled = true },
    ));
}

pub fn CS_BATTLE_LOG_REPORT(scope: *Scope) Scope.Error!void {
    const req = try scope.command.take(p.CS_Battle_Log_Report.Decoded);

    var counts: battle_log.SegmentCounts = .{};
    var events = req.events;
    while (try events.next()) |event| counts.add(&event);

    log.debug(
        "battle {d} segment {d}: frames {d}-{d}: {d} hits, {d} casts, {d} buffs, {d} affix activations, {d} deaths",
        .{
            req.battle_uid,     req.segment_id,     req.start_frame, req.end_frame,
            counts.attack_hits, counts.skill_casts, counts.buffs,    counts.affix_activations,
            counts.deaths,
        },
    );

    try scope.sink.send(.SC_BATTLE_LOG_REPORT, @as(p.SC_Battle_Log_Report, .{
        .ret = 0,
        .battle_uid = req.battle_uid,
        .segment_id = req.segment_id,
    }));
}

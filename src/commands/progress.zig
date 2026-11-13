const std = @import("std");

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

const log = std.log.scoped(.@"roze::commands::progress");

/// How many arguments of a reported event are echoed back.
const args_max = 16;

/// The client reports events that count towards task, guide and unlock progress
/// (exposing an NPC is one). We don't track any of that, the report is acknowledged as is.
pub fn CS_PROGRESS_EVENT_TRIGGER(scope: *Scope) Scope.Error!void {
    var request = try scope.command.take(protobuf.gen.CS_Progress_Event_Trigger.Decoded);

    var args_buf: [args_max][]const u8 = undefined;
    var count: usize = 0;
    while (try request.args.next()) |arg| {
        if (count == args_buf.len) break;
        args_buf[count] = arg;
        count += 1;
    }

    log.debug("event {d} with {d} argument(s) reported", .{ request.event, count });

    try scope.sink.send(.SC_PROGRESS_EVENT_TRIGGER, @as(
        protobuf.gen.SC_Progress_Event_Trigger,
        .{ .event = request.event, .args = args_buf[0..count] },
    ));
}

//! The sandbox's City Records are complete, like its account and character progression.
const roze = @import("../roze.zig");
const p = roze.protobuf.gen;
const tables = roze.assets.tables;

const stages: [tables.newbie_stage.len]p.NewbieStageInfo = data: {
    var out: [tables.newbie_stage.len]p.NewbieStageInfo = undefined;
    for (&out, tables.newbie_stage) |*entry, id| entry.* = .{ .stage_id = id, .is_unlocked = true, .is_reward = true };
    break :data out;
};
const objectives: [tables.newbie.len]p.NewbieInfo = data: {
    var out: [tables.newbie.len]p.NewbieInfo = undefined;
    for (&out, tables.newbie) |*entry, config| entry.* = .{ .newbie_id = config.id, .progress = config.need_count, .is_finish = true, .is_reward = true };
    break :data out;
};

pub fn CS_NEWBIE_GET_DATA_REQUEST(scope: *roze.Scope) roze.Scope.Error!void {
    _ = try scope.command.take(p.CS_Newbie_Get_Data_Request.Decoded);
    try scope.sink.send(.SC_NEWBIE_GET_DATA_RESPONSE, @as(p.SC_Newbie_Get_Data_Response, .{ .stages = &stages, .newbies = &objectives }));
}

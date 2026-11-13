const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const assets = roze.assets;
const Gameplay = roze.Gameplay;
const Scope = roze.Scope;

/// Every talent node of every playable character, at the highest level the node has.
/// Extra levels (granted by constellations and gear enchants) are not accounted for.
const talent_infos: []const protobuf.gen.TalentInfo = talent_infos: {
    @setEvalBranchQuota(100_000);

    const growth_table = assets.tables.character_growth;
    var result: [growth_table.len]protobuf.gen.TalentInfo = undefined;

    for (&result, growth_table) |*info, growth| {
        var nodes: [growth.talent_nodes.len]protobuf.gen.TalentNodeInfo = undefined;
        for (&nodes, growth.talent_nodes) |*node, config|
            node.* = .{ .node_id = config.id, .level = config.level };

        const final_nodes = nodes;
        info.* = .{
            .inst_id = Gameplay.Character.Id.fromInt(growth.character_id).?.toIndex().toInstId(),
            .nodes = &final_nodes,
        };
    }

    const final = result;
    break :talent_infos &final;
};

pub fn CS_TALENT_QUERY(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_TALENT_QUERY, @as(
        protobuf.gen.SC_Talent_Query,
        .{ .infos = talent_infos },
    ));
}

/// Everything is at its maximum already: the request succeeds without changing anything.
pub fn CS_TALENT_LEVEL_UP(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Talent_Level_Up.Decoded);

    const node: protobuf.gen.TalentNodeInfo = node: for (talent_infos) |info| {
        if (info.inst_id != request.inst_id) continue;
        for (info.nodes) |node| if (node.node_id == request.node_id) break :node node;
    } else return try scope.sink.send(.SC_TALENT_LEVEL_UP, @as(
        protobuf.gen.SC_Talent_Level_Up,
        .{ .result = -1 },
    ));

    try scope.sink.send(.SC_TALENT_LEVEL_UP, @as(protobuf.gen.SC_Talent_Level_Up, .{
        .inst_id = request.inst_id,
        .node_info = node,
    }));
}

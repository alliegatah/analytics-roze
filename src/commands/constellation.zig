const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const assets = roze.assets;
const Gameplay = roze.Gameplay;
const Scope = roze.Scope;

const ElemList = [assets.tables.character_growth.len]protobuf.gen.ConstellationElem;

/// Psyche levels from `sandbox.zon` (`gameplay.transient.sandbox`).
fn constellationElems(gameplay: *const Gameplay, result: *ElemList) []const protobuf.gen.ConstellationElem {
    for (result, assets.tables.character_growth) |*elem, *growth| elem.* = .{
        .unique_id = Gameplay.Character.Id.fromInt(growth.character_id).?.toIndex().toInstId(),
        .points = gameplay.transient.sandbox.constellationPoints(growth),
    };
    return result;
}

pub fn CS_CONSTELLATION_QUERY_REQ(scope: *Scope) Scope.Error!void {
    var elems: ElemList = undefined;
    try scope.sink.send(.SC_CONSTELLATION_QUERY_RSP, @as(
        protobuf.gen.SC_Constellation_Query_Rsp,
        .{ .constellation_elems = constellationElems(scope.gameplay, &elems) },
    ));
}

/// Psyche is set in `sandbox.zon`, so activation requests answer with the
/// configured level unchanged.
pub fn CS_CONSTELLATION_ACTIVE_REQ(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Constellation_Active_Req.Decoded);

    var elems: ElemList = undefined;
    const elem: protobuf.gen.ConstellationElem = for (constellationElems(scope.gameplay, &elems)) |elem| {
        if (elem.unique_id == request.unique_id) break elem;
    } else return try scope.sink.send(.SC_CONSTELLATION_ACTIVE_RSP, @as(
        protobuf.gen.SC_Constellation_Active_Rsp,
        .{ .result = -1 },
    ));

    try scope.sink.send(.SC_CONSTELLATION_ACTIVE_RSP, @as(
        protobuf.gen.SC_Constellation_Active_Rsp,
        .{ .constellation_elem = elem },
    ));
}

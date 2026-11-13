const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

/// The client asks for the collectibles of each map block it loads.
/// We don't have the collection tables, so there's nothing to collect anywhere.
pub fn CS_COLLECTION_GET_LIST(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_COLLECTION_GET_LIST, @as(
        protobuf.gen.SC_Collection_Get_List,
        .init,
    ));
}

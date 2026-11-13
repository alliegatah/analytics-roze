const roze = @import("../roze.zig");
const assets = roze.assets;
const protobuf = roze.protobuf;
const Gameplay = roze.Gameplay;
const Scope = roze.Scope;

pub fn CS_OUTSIDE_ATTRIB_QUERY(scope: *Scope) Scope.Error!void {
    const packers = protobuf.packers;

    var buffer: packers.Buffer(
        protobuf.packers.CharacterAttribDataBuffer,
        Gameplay.Character.count,
    ) = undefined;

    var list = buffer.toList();

    var it = scope.gameplay.character.iterator();
    while (it.next()) |index| packers.packCharacterAttribData(
        scope.asset_index,
        &list,
        scope.gameplay,
        index,
    );

    const response: protobuf.gen.SC_Outside_Attrib_Query = .{
        .data = list.items(.data),
    };

    try scope.sink.send(.SC_OUTSIDE_ATTRIB_QUERY, response);
}

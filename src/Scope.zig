const Scope = @This();
const roze = @import("roze.zig");
const Io = roze.Io;

time: Io.Timespec,
sink: roze.net.Sink,
command: roze.commands.Buffer,
gameplay: *roze.Gameplay,
asset_index: *const roze.assets.Index,
level: Level,
store: Store,

pub const Error = roze.net.Sink.Error ||
    roze.commands.Buffer.Error;

/// Tells the client what the attributes of the character are now.
pub fn notifyCharacterAttrib(scope: *Scope, index: roze.Gameplay.Character.Index) Error!void {
    const packers = roze.protobuf.packers;

    var buffer: packers.Buffer(packers.CharacterAttribDataBuffer, 1) = undefined;
    var list = buffer.toList();
    packers.packCharacterAttribData(scope.asset_index, &list, scope.gameplay, index);

    try scope.sink.send(.SC_OUTSIDE_ATTRIB_NTF, @as(
        roze.protobuf.gen.SC_Outside_Attrib_Ntf,
        .{ .data = list.items(.data)[0] },
    ));
}

/// Tells the client that the character's data (the weapon it holds, for one) has changed.
pub fn notifyCharacterUpdate(scope: *Scope, index: roze.Gameplay.Character.Index) Error!void {
    try scope.sink.send(.SC_NTF_CHARACTER_UPDATE, @as(
        roze.protobuf.gen.SC_Character_Update_Ntf,
        .{ .characters = &.{roze.protobuf.packers.packCharacterData(scope.gameplay, index)} },
    ));
}

/// Account-wide levels reported to the client. Set from the command line.
pub const Level = struct {
    team: u32,
    world: u32,

    /// The highest the game defines, as everything else here is maxed out too.
    pub const default: Level = .{
        .team = roze.assets.tables.level_cap.team_level,
        .world = roze.assets.tables.level_cap.world_level,
    };
};

pub const Store = struct {
    role_id: u64,
    gameplay_state_save_requested: bool,

    pub fn requestGameplayStateSave(store: *Store) void {
        store.gameplay_state_save_requested = true;
    }
};

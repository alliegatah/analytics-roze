const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Gameplay = roze.Gameplay;
const Scope = roze.Scope;

pub fn CS_REQ_CHARACTER_LIST(scope: *Scope) Scope.Error!void {
    var characters_buf: [Gameplay.Character.count]protobuf.gen.CharacterData = undefined;
    var count: u32 = 0;

    var it = scope.gameplay.character.iterator();
    while (it.next()) |index| {
        characters_buf[count] = protobuf.packers.packCharacterData(scope.gameplay, index);
        count += 1;
    }

    try scope.sink.send(.SC_RES_CHARACTER_LIST, @as(protobuf.gen.SC_Character_List_Rsp, .{
        .list = characters_buf[0..count],
    }));
}

pub fn CS_CHARACTER_HEAL_REQ(scope: *Scope) Scope.Error!void {
    const character = &scope.gameplay.character;
    const active_characters = scope.gameplay.activeTeamMembers();

    for (active_characters) |character_index_maybe| {
        const character_index = character_index_maybe.unwrap() orelse continue;

        if (character.snapshots[@backingInt(character_index)].unwrap()) |snapshot_prev| {
            character.snapshots[@backingInt(character_index)] = .wrap(.{
                .hp = roze.stats.maxHp(scope.asset_index, scope.gameplay, character_index),
                .permanent_liquid = snapshot_prev.permanent_liquid,
            });
        }

        // why this is not a repeated field? lol.
        try scope.notifyCharacterAttrib(character_index);
    }

    try scope.sink.send(.SC_CHARACTER_HEAL_RES, @as(protobuf.gen.SC_Character_Heal_Res, .init));

    errdefer comptime unreachable; // Ensure that it's safe to request save.
    scope.store.requestGameplayStateSave();
}

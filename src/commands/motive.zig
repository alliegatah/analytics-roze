//! Weapons ("motives"). The player owns every weapon, fully upgraded, so the only thing
//! that can change is which character holds which one.

const std = @import("std");

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const packers = roze.protobuf.packers;
const assets = roze.assets;
const Gameplay = roze.Gameplay;
const Scope = roze.Scope;
const MotiveUniqueId = Gameplay.Character.MotiveUniqueId;

const log = std.log.scoped(.@"roze::commands::motive");

pub fn CS_MOTIVE_QUERY(scope: *Scope) Scope.Error!void {
    var elems: [MotiveUniqueId.count]protobuf.gen.CSMotiveElem = undefined;
    for (&elems, 0..) |*elem, instance| {
        elem.* = packers.packMotiveElem(scope.gameplay, .fromInstance(instance), scope.time.toMilliseconds());
    }

    try scope.sink.send(.SC_MOTIVE_QUERY, @as(
        protobuf.gen.SC_Motive_Query,
        .{ .motive_elems = &elems },
    ));
}

pub fn CS_MOTIVE_EQUIP(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Motive_Equip.Decoded);
    const character = &scope.gameplay.character;

    const uid = MotiveUniqueId.fromInt(request.motive_uniq_id) orelse {
        log.debug("weapon with unique id {d} doesn't exist", .{request.motive_uniq_id});
        return try scope.sink.send(.SC_MOTIVE_EQUIP, @as(protobuf.gen.SC_Motive_Equip, .{ .result = -1 }));
    };

    const target = unlockedCharacter(scope, request.inst_id) orelse {
        log.debug("invalid character inst id: {d}", .{request.inst_id});
        return try scope.sink.send(.SC_MOTIVE_EQUIP, @as(protobuf.gen.SC_Motive_Equip, .{ .result = -1 }));
    };

    if (uid.config().identity_type != assets.tables.character[target.toInt()].identity_type) {
        log.debug("weapon {d} doesn't fit character {d}", .{ uid.config().id, @backingInt(target.toId()) });
        return try scope.sink.send(.SC_MOTIVE_EQUIP, @as(protobuf.gen.SC_Motive_Equip, .{ .result = -1 }));
    }

    const previous_owner = character.motiveOwner(uid);
    if (previous_owner) |owner| character.motives[owner.toInt()] = .none;
    character.motives[target.toInt()] = .wrap(uid);

    try scope.sink.send(.SC_MOTIVE_EQUIP, @as(protobuf.gen.SC_Motive_Equip, .{
        .motive_uniq_id = request.motive_uniq_id,
        .inst_id = request.inst_id,
    }));

    if (previous_owner) |owner| if (owner != target) {
        try scope.notifyCharacterUpdate(owner);
        try scope.notifyCharacterAttrib(owner);
    };
    try scope.notifyCharacterUpdate(target);
    try scope.notifyCharacterAttrib(target);

    errdefer comptime unreachable; // Ensure that it's safe to request save.
    scope.store.requestGameplayStateSave();
}

pub fn CS_MOTIVE_UNEQUIP(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Motive_Unequip.Decoded);
    const character = &scope.gameplay.character;

    const target = unlockedCharacter(scope, request.inst_id) orelse {
        log.debug("invalid character inst id: {d}", .{request.inst_id});
        return try scope.sink.send(.SC_MOTIVE_UNEQUIP, @as(protobuf.gen.SC_Motive_Unequip, .{ .result = -1 }));
    };

    if (@backingInt(character.motives[target.toInt()]) != request.motive_uniq_id or request.motive_uniq_id == 0) {
        log.debug("character {d} doesn't hold weapon {d}", .{ request.inst_id, request.motive_uniq_id });
        return try scope.sink.send(.SC_MOTIVE_UNEQUIP, @as(protobuf.gen.SC_Motive_Unequip, .{ .result = -1 }));
    }

    character.motives[target.toInt()] = .none;

    try scope.sink.send(.SC_MOTIVE_UNEQUIP, @as(protobuf.gen.SC_Motive_Unequip, .{
        .motive_uniq_id = request.motive_uniq_id,
        .inst_id = request.inst_id,
    }));

    try scope.notifyCharacterUpdate(target);
    try scope.notifyCharacterAttrib(target);

    errdefer comptime unreachable; // Ensure that it's safe to request save.
    scope.store.requestGameplayStateSave();
}

/// The lock only guards against using the weapon as upgrade material, which can't happen here.
pub fn CS_MOTIVE_LOCK(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Motive_Lock.Decoded);

    try scope.sink.send(.SC_MOTIVE_LOCK, @as(protobuf.gen.SC_Motive_Lock, .{
        .motive_uniq_id = request.motive_uniq_id,
        .lock_state = request.lock_state,
    }));
}

// Everything is at its maximum already: the upgrade requests succeed without changing anything.

pub fn CS_MOTIVE_LEVEUP(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Motive_LevelUp.Decoded);
    const uid = MotiveUniqueId.fromInt(request.motive_uniq_id) orelse
        return try scope.sink.send(.SC_MOTIVE_LEVEUP, @as(protobuf.gen.SC_Motive_LevelUp, .{ .result = -1 }));

    try scope.sink.send(.SC_MOTIVE_LEVEUP, @as(protobuf.gen.SC_Motive_LevelUp, .{
        .motive_uniq_id = request.motive_uniq_id,
        .old_level = uid.config().level,
        .new_level = uid.config().level,
    }));
}

pub fn CS_MOTIVE_BREAK(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Motive_Break.Decoded);
    const uid = MotiveUniqueId.fromInt(request.motive_uniq_id) orelse
        return try scope.sink.send(.SC_MOTIVE_BREAK, @as(protobuf.gen.SC_Motive_Break, .{ .result = -1 }));

    try scope.sink.send(.SC_MOTIVE_BREAK, @as(protobuf.gen.SC_Motive_Break, .{
        .motive_uniq_id = request.motive_uniq_id,
        .old_break_level = uid.config().break_level,
        .new_break_level = uid.config().break_level,
    }));
}

pub fn CS_MOTIVE_REFINEUP(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Motive_RefineUp.Decoded);
    const uid = MotiveUniqueId.fromInt(request.motive_uniq_id) orelse
        return try scope.sink.send(.SC_MOTIVE_REFINEUP, @as(protobuf.gen.SC_Motive_RefineUp, .{ .result = -1 }));

    try scope.sink.send(.SC_MOTIVE_REFINEUP, @as(protobuf.gen.SC_Motive_RefineUp, .{
        .motive_uniq_id = request.motive_uniq_id,
        .old_refine = scope.gameplay.transient.sandbox.refineOf(uid),
        .current_refine = scope.gameplay.transient.sandbox.refineOf(uid),
    }));
}

fn unlockedCharacter(scope: *Scope, inst_id: u64) ?Gameplay.Character.Index {
    const index = Gameplay.Character.Index.fromInstId(inst_id) orelse return null;
    if (!scope.gameplay.character.unlocked.isSet(index.toInt())) return null;
    return index;
}

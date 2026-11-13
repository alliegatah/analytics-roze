//! Gear. The player owns every piece (see `Gameplay.Equipment`), fully refined, so the only
//! thing that can change is which character wears which one.

const std = @import("std");

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const packers = roze.protobuf.packers;
const Gameplay = roze.Gameplay;
const Scope = roze.Scope;
const UniqueId = Gameplay.Equipment.UniqueId;

const log = std.log.scoped(.@"roze::commands::equipment");

/// The client asks for the list page by page until it has seen `page_max` of them.
const page_size = 200;
const page_count = std.math.divCeil(usize, UniqueId.count, page_size) catch unreachable;

pub fn CS_EQUIPMENT_DATA(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Equipment_Data.Decoded);

    // Pages are numbered from 1.
    const page: usize = @min(@max(request.page, 1), page_count);
    const first = (page - 1) * page_size;
    const last = @min(first + page_size, UniqueId.count);

    var data_buf: [page_size]protobuf.gen.CmdEquipmentData = undefined;
    const data = data_buf[0 .. last - first];
    for (data, first..) |*equipment, instance|
        equipment.* = packers.packEquipmentData(scope.gameplay, .fromInstance(instance));

    try scope.sink.send(.SC_EQUIPMENT_DATA, @as(protobuf.gen.SC_Equipment_Data, .{
        .page_cur = @intCast(page),
        .page_max = @intCast(page_count),
        .data = data,
    }));
}

pub fn CS_EQUIPMENT_WEAR(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Equipment_Wear.Decoded);
    const equipment = &scope.gameplay.equipment;

    const uid = UniqueId.fromInt(request.uid) orelse {
        log.debug("gear with unique id {d} doesn't exist", .{request.uid});
        return try scope.sink.send(.SC_EQUIPMENT_WEAR, @as(protobuf.gen.SC_Equipment_Wear, .{ .result = -1 }));
    };

    const slot = uid.slot() orelse {
        log.debug("gear {d} goes into an unknown slot", .{uid.config().id});
        return try scope.sink.send(.SC_EQUIPMENT_WEAR, @as(protobuf.gen.SC_Equipment_Wear, .{ .result = -1 }));
    };

    const target = unlockedCharacter(scope, request.owner_uid) orelse {
        log.debug("invalid character inst id: {d}", .{request.owner_uid});
        return try scope.sink.send(.SC_EQUIPMENT_WEAR, @as(protobuf.gen.SC_Equipment_Wear, .{ .result = -1 }));
    };

    // If somebody else wears the piece, the two characters swap.
    const previous_owner = equipment.owner(uid);
    const replaced = equipment.worn[target.toInt()][slot];

    if (previous_owner) |owner| equipment.worn[owner.toInt()][slot] = replaced;
    equipment.worn[target.toInt()][slot] = .wrap(uid);

    try scope.sink.send(.SC_EQUIPMENT_WEAR, @as(protobuf.gen.SC_Equipment_Wear, .{
        .uid = request.uid,
        .owner_uid = request.owner_uid,
        .other_uid = @backingInt(replaced),
        .other_owner_uid = if (previous_owner) |owner|
            (if (owner != target and replaced != .none) owner.toInstId() else 0)
        else
            0,
    }));

    if (previous_owner) |owner| if (owner != target) try scope.notifyCharacterAttrib(owner);
    try scope.notifyCharacterAttrib(target);

    errdefer comptime unreachable; // Ensure that it's safe to request save.
    scope.store.requestGameplayStateSave();
}

pub fn CS_EQUIPMENT_UNWEAR(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Equipment_UnWear.Decoded);
    const equipment = &scope.gameplay.equipment;

    const uid = UniqueId.fromInt(request.uid) orelse {
        log.debug("gear with unique id {d} doesn't exist", .{request.uid});
        return try scope.sink.send(.SC_EQUIPMENT_UNWEAR, @as(protobuf.gen.SC_Equipment_UnWear, .{ .result = -1 }));
    };

    const owner = equipment.owner(uid) orelse {
        log.debug("nobody wears gear with unique id {d}", .{request.uid});
        return try scope.sink.send(.SC_EQUIPMENT_UNWEAR, @as(protobuf.gen.SC_Equipment_UnWear, .{ .result = -1 }));
    };

    equipment.worn[owner.toInt()][uid.slot().?] = .none;

    try scope.sink.send(.SC_EQUIPMENT_UNWEAR, @as(protobuf.gen.SC_Equipment_UnWear, .{
        .uid = request.uid,
        .owner_uid = owner.toInstId(),
    }));

    try scope.notifyCharacterAttrib(owner);

    errdefer comptime unreachable; // Ensure that it's safe to request save.
    scope.store.requestGameplayStateSave();
}

/// The lock only guards against decomposing the piece, which can't happen here.
pub fn CS_EQUIPMENT_LOCK(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Equipment_Lock.Decoded);

    try scope.sink.send(.SC_EQUIPMENT_LOCK, @as(protobuf.gen.SC_Equipment_Lock, .{
        .uid = request.uid,
        .lock_state = request.lock_state,
    }));
}

fn unlockedCharacter(scope: *Scope, inst_id: u64) ?Gameplay.Character.Index {
    const index = Gameplay.Character.Index.fromInstId(inst_id) orelse return null;
    if (!scope.gameplay.character.unlocked.isSet(index.toInt())) return null;
    return index;
}

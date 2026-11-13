//! Thought Experiment progression. Fixed-size storage follows the embedded CBT2 tables.
const std = @import("std");
const tables = @import("assets/tables.zig");

pub const mode_count = tables.abyss.len;
pub const layer_count = countLayers();
pub const room_count = countRooms();
pub const rooms_max = 3;
pub const item_count = tables.abyss_reward_item.len;

fn countLayers() usize {
    var n: usize = 0;
    for (tables.abyss) |mode| n += mode.layers.len;
    return n;
}
fn countRooms() usize {
    var n: usize = 0;
    for (tables.abyss) |mode| for (mode.layers) |layer| {
        n += layer.rooms.len;
    };
    return n;
}

pub const Failure = error{ ModeNotFound, LayerNotFound, LayerLocked, RoomNotFound, RoomLocked, NotStarted, NotFinished, Invalid, AlreadyClaimed };
pub fn result(err: Failure) i32 {
    return switch (err) {
        error.ModeNotFound => 4400,
        error.LayerLocked => 4401,
        error.LayerNotFound => 4402,
        error.RoomNotFound => 4404,
        error.RoomLocked => 4405,
        error.AlreadyClaimed => 4406,
        error.NotStarted => 4408,
        error.NotFinished => 4409,
        error.Invalid => 207,
    };
}

pub const Location = struct {
    mode: usize,
    layer: usize,
    flat: usize,
    config: *const tables.S_Abyss.Layer,
};
pub fn modeIndex(id: u32) ?usize {
    for (tables.abyss, 0..) |mode, i| if (mode.id == id) return i;
    return null;
}
pub fn locate(id: u32, layer_index: u32) Failure!Location {
    const mi = modeIndex(id) orelse return error.ModeNotFound;
    var flat: usize = 0;
    for (tables.abyss, 0..) |mode, i| {
        for (mode.layers, 0..) |*layer, j| {
            if (i == mi and layer.index == layer_index)
                return .{ .mode = i, .layer = j, .flat = flat, .config = layer };
            flat += 1;
        }
    }
    return error.LayerNotFound;
}
pub fn roomIndex(id: u64) ?usize {
    var index: usize = 0;
    for (tables.abyss) |mode| for (mode.layers) |layer| {
        for (layer.rooms) |room| {
            if (room == id) return index;
            index += 1;
        }
    };
    return null;
}

pub const Layer = extern struct {
    times: [rooms_max]u64 = @splat(0),
    star: u32 = 0,
    passed: u32 = 0,
};
pub const Run = extern struct {
    times: [rooms_max]u64 = @splat(0),
    abyss_id: u32 = 0,
    layer: u32 = 0,
    room: u32 = 0,
    completed: u32 = 0,
};
pub const State = extern struct {
    layers: [layer_count]Layer = @splat(.{}),
    run: Run = .{},
    claimed: [mode_count]u32 = @splat(0),
    items: [item_count]u32 = @splat(0),

    pub const init: State = .{};

    pub fn total(state: *const State, mode: usize) u32 {
        var sum: u32 = 0;
        var offset: usize = 0;
        for (tables.abyss[0..mode]) |config| offset += config.layers.len;
        for (state.layers[offset..][0..tables.abyss[mode].layers.len]) |layer| sum += layer.star;
        return sum;
    }

    pub fn enter(state: *State, id: u32, layer_index: u32, room: u32) Failure!void {
        const loc = try locate(id, layer_index);
        if (room == 0 or room > loc.config.rooms.len) return error.RoomNotFound;
        // Sandbox: every configured layer is selectable without clearing its predecessor.
        if (room == 1) {
            // A new first-room entry explicitly restarts the attempt, preserving best results.
            state.run = .{ .abyss_id = id, .layer = layer_index, .room = 1 };
        } else {
            if (state.run.abyss_id != id or state.run.layer != layer_index) return error.NotStarted;
            if (state.run.completed != room - 1) return error.RoomLocked;
            state.run.room = room;
        }
    }

    pub fn progress(state: *State, id: u32, layer_index: u32, room: u32, milliseconds: u64) Failure!void {
        const loc = try locate(id, layer_index);
        if (room == 0 or room > loc.config.rooms.len) return error.RoomNotFound;
        if (state.run.abyss_id != id or state.run.layer != layer_index) return error.NotStarted;
        if (milliseconds == 0 or milliseconds > std.math.maxInt(i64)) return error.Invalid;
        if (room <= state.run.completed) {
            if (state.run.times[room - 1] != milliseconds) return error.Invalid;
            return; // An exact retransmission must not change the attempt.
        }
        if (room != state.run.room or room != state.run.completed + 1) return error.RoomLocked;
        state.run.times[room - 1] = milliseconds;
        state.run.completed = room;
        if (room < loc.config.rooms.len) state.run.room = room + 1;
    }

    pub const Finish = struct { layer: u32, current: u32, best: u32, total: u32 };
    pub fn finish(state: *State, id: u32, win: bool, reason: u32, task_ids: []const u32) Failure!Finish {
        const mi = modeIndex(id) orelse return error.ModeNotFound;
        if (state.run.abyss_id == 0 or state.run.abyss_id != id) return error.NotStarted;
        const loc = try locate(id, state.run.layer);
        if (reason > 2 or (win and reason != 0)) return error.Invalid;
        if (win and state.run.completed != loc.config.rooms.len) return error.NotFinished;
        if (task_ids.len > loc.config.tasks.len) return error.Invalid;
        var seen: [3]bool = @splat(false);
        var elapsed: u64 = 0;
        for (state.run.times[0..state.run.completed]) |time| elapsed = std.math.add(u64, elapsed, time) catch return error.Invalid;
        var stars: u32 = 0;
        for (task_ids) |id_task| {
            const i = std.mem.findScalar(u32, loc.config.tasks, id_task) orelse return error.Invalid;
            if (seen[i]) return error.Invalid;
            seen[i] = true;
            if (win and elapsed <= @as(u64, loc.config.task_seconds[i]) * 1000) stars += 1;
        }
        const saved = &state.layers[loc.flat];
        if (win) {
            if (saved.passed == 0 or stars >= saved.star) saved.times = state.run.times;
            saved.star = @max(saved.star, stars);
            saved.passed = 1;
        }
        const finished: Finish = .{ .layer = state.run.layer, .current = stars, .best = saved.star, .total = state.total(mi) };
        state.run = .{};
        return finished;
    }

    /// Returns item deltas; only configured, guaranteed drops are imported.
    pub fn claim(state: *State, id: u32) Failure![item_count]u32 {
        const mi = modeIndex(id) orelse return error.ModeNotFound;
        const stars = state.total(mi);
        var awarded: [item_count]u32 = @splat(0);
        var threshold = state.claimed[mi];
        for (tables.abyss[mi].rewards) |reward| {
            if (reward.star <= state.claimed[mi] or reward.star > stars) continue;
            for (reward.items) |item| {
                const i = std.mem.findScalar(u32, tables.abyss_reward_item, item.id).?;
                awarded[i] = std.math.add(u32, awarded[i], item.count) catch return error.Invalid;
            }
            threshold = @max(threshold, reward.star);
        }
        if (threshold == state.claimed[mi]) return error.AlreadyClaimed;
        var balances = state.items;
        for (&balances, awarded) |*balance, delta| balance.* = std.math.add(u32, balance.*, delta) catch return error.Invalid;
        state.items = balances;
        state.claimed[mi] = threshold;
        return awarded;
    }
};

test "sequential rooms, timing units, best stars and one-time persisted rewards" {
    const t = std.testing;
    var state: State = .init;
    try state.enter(1000, 2, 1);
    try t.expectError(error.RoomNotFound, state.enter(1000, 1, 100101));
    try state.enter(1000, 1, 1);
    try t.expectError(error.NotStarted, state.progress(2000, 1, 1, 1000));
    try t.expectError(error.NotFinished, state.finish(1000, true, 0, &.{100101}));
    try state.progress(1000, 1, 1, 90_000);
    try state.progress(1000, 1, 1, 90_000);
    try t.expectError(error.Invalid, state.progress(1000, 1, 1, 1));
    try t.expectError(error.Invalid, state.finish(1000, true, 0, &.{ 100101, 100101 }));
    const finished = try state.finish(1000, true, 0, &.{ 100101, 100102, 100103 });
    try t.expectEqual(@as(u32, 3), finished.best);
    try t.expectError(error.NotStarted, state.finish(1000, true, 0, &.{}));
    try state.enter(1000, 1, 1);
    try state.progress(1000, 1, 1, 150_000);
    const worse = try state.finish(1000, true, 0, &.{ 100101, 100102, 100103 });
    try t.expectEqual(@as(u32, 1), worse.current);
    try t.expectEqual(@as(u32, 3), worse.best);
    _ = try state.claim(1000);
    try t.expectEqual(@as(u32, 3), state.claimed[0]);
    try t.expectEqual(@as(u32, 5000), state.items[0]);
    var restored: State = undefined;
    @memcpy(std.mem.asBytes(&restored), std.mem.asBytes(&state));
    try t.expectError(error.AlreadyClaimed, restored.claim(1000));
    try restored.enter(1000, 2, 1);
}

test "two-room attempt resumes and failed/replayed attempts never grant stars" {
    const t = std.testing;
    var state: State = .init;
    try t.expectError(error.NotStarted, state.enter(2000, 1, 2));
    try state.enter(2000, 1, 1);
    try t.expectError(error.RoomLocked, state.progress(2000, 1, 2, 1));
    try state.progress(2000, 1, 1, 40_000);
    var resumed = state;
    try resumed.enter(2000, 1, 2);
    try t.expectError(error.NotFinished, resumed.finish(2000, true, 0, &.{}));
    try resumed.progress(2000, 1, 2, 40_000);
    _ = try resumed.finish(2000, true, 0, &.{ 100104, 100105, 100106 });
    try t.expectEqual(@as(u32, 3), resumed.total(1));
    try resumed.enter(2000, 2, 1);
    const lost = try resumed.finish(2000, false, 2, &.{});
    try t.expectEqual(@as(u32, 0), lost.current);
    try t.expectEqual(@as(u32, 0), resumed.run.abyss_id);
    try t.expectEqual(@as(u32, 0), resumed.layers[(try locate(2000, 2)).flat].passed);
}

test "claim collects every reached milestone and keeps modes independent" {
    const t = std.testing;
    var state: State = .init;
    for (&state.layers) |*layer| layer.* = .{ .star = 3, .passed = 1 };
    _ = try state.claim(1000);
    _ = try state.claim(2000);
    const before = state.items;
    const last = try state.claim(3000);
    try t.expectEqualDeep([3]u32{ 30, 12, 12 }, state.claimed);
    for (state.items, before, last) |balance, prior, delta| try t.expectEqual(prior + delta, balance);
    try t.expectError(error.AlreadyClaimed, state.claim(2000));
    try t.expectError(error.AlreadyClaimed, state.claim(3000));
}

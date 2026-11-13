//! Runs every roze service from a single terminal.
//!
//! `zig build` runs the steps that share its terminal one at a time, so a step
//! that merely depended on the three `run-*-server` steps would start the next
//! server only once the previous one had exited. This spawns them itself.
//! The services are useless without each other, so when one of them stops,
//! the rest are stopped as well.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const process = std.process;
const Child = process.Child;

const log = std.log.scoped(.@"roze-serve-all");

fn usage(io: Io) noreturn {
    Io.File.stdout().writeStreamingAll(io,
        \\Usage: roze-serve-all [executables] [-- arguments]
        \\
        \\Everything after `--` is passed to each executable.
        \\
        \\Options:
        \\  -h, --help            Print this help and exit
        \\
    ) catch {};
    process.exit(0);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    process.exit(1);
}

const Event = union(enum) {
    exit: Exit,
};

const Exit = struct {
    index: usize,
    term: Child.WaitError!Child.Term,
};

fn wait(io: Io, child: *Child, index: usize) Exit {
    return .{ .index = index, .term = child.wait(io) };
}

pub fn main(init: process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const separator = for (args, 0..) |arg, i| {
        if (mem.eql(u8, arg, "--")) break i;
    } else args.len;

    const executables = args[@min(1, args.len)..separator];
    const passthru = args[@min(separator + 1, args.len)..];

    for (executables) |executable| {
        if (mem.eql(u8, executable, "-h") or mem.eql(u8, executable, "--help"))
            usage(io);
    }
    if (executables.len == 0) fatal("no executables to run", .{});

    const children = try arena.alloc(Child, executables.len);
    var spawned: usize = 0;

    for (executables, children) |executable, *child| {
        const argv = try arena.alloc([]const u8, 1 + passthru.len);
        argv[0] = executable;
        for (argv[1..], passthru) |*dest, arg| dest.* = arg;

        child.* = process.spawn(io, .{ .argv = argv }) catch |err| {
            for (children[0..spawned]) |*running| running.kill(io);
            fatal("failed to start {s}: {t}", .{ name(executable), err });
        };
        spawned += 1;
    }

    const events = try arena.alloc(Event, children.len);
    var select: Io.Select(Event) = .init(io, events);

    for (children, 0..) |*child, index| {
        select.concurrent(.exit, wait, .{ io, child, index }) catch |err| {
            select.cancelDiscard();
            for (children) |*running| running.kill(io);
            fatal("failed to wait for {s}: {t}", .{ name(executables[index]), err });
        };
    }

    const first = select.await() catch |err| switch (err) {
        error.Canceled => {
            select.cancelDiscard();
            for (children) |*running| running.kill(io);
            return err;
        },
    };

    // Stop waiting before killing: `Child.kill` reaps the process as well.
    select.cancelDiscard();
    for (children) |*running| running.kill(io);

    const exit = first.exit;
    if (exit.term) |term| {
        fatal("{s} {f}, stopped the other servers", .{ name(executables[exit.index]), term });
    } else |err| {
        fatal("failed to wait for {s}: {t}", .{ name(executables[exit.index]), err });
    }
}

fn name(executable: []const u8) []const u8 {
    return std.fs.path.stem(executable);
}

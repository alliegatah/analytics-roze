const builtin = @import("builtin");

const std = @import("std");
const mem = std.mem;
const process = std.process;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const roze = @import("roze");
const Io = roze.Io;
const Maybe = roze.Maybe;
const Ip4Address = roze.Io.Ip4Address;
const SinglyLinkedListWithTail = roze.SinglyLinkedListWithTail;

const default_listen_address = "127.0.0.1:30003";
const default_listen_backlog: u31 = 64;
const default_concurrency: u32 = 16;
const default_store_dir = "store";
const default_bind_capacity: u32 = 1024;
/// Same default as roze-dir-server's `--bloom-dir`, which serves it to Bloom.
const default_bloom_dir = "bloom";

const gameplay_root_sub_path = "gameplay";

const log = std.log.scoped(.@"roze-scene-server");

pub const std_options: std.Options = .{
    .logFn = Io.std_log.logFn,
};

const Option = enum {
    @"--help",
    @"--listen-address",
    @"--listen-backlog",
    @"--concurrency",
    @"--store-dir",
    @"--bind-capacity",
    @"--team-level",
    @"--world-level",
    @"--bloom-dir",
    @"--sandbox-file",
};

fn usage() noreturn {
    Io.File.Preopen.stdout.writeAllBlocking(std.fmt.comptimePrint(
        \\Usage: roze-scene-server [options]
        \\
        \\Options:
        \\  --help               Print this help and exit
        \\  --listen-address     The address to listen on via TCP; default is {q}
        \\  --listen-backlog     The kernel backlog size for the listening socket; default is {d}
        \\  --concurrency        The amount of connections allowed to be processed concurrently; default is {d}
        \\  --store-dir          The directory to store persistent data files in; default is {q}
        \\  --bind-capacity      The capacity of account-to-uid map; default is {d}
        \\  --team-level         The account (team) level reported to the client; default is {d}
        \\  --world-level        The world level reported to the client; default is {d}
        \\  --bloom-dir          Where the active team's loadout.json is written for Bloom; default is {q}
        \\  --sandbox-file       Weapon refine and psyche settings, re-read at every login; default is {q}
        \\
    , .{
        default_listen_address,
        default_listen_backlog,
        default_concurrency,
        default_store_dir,
        default_bind_capacity,
        roze.Scope.Level.default.team,
        roze.Scope.Level.default.world,
        default_bloom_dir,
        roze.sandbox.default_path,
    })) catch {};
    process.exit(0);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    process.exit(1);
}

const Globals = struct {
    asset_index: *const roze.assets.Index,
    gameplay_dir: []const u8,
    sdk_bind: *roze.he_sdk.Bind,
    level: roze.Scope.Level,
    loadout_path: [:0]const u8,
    sandbox_path: [:0]const u8,
};

pub fn main(init: process.Init.Minimal) !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var io_instance: Io = undefined;
    try io_instance.init();
    defer io_instance.deinit();
    const io = &io_instance;

    var argv = try init.args.iterateAllocator(arena);
    defer argv.deinit();
    assert(argv.skip());

    var listen_address = comptime Ip4Address.parseLiteral(default_listen_address) catch unreachable;
    var listen_options: Io.ListenOptions = .{
        .reuse_address = true,
        .backlog = default_listen_backlog,
    };
    var concurrency = default_concurrency;
    var store_dir: [:0]const u8 = default_store_dir;
    var bind_capacity: u32 = default_bind_capacity;
    var level: roze.Scope.Level = .default;
    var bloom_dir: []const u8 = default_bloom_dir;
    var sandbox_path: [:0]const u8 = roze.sandbox.default_path;

    while (argv.next()) |arg| {
        const option = std.meta.stringToEnum(Option, arg) orelse {
            log.err("unrecognized argument: {s}", .{arg});
            usage();
        };

        switch (option) {
            .@"--help" => usage(),
            .@"--listen-address" => {
                listen_address = Ip4Address.parseLiteral(argv.next() orelse usage()) catch |err|
                    fatal("bad --listen-address: {t}", .{err});
            },
            .@"--listen-backlog" => {
                listen_options.backlog = std.fmt.parseInt(u31, argv.next() orelse usage(), 10) catch |err|
                    fatal("bad --listen-backlog: {t}", .{err});
            },
            .@"--concurrency" => {
                concurrency = std.fmt.parseInt(u32, argv.next() orelse usage(), 10) catch |err|
                    fatal("bad --concurrency: {t}", .{err});
            },
            .@"--store-dir" => {
                store_dir = try arena.dupeSentinel(u8, argv.next() orelse usage(), 0);
            },
            .@"--bloom-dir" => {
                bloom_dir = try arena.dupe(u8, argv.next() orelse usage());
            },
            .@"--sandbox-file" => {
                sandbox_path = try arena.dupeSentinel(u8, argv.next() orelse usage(), 0);
            },
            .@"--bind-capacity" => {
                bind_capacity = std.fmt.parseInt(u32, argv.next() orelse usage(), 10) catch |err|
                    fatal("bad --bind-capacity: {t}", .{err});
            },
            .@"--team-level" => {
                level.team = std.fmt.parseInt(u31, argv.next() orelse usage(), 10) catch |err|
                    fatal("bad --team-level: {t}", .{err});
            },
            .@"--world-level" => {
                level.world = std.fmt.parseInt(u31, argv.next() orelse usage(), 10) catch |err|
                    fatal("bad --world-level: {t}", .{err});
            },
        }
    }

    Io.createDirectoryBlocking(store_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    const gameplay_dir = try arena.printSentinel("{s}/{s}", .{ store_dir, gameplay_root_sub_path }, 0);
    Io.createDirectoryBlocking(gameplay_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    var asset_index: roze.assets.Index = undefined;
    try asset_index.init(arena);

    var sdk_bind = roze.he_sdk.Bind.init(io, arena, store_dir, bind_capacity) catch |err| switch (err) {
        error.OutOfMemory => fatal(
            \\failed to allocate account bind storage with capacity {d}
            \\likely cause: --bind-capacity is higher than the system can process
        , .{bind_capacity}),
        error.MalformedFile => fatal(
            \\failed to read account bind file
            \\likely cause: the file is corrupted or its format is incompatible (e.g. due to breaking change)
        , .{}),
        error.TooManyAccounts => fatal(
            \\too many accounts in the account bind file
            \\likely cause: the server was previously running with a higher --bind-capacity value
        , .{}),
        else => |e| return e,
    };

    const clients = arena.alloc(Client, concurrency) catch |err| switch (err) {
        error.OutOfMemory => fatal(
            \\couldn't allocate memory for {d} clients
            \\likely cause: --concurrency is higher than the system can process
        , .{concurrency}),
    };

    const globals: Globals = .{
        .asset_index = &asset_index,
        .gameplay_dir = gameplay_dir,
        .sdk_bind = &sdk_bind,
        .level = level,
        .loadout_path = try arena.printSentinel("{s}/{s}", .{ bloom_dir, roze.loadout.file_name }, 0),
        .sandbox_path = sandbox_path,
    };
    roze.sandbox.ensureFile(io, sandbox_path);

    const listening = io.listen(&listen_address, listen_options) catch |err| switch (err) {
        error.AddressInUse => fatal(
            \\the address {f} is already in use
            \\likely cause: another instance of this server is already running
        , .{listen_address}),
        else => |e| return e,
    };
    defer io.closeSocket(&listening.raw);

    for (clients) |*client|
        client.submitAccept(io, &listening);

    var sdk_bind_access_queue: SinglyLinkedListWithTail = .init;

    log.info("waiting for clients at tcp://{f}", .{listen_address});

    while (true) {
        try io.wait(std.math.maxInt(u63));

        while (io.nextCompletion()) |storage| {
            const client: *Client = @alignCast(@fieldParentPtr("operation", storage));
            switch (storage.completion.result) {
                .tcp_accept => |tcp_accept| {
                    const connected = tcp_accept catch |err| {
                        log.warn("accept failed: {t}", .{err});
                        client.submitAccept(io, &listening);
                        continue;
                    };

                    log.info("new connection from {f}", .{connected.raw.address});

                    client.state = .start;
                    client.connected_socket = connected;

                    var maybe: Maybe(Io.Operation.Result) = .{ .ptr_maybe = &storage.completion.result };
                    client.state = tick(io, &globals, client, &maybe) catch |err| {
                        assert(err != error.StoreLocked);

                        log.err("client tick failed: {t}", .{err});
                        client.closeAndSubmitAccept(io, &listening, err);
                        continue;
                    };
                },
                else => |result| {
                    var maybe: Maybe(Io.Operation.Result) = .{ .ptr_maybe = &result };
                    client.state = tick(io, &globals, client, &maybe) catch |err| switch (err) {
                        error.StoreLocked => {
                            sdk_bind_access_queue.append(&client.queue_node);
                            continue;
                        },
                        else => |e| {
                            if (e != error.EndOfStream and e != error.ConnectionResetByPeer)
                                log.err("client tick failed: {t}", .{err});

                            client.closeAndSubmitAccept(io, &listening, e);
                            continue;
                        },
                    };
                },
            }
        }

        while (!globals.sdk_bind.lock) {
            const node = sdk_bind_access_queue.popFirst() orelse break;
            const client: *Client = @alignCast(@fieldParentPtr("queue_node", node));

            var maybe: Maybe(Io.Operation.Result) = .{ .ptr_maybe = null };
            client.state = tick(io, &globals, client, &maybe) catch |err| {
                assert(err != error.StorageLocked); // See loop condition.

                if (err != error.EndOfStream and err != error.ConnectionResetByPeer)
                    log.err("client tick failed: {t}", .{err});

                client.closeAndSubmitAccept(io, &listening, err);
                continue;
            };
        }
    }
}

const Client = struct {
    const read_buffer_size: usize = 128 * 1024;
    const write_buffer_size: usize = 128 * 1024;
    const state_path_buffer_size: usize = 1024;

    comptime {
        // Must fit at least `message_size_max` and `Header`.
        // The buffers are used as is, without rebasing until messages are processed.

        assert(read_buffer_size >= roze.net.message_size_max + roze.net.Header.size);
        assert(write_buffer_size >= roze.net.message_size_max + roze.net.Header.size);
    }

    state: State,
    send_seq: u32,
    role_id: u64,
    connected_socket: Io.Socket.Connected,
    operation: Io.Operation.Storage,
    accept_buffer: Io.Operation.TcpAccept.Buffer,
    read_buffer: [read_buffer_size]u8,
    read_buffer_seek: usize,
    read_buffer_end: usize,
    write_buffer: [write_buffer_size]u8,
    write_buffer_seek: usize,
    write_buffer_end: usize,
    queue_node: SinglyLinkedListWithTail.Node,
    sdk_bind_save_vec_buffer: roze.he_sdk.Bind.SaveVector,
    sdk_bind_save_header_buffer: roze.he_sdk.Bind.SaveHeaderBuffer,
    // active while `writing_sdk_bind`, `writing_gameplay_state_file`, `reading_gameplay_state_file`
    file_rw: struct {
        kind: enum { read, write },
        handle: Io.File.Handle,
        /// Used for both reading and writing. Cast as needed.
        buffers: []Io.Buffer(.@"var"),
        offset: u64,
    },
    gameplay_state_file: Io.File.Optional,
    /// Hash of the loadout last written for Bloom; 0 when none was written.
    loadout_hash: u64,
    // initialized by `start_loading_gameplay_state`
    gameplay_state_path_buffer: [state_path_buffer_size]u8,
    gameplay_state_path: [:0]const u8, // points to `gameplay_state_path_buffer`
    gameplay: roze.Gameplay,
    gameplay_header: roze.Gameplay.Header,
    // Used for both reading and writing. Cast as needed.
    gameplay_vec: roze.Gameplay.StateVector(.@"var"),

    const State = enum {
        start,
        sending_set_mode,
        waiting_login,
        writing_sdk_bind,
        syncing_sdk_bind,
        start_loading_gameplay_state,
        opening_gameplay_state_file,
        creating_gameplay_state_file,
        reading_gameplay_state_file,
        start_saving_gameplay_state,
        writing_gameplay_state_file,
        syncing_gameplay_state_file,
        reading_messages,
        sending_messages,
    };

    fn submitAccept(client: *Client, io: *Io, listening: *const Io.Socket.Listening) void {
        client.operation = .init(.{ .tcp_accept = .{
            .listening_socket_handle = listening.raw.handle,
            .buffer = &client.accept_buffer,
        } });
        io.submit(&client.operation);
    }

    fn closeAndSubmitAccept(client: *Client, io: *Io, listening: *const Io.Socket.Listening, reason: anyerror) void {
        log.info("connection from {f} closed (reason: {t}, state: {t})", .{ client.connected_socket.raw.address, reason, client.state });
        io.closeSocket(&client.connected_socket.raw);

        if (client.gameplay_state_file.unwrap()) |state_file| {
            state_file.closeBlocking(io);
            client.gameplay_state_file = .none;
        }

        client.submitAccept(io, listening);
    }

    fn submitWrite(client: *Client, io: *Io) void {
        client.operation = .init(.{ .tcp_write = .{
            .connected_socket_handle = client.connected_socket.raw.handle,
            .buffer = client.write_buffer[client.write_buffer_seek..client.write_buffer_end],
        } });
        io.submit(&client.operation);
    }

    /// Returns `true` if another write operation was submitted.
    fn tcpWriteMore(client: *Client, io: *Io) bool {
        assert(client.write_buffer_seek <= client.write_buffer_end);

        if (client.write_buffer_seek < client.write_buffer_end) {
            client.submitWrite(io);
            return true;
        } else {
            // The buffer is fully drained.
            client.write_buffer_seek = 0;
            client.write_buffer_end = 0;
            return false;
        }
    }

    fn submitRead(client: *Client, io: *Io) void {
        client.operation = .init(.{ .tcp_read = .{
            .connected_socket_handle = client.connected_socket.raw.handle,
            .buffer = client.read_buffer[client.read_buffer_end..],
        } });
        io.submit(&client.operation);
    }

    fn rebaseReadBuffer(client: *Client) void {
        if (client.read_buffer_end == client.read_buffer_seek) {
            client.read_buffer_end = 0;
            client.read_buffer_seek = 0;
        } else if (client.read_buffer_seek != 0) {
            const new_end = client.read_buffer_end - client.read_buffer_seek;
            @memmove(
                client.read_buffer[0..new_end],
                client.read_buffer[client.read_buffer_seek..client.read_buffer_end],
            );

            client.read_buffer_seek = 0;
            client.read_buffer_end = new_end;
        }
    }

    const AdvanceFileRwStatus = enum {
        rw_submitted,
        fsync_submitted,
        read_completed,
    };

    fn advanceFileRw(client: *Client, io: *Io, advance_n: usize) AdvanceFileRwStatus {
        const rw = &client.file_rw;
        rw.offset += advance_n;

        var buffers = rw.buffers;
        defer rw.buffers = buffers;

        var remaining = advance_n;

        while (remaining >= buffers[0].slice().len) {
            remaining -= buffers[0].slice().len;
            buffers = buffers[1..];

            if (buffers.len == 0) switch (rw.kind) {
                .read => return .read_completed,
                .write => {
                    client.operation = .init(.{ .file_synchronize = .{
                        .file_handle = rw.handle,
                    } });
                    io.submit(&client.operation);

                    return .fsync_submitted;
                },
            };
        }

        buffers[0].advance(remaining);

        client.operation = switch (rw.kind) {
            .read => .init(.{ .file_read = .{
                .file_handle = rw.handle,
                .buffers = buffers,
                .offset = rw.offset,
            } }),
            .write => .init(.{ .file_write = .{
                .file_handle = rw.handle,
                .buffers = @ptrCast(buffers),
                .offset = rw.offset,
            } }),
        };

        io.submit(&client.operation);
        return .rw_submitted;
    }
};

fn tick(
    io: *Io,
    globals: *const Globals,
    client: *Client,
    io_result_maybe: *Maybe(Io.Operation.Result),
) !Client.State {
    const current_time: Io.Timespec = .collect(io);

    state: switch (client.state) {
        .start => {
            _ = io_result_maybe.take();

            client.send_seq = 0;
            client.write_buffer_seek = 0;
            client.read_buffer_seek = 0;
            client.write_buffer_end = 0;
            client.read_buffer_end = 0;
            client.gameplay = .init;
            client.gameplay_state_file = .none;
            client.loadout_hash = 0;

            const set_mode: roze.net.SetModeAck = .{
                .ret = .success,
                .mode = .unencrypted,
            };

            comptime assert(Client.write_buffer_size >= roze.net.SetModeAck.full_size);
            const buffer = client.write_buffer[0..roze.net.SetModeAck.full_size];
            client.write_buffer_end = buffer.len;

            set_mode.encode(&.{
                .opcode = .SET_MODE_ACK,
                .encrypted_len = roze.net.SetModeAck.size_headerless,
                .decrypted_len = roze.net.SetModeAck.size_headerless,
                .seq = 0,
            }, buffer);

            continue :state .sending_set_mode;
        },
        .sending_set_mode => {
            if (io_result_maybe.take()) |io_result| {
                assert(io_result == .tcp_write);
                const written = try io_result.tcp_write;
                client.write_buffer_seek += written;
            }

            if (client.tcpWriteMore(io)) return .sending_set_mode;

            client.send_seq = 1;
            continue :state .waiting_login;
        },
        .waiting_login => {
            if (io_result_maybe.take()) |io_result| {
                assert(io_result == .tcp_read);

                const read_n = try io_result.tcp_read;
                if (read_n == 0) return error.EndOfStream;

                client.read_buffer_end += read_n;
                assert(client.read_buffer_end <= client.read_buffer.len);
            }

            if (client.read_buffer_end < roze.net.Header.size) {
                client.submitRead(io);
                return .waiting_login;
            }

            const header: roze.net.Header = .decode(
                client.read_buffer[client.read_buffer_seek..][0..roze.net.Header.size],
            );

            if (header.opcode != .PROTO) return error.UnexpectedOpcode;

            if (client.read_buffer_end < roze.net.Header.size + header.encrypted_len) {
                client.submitRead(io);
                return .waiting_login;
            }

            const body = client.read_buffer[client.read_buffer_seek +
                roze.net.Header.size ..][0..header.encrypted_len];

            var sink: roze.net.Sink = .{
                .buffer = &client.write_buffer,
                .end = &client.write_buffer_end,
                .send_seq = &client.send_seq,
            };

            const get_or_create = handleAccountLogin(globals, body, &sink, current_time) catch |err| switch (err) {
                error.SinkBufferOverflow => |e| return e,
                error.StoreLocked => {
                    client.state = .waiting_login; // retain current state
                    return error.StoreLocked;
                },
                else => |e| {
                    log.warn(
                        "login for connection from {f} failed: {t}",
                        .{ client.connected_socket.raw.address, e },
                    );
                    return e;
                },
            };

            client.read_buffer_seek = 0;
            client.read_buffer_end = 0;

            client.role_id = @backingInt(get_or_create.role_id);
            if (get_or_create.needs_save) {
                globals.sdk_bind.lock = true;

                client.sdk_bind_save_vec_buffer = globals.sdk_bind.getSaveVector(
                    &client.sdk_bind_save_header_buffer,
                );

                client.file_rw = .{
                    .kind = .write,
                    .handle = globals.sdk_bind.file.handle,
                    .buffers = @ptrCast(&client.sdk_bind_save_vec_buffer),
                    .offset = 0,
                };

                continue :state .writing_sdk_bind;
            } else {
                continue :state .start_loading_gameplay_state;
            }
        },
        .writing_sdk_bind => {
            assert(globals.sdk_bind.lock);

            const written_this_tick = if (io_result_maybe.take()) |io_result| result: {
                assert(io_result == .file_write);
                break :result try io_result.file_write;
            } else 0;

            switch (client.advanceFileRw(io, written_this_tick)) {
                .read_completed => unreachable, // writing
                .rw_submitted => return .writing_sdk_bind,
                .fsync_submitted => continue :state .syncing_sdk_bind,
            }
        },
        .syncing_sdk_bind => {
            assert(globals.sdk_bind.lock);

            if (io_result_maybe.take()) |io_result| {
                assert(io_result == .file_synchronize);
                try io_result.file_synchronize;

                globals.sdk_bind.lock = false;
                continue :state .start_loading_gameplay_state;
            }

            return .syncing_sdk_bind;
        },
        .start_loading_gameplay_state => {
            client.gameplay = .init;
            // Not part of the save: re-read at every login, so edits apply on the next one.
            client.gameplay.transient.sandbox = roze.sandbox.load(io, globals.sandbox_path);

            client.gameplay_state_path = mem.printSentinel(
                &client.gameplay_state_path_buffer,
                "{s}/role_{d}.bin",
                .{ globals.gameplay_dir, client.role_id },
                0,
            ) catch {
                log.err("gameplay state path is too long", .{});
                return error.StatePathTooLong;
            };

            client.operation = .init(.{ .file_open = .{
                .path = client.gameplay_state_path,
                .mode = .load,
            } });
            io.submit(&client.operation);

            continue :state .opening_gameplay_state_file;
        },
        .opening_gameplay_state_file => {
            if (io_result_maybe.take()) |io_result| {
                assert(io_result == .file_open);

                const file = io_result.file_open catch |err| switch (err) {
                    error.FileNotFound => {
                        client.operation = .init(.{ .file_open = .{
                            .path = client.gameplay_state_path,
                            .mode = .create,
                        } });
                        io.submit(&client.operation);
                        continue :state .creating_gameplay_state_file;
                    },
                    else => |e| return e,
                };

                client.gameplay_state_file = .wrap(file);

                client.gameplay.writableVector(
                    &client.gameplay_header,
                    &client.gameplay_vec,
                );

                client.file_rw = .{
                    .kind = .read,
                    .handle = client.gameplay_state_file.unwrap().?.handle,
                    .buffers = &client.gameplay_vec,
                    .offset = 0,
                };

                continue :state .reading_gameplay_state_file;
            }

            return .opening_gameplay_state_file;
        },
        .creating_gameplay_state_file => {
            if (io_result_maybe.take()) |io_result| {
                assert(io_result == .file_open);
                client.gameplay_state_file = .wrap(try io_result.file_open);

                // We must write the initial data,
                // so that the subsequent login will encounter the file and read it.

                continue :state .start_saving_gameplay_state;
            }

            return .creating_gameplay_state_file;
        },
        .reading_gameplay_state_file => {
            const read_n = if (io_result_maybe.take()) |io_result| result: {
                assert(io_result == .file_read);
                const read_n = try io_result.file_read;
                if (read_n == 0) {
                    // A file written by an older version doesn't have the fields added since.
                    // They keep their initial values and `migrate` takes it from there.
                    const header_was_read = client.file_rw.offset >= @sizeOf(roze.Gameplay.Header);
                    if (!header_was_read or !client.gameplay_header.isOlder())
                        return error.SaveFileMalformed;

                    _ = client.gameplay.migrate(&client.gameplay_header);
                    log.info("migrated gameplay state of role {d} from version {d}", .{
                        client.role_id,
                        client.gameplay_header.state_version,
                    });
                    continue :state .start_saving_gameplay_state;
                }
                break :result read_n;
            } else 0;

            switch (client.advanceFileRw(io, read_n)) {
                .read_completed => {
                    if (client.gameplay.migrate(&client.gameplay_header)) {
                        log.info("migrated gameplay state of role {d} from version {d}", .{
                            client.role_id,
                            client.gameplay_header.state_version,
                        });
                        continue :state .start_saving_gameplay_state;
                    }

                    continue :state .sending_messages;
                },
                .rw_submitted => return .reading_gameplay_state_file,
                .fsync_submitted => unreachable, // reading
            }
        },
        .start_saving_gameplay_state => {
            client.gameplay.readableVector(
                &client.gameplay_header,
                @ptrCast(&client.gameplay_vec),
            );

            client.file_rw = .{
                .kind = .write,
                .handle = client.gameplay_state_file.unwrap().?.handle,
                .buffers = &client.gameplay_vec,
                .offset = 0,
            };

            continue :state .writing_gameplay_state_file;
        },
        .writing_gameplay_state_file => {
            const write_n = if (io_result_maybe.take()) |io_result| result: {
                assert(io_result == .file_write);
                break :result try io_result.file_write;
            } else 0;

            switch (client.advanceFileRw(io, write_n)) {
                .read_completed => unreachable, // writing
                .rw_submitted => return .writing_gameplay_state_file,
                .fsync_submitted => continue :state .syncing_gameplay_state_file,
            }
        },
        .syncing_gameplay_state_file => {
            if (io_result_maybe.take()) |io_result| {
                assert(io_result == .file_synchronize);
                try io_result.file_synchronize;

                globals.sdk_bind.lock = false;
                continue :state .sending_messages;
            }

            return .syncing_gameplay_state_file;
        },
        .sending_messages => {
            if (io_result_maybe.take()) |io_result| {
                assert(io_result == .tcp_write);
                const written = try io_result.tcp_write;
                client.write_buffer_seek += written;
            }

            if (client.tcpWriteMore(io)) return .sending_messages;

            // All complete buffered frames have been handled. Any remaining frame
            // needs more bytes, even if its header has already arrived. Re-entering
            // the parser without a read would spin forever on a partial body.
            client.submitRead(io);
            return .reading_messages;
        },
        .reading_messages => {
            if (io_result_maybe.take()) |io_result| {
                assert(io_result == .tcp_read);

                const read_n = try io_result.tcp_read;
                if (read_n == 0) return error.EndOfStream;

                client.read_buffer_end += read_n;
            }

            assert(client.read_buffer_end <= client.read_buffer.len);
            assert(client.read_buffer_seek <= client.read_buffer_end);

            if (client.read_buffer_end < roze.net.Header.size) {
                client.submitRead(io);
                return .reading_messages;
            }

            var buffered = client.read_buffer[client.read_buffer_seek..client.read_buffer_end];
            var batched: u32 = 0;
            defer if (batched > 1) log.debug(
                "processed batch of {d} messages from {f}",
                .{ batched, client.connected_socket.raw.address },
            );

            var save_requested: bool = false;

            while (buffered.len >= roze.net.Header.size) : ({
                buffered = client.read_buffer[client.read_buffer_seek..client.read_buffer_end];
            }) {
                const header: roze.net.Header = .decode(
                    client.read_buffer[client.read_buffer_seek..][0..roze.net.Header.size],
                );

                if (buffered.len < header.encrypted_len + roze.net.Header.size)
                    break;

                batched += 1;

                const body = buffered[roze.net.Header.size..][0..header.encrypted_len];
                client.read_buffer_seek += header.encrypted_len + roze.net.Header.size;

                switch (header.opcode) {
                    .HB => {
                        if (client.write_buffer.len - client.write_buffer_end < roze.net.Heartbeat.full_size)
                            return error.WriteBufferOverflow;

                        const heartbeat_buffer = client.write_buffer[client.write_buffer_end..][0..roze.net.Heartbeat.full_size];
                        client.write_buffer_end += heartbeat_buffer.len;

                        const heartbeat: roze.net.Heartbeat = .{
                            .timestamp_ms = current_time.toMilliseconds(),
                            .rtt = 0,
                        };

                        const heartbeat_header: roze.net.Header = .{
                            .opcode = .HB,
                            .encrypted_len = roze.net.Heartbeat.size_headerless,
                            .decrypted_len = roze.net.Heartbeat.size_headerless,
                            .seq = client.send_seq,
                        };

                        client.send_seq +%= 1;

                        heartbeat.encode(&heartbeat_header, heartbeat_buffer);
                    },
                    .PROTO => {
                        const message = roze.protobuf.decode(roze.protobuf.gen.CSMsgPkg.Decoded, body) catch
                            return error.BadRequest;

                        const head = message.head orelse return error.BadRequest;

                        var scope: roze.Scope = .{
                            .time = current_time,
                            .sink = .{
                                .buffer = &client.write_buffer,
                                .end = &client.write_buffer_end,
                                .send_seq = &client.send_seq,
                            },
                            .command = .{
                                .id = head.cmd,
                                .data = message.body,
                            },
                            .gameplay = &client.gameplay,
                            .asset_index = globals.asset_index,
                            .level = globals.level,
                            .store = .{
                                .role_id = client.role_id,
                                .gameplay_state_save_requested = false,
                            },
                        };

                        roze.commands.execute(&scope) catch |err| switch (err) {
                            error.SinkBufferOverflow => |e| {
                                log.err(
                                    \\sink buffer overflow while executing command with id {d}
                                    \\consider re-evaluating `write_buffer_size`
                                , .{scope.command.id});
                                return e;
                            },
                            else => |e| {
                                log.err("command {d} failed ({d} body bytes): {t}", .{ head.cmd, message.body.len, e });
                                return e;
                            },
                        };

                        if (scope.store.gameplay_state_save_requested) save_requested = true;
                        writeLoadout(io, globals, client);
                    },
                    _ => |illegal| {
                        log.debug(
                            "received illegal opcode {d} from {f}",
                            .{ @backingInt(illegal), client.connected_socket.raw.address },
                        );
                        return error.UnexpectedOpcode;
                    },
                    else => |unexpected| {
                        log.debug(
                            "unexpected opcode {t} from {f}",
                            .{ unexpected, client.connected_socket.raw.address },
                        );
                        return error.UnexpectedOpcode;
                    },
                }
            }

            client.rebaseReadBuffer();

            if (save_requested) {
                continue :state .start_saving_gameplay_state;
            } else {
                continue :state .sending_messages;
            }
        },
    }
}

/// Rewrites `<bloom dir>/loadout.json` when the active team's build changed,
/// so Bloom can attach it to the next battle log. Failures are logged and
/// retried after the next command.
fn writeLoadout(io: *Io, globals: *const Globals, client: *Client) void {
    var buffer: [roze.loadout.max_size]u8 = undefined;
    const text = roze.loadout.render(&buffer, &client.gameplay) orelse
        return log.warn("loadout does not fit in {d} bytes; not written", .{buffer.len});
    const hash = std.hash.Wyhash.hash(0, text) | 1;
    if (hash == client.loadout_hash) return;

    const file = Io.File.createBlocking(io, globals.loadout_path) catch |err|
        return log.warn("cannot write {s}: {t}", .{ globals.loadout_path, err });
    defer file.closeBlocking(io);
    file.writeAllBlocking(io, text, 0) catch |err|
        return log.warn("cannot write {s}: {t}", .{ globals.loadout_path, err });
    client.loadout_hash = hash;
    log.debug("wrote {s} ({d} bytes)", .{ globals.loadout_path, text.len });
}

const HandleAccountLoginError = roze.net.Sink.Error || error{
    TooManyAccounts,
    StoreLocked,
    BadRequest,
};

const channel_name_length_max = 5;

fn handleAccountLogin(
    globals: *const Globals,
    data: []const u8,
    sink: *roze.net.Sink,
    current_time: Io.Timespec,
) HandleAccountLoginError!roze.he_sdk.Bind.GetOrCreate {
    const message = roze.protobuf.decode(roze.protobuf.gen.CSMsgPkg.Decoded, data) catch
        return error.BadRequest;

    const head = message.head orelse return error.BadRequest;

    if (head.cmd != @backingInt(roze.protobuf.gen.EClientServerCmds.CS_ACCOUNT_LOGIN))
        return error.BadRequest;

    const request = roze.protobuf.decode(roze.protobuf.gen.CS_Account_Login.Decoded, message.body) catch
        return error.BadRequest;

    if (request.channel_name.len > channel_name_length_max)
        return error.BadRequest;

    const channel_uid = std.fmt.parseInt(u64, request.channel_uid, 10) catch
        return error.BadRequest;

    const get_or_create = try globals.sdk_bind.getOrCreate(channel_uid);

    var userid_buf: [channel_name_length_max + 21]u8 = undefined;
    const userid = mem.print(&userid_buf, "{s}_{d}", .{ request.channel_name, channel_uid }) catch
        unreachable;

    const response: roze.protobuf.gen.SC_Account_Login = .{
        .result = 0,
        .connect_identify_id = @backingInt(get_or_create.role_id),
        .world_id = 909,
        .timestamp = @intCast(current_time.toSeconds()),
        .brief_role = .{ .role_id = @backingInt(get_or_create.role_id) },
        .userid = userid,
    };

    try sink.send(.SC_ACCOUNT_LOGIN, response);
    return get_or_create;
}

// Exercise the real state machine with queued I/O completions, without sockets.
const TransportFixture = struct {
    client: *Client,
    io: Io = .{ .submissions = .init, .completions = .init, .userdata = undefined },
    globals: Globals = undefined, // Heartbeat handling does not use account globals.

    fn init() !TransportFixture {
        const client = try std.testing.allocator.create(Client);
        client.* = undefined;
        client.state = .reading_messages;
        client.connected_socket = .{ .raw = .{
            // Only copied into queued operations; no system I/O is performed.
            .handle = if (builtin.os.tag == .windows) @ptrFromInt(1) else 0,
            .address = comptime Ip4Address.parseLiteral("127.0.0.1:1") catch unreachable,
        } };
        client.send_seq = 1;
        client.read_buffer_seek = 0;
        client.read_buffer_end = 0;
        client.write_buffer_seek = 0;
        client.write_buffer_end = 0;
        return .{ .client = client };
    }

    fn deinit(f: *TransportFixture) void {
        std.testing.allocator.destroy(f.client);
    }

    fn complete(f: *TransportFixture, result: Io.Operation.Result) !void {
        f.io.submissions = .init;
        var maybe: Maybe(Io.Operation.Result) = .{ .ptr_maybe = &result };
        f.client.state = try tick(&f.io, &f.globals, f.client, &maybe);
        try std.testing.expect(f.io.submissions.head != null);
    }

    fn receive(f: *TransportFixture, bytes: []const u8) !void {
        @memcpy(f.client.read_buffer[f.client.read_buffer_end..][0..bytes.len], bytes);
        try f.complete(.{ .tcp_read = bytes.len });
    }
};

test "fragmented TCP frames schedule reads at every header and body boundary" {
    var frame: [roze.net.Heartbeat.full_size]u8 = @splat(0);
    const header: roze.net.Header = .{
        .opcode = .HB,
        .encrypted_len = roze.net.Heartbeat.size_headerless,
        .decrypted_len = roze.net.Heartbeat.size_headerless,
        .seq = 1,
    };
    header.encode(frame[0..roze.net.Header.size]);

    for (1..frame.len) |split| {
        var f = try TransportFixture.init();
        defer f.deinit();
        try f.receive(frame[0..split]);
        try std.testing.expectEqual(Client.State.reading_messages, f.client.state);
        try std.testing.expect(f.client.operation.submission.operation == .tcp_read);
        try std.testing.expectEqualSlices(u8, frame[0..split], f.client.read_buffer[0..f.client.read_buffer_end]);

        try f.receive(frame[split..]);
        try std.testing.expectEqual(Client.State.sending_messages, f.client.state);
        try std.testing.expectEqual(@as(usize, roze.net.Heartbeat.full_size), f.client.write_buffer_end);
        try std.testing.expectEqual(@as(usize, 0), f.client.read_buffer_end);
        try f.complete(.{ .tcp_write = f.client.write_buffer_end });
        try std.testing.expectEqual(Client.State.reading_messages, f.client.state);
        try std.testing.expect(f.client.operation.submission.operation == .tcp_read);
    }
}

test "header-only frames and batched frames followed by partial bodies make progress" {
    var header: roze.net.Header = .{ .opcode = .HB, .encrypted_len = 0, .decrypted_len = 0, .seq = 1 };
    var frame: [roze.net.Header.size]u8 = undefined;
    header.encode(&frame);
    var f = try TransportFixture.init();
    defer f.deinit();
    try f.receive(&frame);
    try std.testing.expectEqual(Client.State.sending_messages, f.client.state);
    try std.testing.expectEqual(@as(usize, 0), f.client.read_buffer_end);
    try f.complete(.{ .tcp_write = f.client.write_buffer_end });

    var batch: [roze.net.Header.size * 2 + 1]u8 = @splat(0);
    @memcpy(batch[0..frame.len], &frame);
    header.encrypted_len = roze.net.Heartbeat.size_headerless;
    header.decrypted_len = roze.net.Heartbeat.size_headerless;
    header.encode(batch[frame.len..][0..roze.net.Header.size]);
    try f.receive(&batch);
    try std.testing.expectEqual(Client.State.sending_messages, f.client.state);
    try std.testing.expectEqual(@as(usize, roze.net.Header.size + 1), f.client.read_buffer_end);
    try f.complete(.{ .tcp_write = f.client.write_buffer_end });
    try std.testing.expectEqual(Client.State.reading_messages, f.client.state);
    try f.receive(&@as([roze.net.Heartbeat.size_headerless - 1]u8, @splat(0)));
    try std.testing.expectEqual(Client.State.sending_messages, f.client.state);
    try std.testing.expectEqual(@as(usize, 0), f.client.read_buffer_end);
}

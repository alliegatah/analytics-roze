# Roze
Silver Palace Server Emulator prioritizing performance, stability and correctness.

This is a fork of Roze by xeon (xeondev / ReversedRooms). The server architecture, I/O layer and protocol work are xeon's; this fork adds the combat sandbox described under [Features](#features) and is maintained separately. It is not affiliated with or supported by the original project, so please don't take questions about this fork there.

![screenshot](assets/images/screenshot.png)

## Architecture
- **Static memory allocation.** `Roze` doesn't make heap allocations after startup. Instead, during the initialization, it allocates all of the required resources up-front, based on CLI arguments. This allows for predictable resource consumption. Once the server is started up, the memory footprint won't grow. Therefore it's trivial for server operators to put hard resource limits without using complicated and vendor-specific features like cgroups for this.
- **Asynchronous I/O.** The server uses the state-of-the-art I/O primitives, such as `io_uring`. We're not relying on "language magic" (such as async/await) to make use of it. Instead, we implement a crossplatform wrapper providing completion-based I/O interface. It's the application's responsibility to implement an event loop itself on top of it. We're writing state machines by hand. **Why `async`/`await` when you can `switch`?**
- **No external dependencies.** Focusing on performance, it's important to have every component of the software purpose-built. This allows not wasting any performance doing unnecessary work. For example, a general-purpose protobuf deserialization library, by the spec, would not allow zero-allocation decoding. However, knowing the end implementation that is on the client we're building the server for, instead of thinking of some possible "abstract" implementation that does not exist, we can optimize **the spec itself** for our concrete use-case.

## Features
This fork turns Roze into a combat sandbox for testing every character, weapon and gear piece. Game data comes from the client's own tables (see `assets/import_sandbox_tables.py`).

- **Everything unlocked and maxed.** All playable characters at the highest level and break level with talents maxed; two copies of every weapon and four of every gear piece, maxed with their stats applied; one of each regular catalyst; account level 50 and world level 4 (`--team-level`/`--world-level` on the scene server). Every save point and teleport point is unlocked for fast travel.
- **Configurable refine and psyche.** Weapon refine and psyche levels come from `sandbox.zon`, re-read at every login (see [Sandbox settings](#sandbox-settings)).
- **City combat.** Exposing a city NPC starts a fight; shops show their stock (purchases are refused).
- **Thought Experiment (Abyss).** Every layer is selectable, progress and star rewards persist, and each room side keeps its own team and catalysts. Room teams start every battle at full HP and full ultimate, as the game's dungeon table specifies.
- **Training room.** `bloom/training_room.lua` turns chosen Thought Experiment rooms into a configurable training encounter (enemy, monster level, stat scaling, affix, time limit, attribute rates). The dir server serves the `bloom/` directory to the Bloom client patch at `/bloom/<file>`, re-read on every request.
- **Damage-log support.** The scene server writes the active team's build to `bloom/loadout.json` for Bloom's per-battle damage logs. Battle verification reports from the client are enabled and summarized in the log (they carry no damage numbers).
- **Stability.** Battle-end disconnects are fixed (fragmented packets and negative varints), and `zig build serve-all` runs all three services from one terminal.

Not done yet: Circuitway (wind road) unlocks use guessed ids, world-dungeon entrances do not appear, and gear enchants are missing.

## Platform support
Because we maintain our own I/O layer, platform support depends on the existence of an implementation of this layer for the target.

At present, we support `Linux` and `Windows`.

##### NOTE: on Linux, you **must** have `io_uring` enabled.

## Requirements
**Roze** is a zero-dependency project from day one, all you need to build it from sources is:
- Zig Compiler, version `0.17.1`: [Linux](https://ziglang.org/download/0.17.1/zig-x86_64-linux-0.17.1.tar.xz)/[Windows](https://ziglang.org/download/0.17.1/zig-x86_64-windows-0.17.1.zip)

The project was originally pinned to the development build `0.17.0-dev.1946+d813faaf0`, which is no longer downloadable; `0.17.1` builds it unchanged.

##### HINT: if you're using Linux, you can run the `envrc` script included in this repository to setup the zig environment. It's a simple `/bin/sh` script that downloads zig compiler 0.17.1, untars it and adds to the `$PATH`.

## Compiling and running
Once you've got `zig` compiler set up, you can compile the server.
First, double-check that the compiler version matches by typing `zig version` in your terminal.
```sh
$ zig version
0.17.1
```
If the output matches, you can proceed to the compilation.

Start by cloning this repository using [git](https://git-scm.com/).

In short, to **compile** the server, a single command is enough:
```sh
$ zig build
```
That's it. The resulting binaries will appear under the `zig-out/bin/` directory.

However, if you want to compile **and run** it, a single command starts all three services in one terminal.

Note that it has to be kept running. If one of the services stops, the other two are stopped as well.
```sh
zig build serve-all
```

Arguments after `--` are passed to every service, so only use the ones they all accept (such as `--concurrency`) here:
```sh
$ zig build serve-all -- --concurrency 1
```

Each service can still be run on its own, one command (and one terminal) per service:
```sh
zig build run-dir-server
zig build run-sdk-server
zig build run-scene-server
```

Optionally, if you run the server locally and are the only person who will be using it, you can pass the `--concurrency 1` argument to each service. This will make the server allocate memory for one session only, instead of the default value that is a bit higher. Example for `scene-server`:
```sh
$ zig build run-scene-server -- --concurrency 1
```

If you've got all three servers running (each one should log out the fact that it's waiting, whichever way you started them), you can proceed to the client setup.

## Sandbox settings
Weapon refine (R) and psyche (P) levels are set in `sandbox.zon`, next to where the servers run. The scene server writes it from `src/sandbox_template.zon` on startup if it is missing, and reads it again at every login: edit it, then log out and back in. No rebuild or restart is needed.

```zon
.{
    .defaults = .{
        .weapon_refine = .{ .s = 1, .a = 5, .b = 5 }, // by weapon rarity, 1..5
        .psyche = .{ .s = 0, .a = 6 },                // by character rarity, 0..6
    },
    .characters = .{ .{ .id = 1504, .psyche = 2 } },     // per-character overrides
    .weapons = .{ .{ .id = 12051001, .refine = 3 } },    // per-weapon overrides
}
```

The defaults above (S rank weapons R1, A/B R5; S rank characters P0, A P6) also apply when the file is missing or invalid. The levels are not saved to the account, so any value can be changed back. Out-of-range values are clamped and unknown ids are ignored, each with a warning in the scene server's log; a successful load logs `applied sandbox.zon`. Use `--sandbox-file <path>` on the scene server to keep the file elsewhere.

The scene server also writes the active team's build (characters, weapon and refine, gear, catalysts) to `bloom/loadout.json` whenever it changes. The dir server serves it, and Bloom attaches it to each damage log.

## Client setup
Use the companion client patch, [analytics-bloom](https://github.com/alliegatah/analytics-bloom) (also forked from xeon's Bloom); its README covers installing it into the game client.

## Contributing
Contributions to this fork are welcome as patches or pull requests against this repository.

## License
This repository was made public in the hopes that it will be useful. However, it comes with no warranty whatsoever (expressed or implied).
It's licensed under [GNU Affero General Public License v3](LICENSE).

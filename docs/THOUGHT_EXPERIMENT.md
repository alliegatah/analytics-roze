# Thought Experiment / Abyss (CBT2 0.10.82.1)

The server implements the six Abyss request/response pairs: info, enter,
enter-already, progress update, finish and star award. Agenda's City Records
query is also registered, so both of its initialization dependencies reply.

## Sandbox behavior

- The bag includes one of each of the 17 regular reactor catalysts from
  `P_GemTable`. Ashley (Cinderella), Cynthia II and Rex have no psyche points
  (P0); other playable characters keep their fully unlocked psyche settings.
  These settings are generated from the source tables and apply to existing
  profiles on their next inventory/psyche query.
- Modes 1000 (Ongoing Project), 2000 and 3000 (Brainstorm) are available.
  The two September CBT2 rotations deliberately stay open; no calendar reset
  runs and rewards do not refresh. The advertised window is Unix seconds
  1 through 4294967295. Original schedules remain in the analysis exports.
- All 18 configured layers across the three modes are selectable immediately,
  including on existing profiles. The client uses `is_passed` as its next-layer
  gate, so info replies set that flag for every layer. Actual saved clears,
  times, stars and reward balances still come from play; unlocking grants none.
- City Records reports all seven stages and 42 objectives complete and already
  rewarded. This is a sandbox query response, not a new City Records quest or
  reward engine.
- Room teams can be queried, edited and activated independently of ordinary
  teams. A character cannot be in both room teams of one layer. Temporary team
  type 5 uses the room table ID as `TeamSrc.src`, with `src_ext = 0`.
  Entering a run activates the selected first-side team on the server and sends
  the entry acknowledgement to start map travel. The destination receives the
  team through its normal `SC_CHARACTER_TEAMS` initialization reply. Sending a
  live team notification before travel can start native character assembly in
  the departing scene; the initial entry must not use that path.
  Successful room progress sends its
  acknowledgement followed by `SC_CHARACTER_TEMP_TEAM_NTF` for the next side;
  that notification lets the client assemble the new characters and end its
  loading transition. No additional Abyss-enter request is needed between sides.
  Empty selected teams are rejected without advancing the attempt.
  Type 0 restores the ordinary team.
- Reactor assignments are saved per ordinary team and per Abyss room team.
  Both full-team updates and `CS_TMP_TEAM_UPDATE_GEM_REQ` accept catalyst slots;
  queries, activation, entry and side-change notifications return all three
  slots for every selected character. Nonempty slots return `VALID` (the 17
  CBT2 regular catalysts have no elemental composition requirements).
  The server validates known item IDs, unique catalysts within a team, slot
  bounds and the 14-point power limit. Per-character incremental costs are
  1, 2 and 4. Empty gem IDs remove equipment. A gem-only update cannot replace
  characters. Responses must fit before new assignments are committed.

## Progress and rewards

Enter requests use the layer **index** and one-based room **index**. These are
not layer row IDs or room table IDs. Rooms complete in order, and later rooms
cannot be entered without the preceding room's saved progress.

Progress messages store per-room milliseconds. The server checks submitted
task IDs against the layer's configured tasks and compares the attempt's total
room time with each task's `CostTime` in seconds. It retains each layer's best
star count and marks a successful zero-star run as passed. Losing, giving up
or replaying clears the attempt without replacing a previous best result.
Exact duplicate room-progress reports are harmless; changed duplicate reports,
duplicate tasks, unknown IDs and out-of-order progress are rejected.

Star claims collect every newly reached milestone once. The importer resolves
`P_AbyssRewardTable.Drop` against `S_DropTable` and verifies that these drops
are guaranteed (`Odds = 10000`, `Weight = 0`). The implementation does not
grant display-only `RewardShow` strings. Claimed thresholds and reward-item
balances are saved together. Bag notifications contain final balances, while
the claim response contains the granted deltas. These balances are included
in subsequent bag queries. Spending ordinary items remains outside the existing
sandbox inventory implementation.

The server accepts client-reported combat completion/times, as the existing
emulator does; it does not independently simulate or verify combat.

## Saved data and reconnect

Save version 5 appends Abyss state and room teams after the version 4 fields.
Version 6 appends catalyst assignments for ordinary and Abyss room teams.
Existing save files migrate automatically on login, retaining equipment,
characters and world data. Active mode/layer/room, completed room times,
per-layer bests, claimed milestones, reward balances, room teams and catalyst
assignments persist.
The generic dungeon reconnect reply returns `EST_ABYSS` and an `AbyssCurrentData`
snapshot while an Abyss attempt is active. Ordinary dungeon entry is rejected
until that attempt is finished or abandoned.
Loading a saved attempt also restores its current room team and active slot,
so reconnecting on the second side does not select the overworld team.

Save layout is specific to the embedded CBT2 table inventory. Adding or reordering
modes, layers, rooms or reward items requires a new save migration.

## Build and run

Validated with Zig 0.17.1 (see the README for download links). From the
repository folder:

```powershell
zig build test
zig build
.\zig-out\bin\roze-scene-server.exe --concurrency 1
```

Restart an existing scene-server process to load the rebuilt executable. The
directory and SDK services remain necessary for normal game login.

Tests cover dispatch/encoded replies for both Agenda queries, entry validation,
reconnect data, settlement, milestone claims, inventory updates, duplicate
claim prevention, temporary teams, save migration/serialization and response
buffer rollback. Two-side tests check selected-team activation, notification
ordering, duplicate progress, both victories, settlement and ordinary-team
restoration. Reactor tests cover equip/unequip, encoded gem replies, room entry,
side switching, malformed assignments, power limits and save migration.
Isolated scene-server socket checks also exercise reconnect and process-restart
persistence, including migration from an actual version 5 file.
Scene-server tests also cover TCP frames split at every header
and body boundary, header-only frames, and complete frames followed by a partial
frame. Incomplete frames schedule another read after queued replies are sent,
preventing a receive-loop stall that previously stopped replies to all clients.
Protobuf tests cover ten-byte signed `int32`/`int64` values, full-width `uint64`
IDs and malformed varints. Battle victory tests include negative end-position
coordinates: the previous decoder rejected these with `VarIntOverflow`, closing
the session before it could acknowledge `CS_LEAVE_BATTLE`.
A running game client is still needed to verify UI, map
transitions and complete battles end to end. Hilbert's Hotel / Wanted Poster
is a separate feature and is not implemented by this change.

The proposed SS2 practice-room changes and client-side requirements are recorded
in [SS2_TRAINING_ROOM.md](SS2_TRAINING_ROOM.md); combat asset changes are not yet implemented.

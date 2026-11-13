# SS2 training room (CBT2 0.10.82.1)

Status: implemented in Bloom (client) and Roze (settings); the boss was
confirmed working in a live run on 2026-11-12.

## Requested behavior

Turn the first, level-19 Thought Experiment room into a practice encounter:
one floor-10 boss, maximum configured enemy level, no Dream Enhancer,
zero elemental resistance and approximately 1000 times its normal HP.
"SS2" is the user's label for this room, not a server mode identifier.

## How it works

The client decides the encounter. `s_CSM_D_AbyssGamplaySystem:UpdateDungeonInfo`
builds a battle description and passes it to
`s_CSM_D_DungeonProcessSystem:UpdateDungeonInfo`, which stores it as
`DungeonInfo`. `s_CSM_D_DungeonProcessState_Enter:DungeonEnterBattle` then
copies these fields into the override parameters of the native `StartBattle`:

| Field | Source in the Abyss system | Native use |
|---|---|---|
| BattleFieldID | battle row | spawn group (`SpawnDeviceGroupKey`) |
| BattleAreaID | battle row | arena |
| MonsterLevel | room `MonsterLevelID` | `OverrideMonsterLevel` |
| MonsterAttributeScaleID | room `AttributeID` | stat scale row |
| MonsterAttributeRateMap | empty `UE.TMap(0, 0)` | `TMap<ESPAttributeType, int32>` |
| AffixID | room `AffixID` (or 0) | `AddBattleFieldAffix` |
| LimitTime | `GetAbyssBattleTime()` | battle timer |

Bloom (`bloom/src/lua.zig`) hooks the client's `luaL_loadbufferx` and wraps
those two modules as they load. `bloom/src/lua/bloom.lua` then patches them:
at the start of each Abyss battle it fetches
`GET http://127.0.0.1:30002/bloom/training_room.lua` from the Roze dir server
and, if the current room is listed there, edits the battle description before
it is stored. `BattleID` is not changed, so Roze still records progress for the
original room. Every other room, and every room when the file cannot be
fetched, keeps its original battle.

The settings live in `roze/bloom/training_room.lua`. Roze re-reads it on every
request (`--bloom-dir` changes the directory), so edits apply the next time the
room is entered or retried, without restarting Roze or the game.

Each applied override is logged to the Bloom console and
`Binaries/Win64/bloom.log`, with the configuration revision and the before and
after values.

## Default settings

| Setting | Value | Effect |
|---|---|---|
| rooms | abyss 1000, layer 1, room 1 | first side of layer 1 |
| battle_id | 203002101 | floor 10 side 1 spawn group (`NormalAbyss_10-1`), Soulless Lord |
| monster_level | 120 | level row 120, all level slots 120 (the maximum) |
| attribute_scale_id | 2050 | floor-10 scaling: MAXHP x0.8686, ATK x1.2 |
| affix_id | 0 | no battlefield affix, so no Dream Enhancer (ATK +20%) |
| time_limit | 3600 | 60-minute timer instead of 180 seconds |
| full_ultimate_on_start | true | fill every selected character once at native battle start |
| MAXHP rate | 5,500,000 | 550x, see HP below |
| DEF_ElementDamage_Res rate | 0 | removes the boss's only resistance stat (5000) |

All three Thought Experiment layers in question use map 203001001001 and
battle area 2030010101, so only the spawn group changes.

### HP

Soulless Lord's base row (76001) has MAXHP 1920 and growth table 101, whose
level-120 MAXHP rate is 10,881,825 (x1088.18). With scale row 2050 that is
about 1.81 million HP. 1000x would be about 1.8 billion, above the MAXHP
maximum of 1,000,000,000 in the battle attribute tables (`s_battleattributetable`
and `p_insideattributetable`, attribute 101), so the default uses 550x
(about 998 million). The native row 1101 (AttributeID 1) uses 999,999,999 HP,
which suggests that is the intended practical ceiling.

### Rate map keys and units

The native `MonsterAttributeRateMap` property is `TMap<ESPAttributeType, int32>`.
This was read from its reflection data: the key is an enum property built from
`ESPAttributeType`, and the value is an int32. In `ESPAttributeType`, MAXHP is 1
and DEF_ElementDamage_Res is 292. These are not the in-battle attribute table
IDs (MAXHP is 101 there). `bloom.lua` resolves names through
`UE.ESPAttributeType` and falls back to a built-in table of the stats in
`MonsterAttributeScaleTable`; all 298 values are in
`analysis/0.10.82.1/esp_attribute_type_values.json`.

The value unit is assumed to match the scale table (10000 = 100%), and it is
not yet known whether the native code multiplies these rates with the scale
row or replaces the scale row's value. Only a live run can confirm this.

## Validation still needed in the game

1. One Soulless Lord spawns in layer 1 side 1, at level 120, with no other waves.
2. No Dream Enhancer effect (the layer's buff text still lists it).
3. HP is about 998 million (or note the real value, to settle the rate unit).
4. Elemental damage is not reduced compared with neutral damage.
5. The timer shows 60 minutes; leaving and retrying works.
6. Other layers and side 2 of layer 1 are unchanged.

If the boss does not change at all, check `bloom.log` for `wrapped ...` and
`patched ...` lines. With none, set `BLOOM_TRACE_LUA=1` to list the chunk
names the client loads.

## Known gaps

- The layer's buff description (`BuffDesc = [1880000166]`) still shows the
  Dream Enhancer; only the effect is removed.
- The floor-1 enemies that do not die are a separate behavior, unrelated to
  this override.

## Evidence

Read-only evidence is in the authors' local analysis workspace
(`analysis/0.10.82.1`, not part of this repository):

- `dummy_room_client_evidence.json` and `bloom_damage_client_evidence.json`:
  constants and instructions of the Abyss, DungeonProcessSystem and
  DungeonProcessState_Enter functions (bytecode, disassembled, not executed).
- `bloom_lua_api.json`, `bloom_unlua_loader.json`: `lua_load` (RVA 0x82B7EA0),
  `luaL_loadbufferx` (0x82BD610), its string reader (0x82BC880) and the UnLua
  call site (0x46BFF90) that loads modules with mode NULL.
- `tables/p_abyssroomtable.json`, `c_repeatabledungeonsbattletable.json`,
  `c_battlefieldsystemtable.json`, `dt_c_monsterfightattributetable.json`,
  `dt_c_monsterattrgrowthtable.json`, `dt_c_monsterattributescaletable.json`,
  `dt_c_monsterleveltable.json`.


### Starting ultimate resource

**Current approach (config revision 3): Roze, not Bloom.** `p_dungeonstypetable`
sets `CharacterHpRatio` and `CharacterPermanentLiquidRatio` to 10000 (100%) for
dungeon type 1, which Thought Experiment uses (`DungeonType = 1` in the Abyss
`UpdateDungeonInfo`). Roze used to resend the HP and ultimate saved at the last
battle exit instead, so gauges carried over between attempts. While a Thought
Experiment room team is active, every attribute packet for its members now sends
full HP and `PERMANENT_LIQUID = 1,000,000,000`, the attribute's table maximum:
`SC_CHARACTER_TEMP_TEAM_NTF` (entry, side change), `SC_SET_TMP_TEAM_RSP`, the
`SC_CHARACTER_TEAMS` reply the client requests after entry, team edits, and the
`SC_OUTSIDE_ATTRIB_NTF` sent after each battle. A first version changed only
the room-team packets; the live gauge still carried over (Firtho started at
21.8/75 both before and after), because the later packets resent the saved
values. Roze does
not compute `PERMANENT_LIQUID_MAX`; the client bounds the current gauge by each
character's maximum (seen in stat captures: Rose's gauge bounded at 750000,
i.e. 75). The saved snapshot is left unchanged and still applies to the
ordinary team. `full_ultimate_on_start` is now `false`.

The client-side refill below is kept for reference. It failed in three live
runs and is off.


Config revision 2 enables `full_ultimate_on_start = true`. Bloom runtime v2 fills
all members of the selected team, including off-field characters, once after
team creation and native battlefield start. Each uses their own maximum through
the game's `SetCharacterPermanentLiquidPercentage(inst_id, 10000)` setter.

This runs on entry and retry, and on subsequent sides if added to `rooms`.
The default still targets only layer 1 side 1. Set the option to `false`, or
omit it, to keep normal carryover. Config edits apply on the next attempt.
Duplicate start notifications cannot refill a gauge spent during the battle.

Roze's existing saved battle resources explain the inconsistent starting gauges:
it saves `permanent_liquid` on exit and restores it for temporary teams. The
training grant uses the normal client resource setter; the resulting resource
can also be saved in a later battle-exit snapshot.

The log reports `training: ultimate inst_id=... before -> after (max ...)`, then
`training: ultimate start refill: N filled, N failed`. Setter errors are logged
and the original battle start still runs.

The first live run (runtime v2) failed for all four characters with
`s_BattleAttribute_MainData.lua:657: bad argument #1 to 'for iterator'`. The
shipped `GetPlayerOverrideAttributeList_Part` checks the character-id keyed
`C_CharacterPawnIDTable` with the instance id, so it returns `{}` and the
forwarder iterates a missing `InitDatas`. Runtime v3 wraps that helper on the
MainData instance for the one setter call only, building the descriptor from
the correctly keyed full getter and keeping only the requested resource
attributes; the original slot is restored afterwards, even on error.

The second live run (runtime v3) then failed with "requested resource attribute
unavailable: 1150". The setter requests PERMANENT_LIQUID (1150, the current
gauge) and PERMANENT_LIQUID_MAX (1151), but the attribute collector behind the
full getter has no entry for 1150: it is state, not a computed stat. Runtime v4
fills 1150 from CharacterData's current value, which the setter has already
set to the maximum, as a plain base value (add and multi 0), the same shape
Roze uses for the starting gauge.

The Lua 5.4 harness (35 checks) mirrors the shipped forwarder and getter
bytecode and the live attribute set, and fails without either workaround in the
same way the game did. Full gauges still need confirmation in the game.
See Bloom's `docs/EFFECTIVE_STATS.txt` for evidence and the call chain.

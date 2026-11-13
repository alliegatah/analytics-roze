-- Training-room settings, served to the Bloom client patch at
-- GET http://127.0.0.1:30002/bloom/training_room.lua
--
-- Roze re-reads this file on every request and Bloom fetches it at the start of
-- every battle in a Thought Experiment room. Edits apply the next time you enter
-- or retry the room; restarting Roze or the game is not needed.
-- Settings stay fixed for the length of a battle.
--
-- Leave out a setting to keep that room's original value.

return {
  -- Printed in the Bloom log with each applied override, to identify test runs.
  revision = 4,
  enabled = true,

  -- Rooms that become the training room. room = side number (1 or 2); omit it
  -- to match every side of the layer.
  rooms = {
    { abyss_id = 1000, layer = 1, room = 1 }, -- Thought Experiment, layer 1 (level 19)
  },

  -- Client-side ultimate refill. Off: it cannot work in this client build (the
  -- game's resource forwarder never receives the gauge values), and it is no
  -- longer needed because Roze now starts every Thought Experiment team at full
  -- HP and ultimate, as p_dungeonstypetable specifies.
  full_ultimate_on_start = false,

  -- Encounter, as a RepeatableDungeonsBattleTable row. Its BattleFieldID chooses
  -- the spawn group; all Thought Experiment layers share the same map and area.
  --   203002011  layer 1   Street Punkster (original)
  --   203002101  layer 10, side 1  Soulless Lord
  --   203002102  layer 10, side 2  "Manager" & "Supervisor"
  battle_id = 203002101,

  -- MonsterLevelTable row. 120 is the highest; it sets every level slot to 120.
  monster_level = 120,

  -- MonsterAttributeScaleTable row (10000 = 100%). 2050 is the floor-10 row:
  -- MAXHP x0.8686, ATK x1.2. The layer-1 row (2041) is MAXHP x2, ATK x0.6.
  attribute_scale_id = 2050,

  -- Battlefield affix. 0 removes the room's affix 1002, which is the Dream
  -- Enhancer (all characters ATK +20%). The layer's buff text still shows it.
  affix_id = 0,

  -- Battle time limit in seconds. 180 matches the original room and the
  -- 3-minute battles analytics.moe compares; raise it for open-ended testing.
  time_limit = 180,

  -- Extra per-attribute rates sent in the battle's MonsterAttributeRateMap.
  -- Keys are ESPAttributeType names (or their numeric values); 10000 = 100%.
  -- How the game combines these with the scale row has not been confirmed in a
  -- live run yet; check the boss HP and the Bloom log after changing them.
  attribute_rates = {
    -- Soulless Lord at level 120 with scale 2050 has about 1.81 million HP.
    -- 1000x would be about 1.8 billion, above the 999,999,999 MAXHP cap, so
    -- this uses 550x (about 998 million).
    MAXHP = 5500000,
    -- Soulless Lord's only resistance stat (5000 in its base row).
    DEF_ElementDamage_Res = 0,
  },
}

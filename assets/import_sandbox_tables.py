"""Generates the `s_*.zon` sandbox tables in `assets/tables/` from exported game tables.

Usage: python import_sandbox_tables.py <export>...

Every <export> is a directory or a .zip of exported tables (`<table name>.json` files,
anywhere inside). A table is taken from the first export that has it.

Levels, break levels and talents are at their maximum, so instead of shipping the
level/scale tables and evaluating them at runtime, this script evaluates them once and
writes down their attribute contributions. Weapon refine and psyche (constellation) levels
are chosen at runtime from `sandbox.zon` (see `src/sandbox.zig`), so their contributions
are written for every level.

Units follow what `packCharacterAttribData` already does for the character's own attributes:
  * flat attributes (MAXHP, ATK, DEF): `table value * permyriad scale`, not divided back;
  * rate attributes (crit, damage bonuses, ...): permyriad.
"""
import json
import os
import sys
import zipfile

PERMYRIAD = 10000


# Name used by the game tables -> (attrib_type as in `Gameplay.Attr`, bucket, is flat).
ATTRS = {
    'MAXHP': (101, 'base', True),
    'ATK': (102, 'base', True),
    'DEF': (103, 'base', True),
    'MAXHP_Add': (101, 'add', True),
    'ATK_Add': (102, 'add', True),
    'DEF_Add': (103, 'add', True),
    'MAXHP_Multi': (101, 'multi', False),
    'ATK_Multi': (102, 'multi', False),
    'DEF_Multi': (103, 'multi', False),
    'ATK_CriticalChance': (104, 'add', False),
    'ATK_CriticalDamage': (105, 'add', False),
    'ATK_Heal_Add_Rate': (108, 'add', False),
    'ATK_Damage_Add_Rate': (301, 'add', False),
    'ATK_BasicAttackDamage_Add_Rate': (331, 'add', False),
    'ATK_FireDamage_Add_Rate': (311, 'add', False),
    'ATK_IceDamage_Add_Rate': (313, 'add', False),
    'ATK_ThunderDamage_Add_Rate': (315, 'add', False),
    'ATK_GravityDamage_Add_Rate': (317, 'add', False),
    'ATK_RadiationDamage_Add_Rate': (319, 'add', False),
    'ATK_SilverDamage_Add_Rate': (327, 'add', False),
    'ATK_BlackIronDamage_Add_Rate': (329, 'add', False),
    'Liquid_AbsorbRate': (1149, 'add', False),
    'ATK_Pursue_BreakDEF': (1164, 'add', False),
    'ATK_Abn_CriticalChance': (1204, 'add', False),
    'ATK_Abn_CriticalDamage': (1205, 'add', False),
    'ATK_NonBreakDamage': (1207, 'add', False),
}

# Attributes the tables use but whose attrib_type number we don't know. Counted and reported.
unknown_attrs = {}


class Bonuses:
    def __init__(self):
        self.values = {}  # attrib_type -> [base, multi, add]

    def add(self, name, value, scale=PERMYRIAD):
        """`value` as written in the table, `scale` the permyriad multiplier that applies to it."""
        if not name or not value:
            return
        if name not in ATTRS:
            unknown_attrs[name] = unknown_attrs.get(name, 0) + 1
            return
        attr, bucket, flat = ATTRS[name]
        amount = value * scale if flat else value * scale // PERMYRIAD
        slot = self.values.setdefault(attr, [0, 0, 0])
        slot[('base', 'multi', 'add').index(bucket)] += amount

    def zon(self):
        parts = []
        for attr in sorted(self.values):
            base, multi, add = self.values[attr]
            fields = ['.attr = %d' % attr]
            if base: fields.append('.base = %d' % base)
            if multi: fields.append('.multi = %d' % multi)
            if add: fields.append('.add = %d' % add)
            parts.append('.{ ' + ', '.join(fields) + ' }')
        return '.{' + ', '.join(parts) + '}'


def zon_list(values):
    return '.{' + ', '.join(str(v) for v in values) + '}'


def import_abyss(write, load):
    """Keep runtime progression and guaranteed star drops tied to the source tables."""
    layers = load('p_abysslayertable')
    tasks = {row['ID']: row for row in load('p_abysstargettasktable')}
    rewards = load('p_abyssrewardtable')
    drops = load('s_droptable')
    reward_items = set()
    modes = []
    for mode in load('p_abysstable'):
        own_layers = []
        for layer in sorted((x for x in layers if x['AbyssID'] == mode['ID']), key=lambda x: x['LayerIndex']):
            assert len(layer['RoomID']) <= 3 and len(layer['TargetTasks']) <= 3
            assert all(tasks[x]['TaskType'] == 1 for x in layer['TargetTasks'])
            own_layers.append('.{ .index = %d, .rooms = %s, .tasks = %s, .task_seconds = %s }' % (
                layer['LayerIndex'], zon_list(layer['RoomID']), zon_list(layer['TargetTasks']),
                zon_list(tasks[x]['CostTime'] for x in layer['TargetTasks'])))
        own_rewards = []
        for reward in sorted((x for x in rewards if x['AbyssID'] == mode['ID']), key=lambda x: x['Star']):
            items = [x for x in drops if x['DropID'] == reward['Drop']]
            assert items and all(x['Odds'] == 10000 and x['Weight'] == 0 for x in items), reward
            reward_items.update(x['ItemID'] for x in items)
            own_rewards.append('.{ .star = %d, .items = .{%s} }' % (reward['Star'], ', '.join(
                '.{ .id = %d, .count = %d }' % (x['ItemID'], x['ItemCount']) for x in items)))
        modes.append('.{ .id = %d, .layers = .{%s}, .rewards = .{%s} }' % (
            mode['ID'], ', '.join(own_layers), ', '.join(own_rewards)))
    write('s_abysstable', modes)
    write('s_abyssrewarditemtable', [str(x) for x in sorted(reward_items)])


def main():
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tables')

    # table name -> how to read it
    index = {}
    for export in sys.argv[1:]:
        if export.lower().endswith('.zip'):
            archive = zipfile.ZipFile(export)
            for member in archive.namelist():
                if member.endswith('.json'):
                    name = os.path.basename(member)[:-len('.json')]
                    index.setdefault(name, lambda a=archive, m=member: json.loads(a.read(m).decode('utf-8')))
        else:
            for root, _, files in os.walk(export):
                for file in files:
                    if file.endswith('.json'):
                        path = os.path.join(root, file)
                        index.setdefault(file[:-len('.json')], lambda p=path: json.load(open(p, encoding='utf-8')))

    def load(name):
        if name not in index:
            sys.exit('table %s is in none of the exports' % name)
        return index[name]()

    source = load

    # Make sure the attribute numbers above are the game's. This table only names the
    # attributes that exist inside a battle, the rest can't be checked.
    attr_ids = {r['Attr_Enum']: r['ID'] for r in load('p_insideattributetable')}
    attr_names = {r['ID']: r['Attr_Enum'] for r in load('p_insideattributetable')}
    for name, (attr, bucket, _) in ATTRS.items():
        # `X_Add` and `X_Multi` are the flat and percentage increases of attribute `X`.
        attr_name = name[:-len('_' + bucket.capitalize())] if bucket in ('add', 'multi') and name.endswith(('_Add', '_Multi')) else name
        if attr_ids.get(attr_name, attr) != attr or attr_names.get(attr, attr_name) != attr_name:
            sys.exit('attribute %s: attrib_type %s is %s in the game, which has %s at %s' % (
                name, attr, attr_names.get(attr), attr_name, attr_ids.get(attr_name)))

    def write(name, rows):
        with open(os.path.join(out_dir, name + '.zon'), 'w', encoding='utf-8', newline='\n') as f:
            f.write('.{\n')
            for row in rows:
                f.write('    ' + row + ',\n')
            f.write('}\n')
        print('%-28s %d rows' % (name, len(rows)))

    # --- weapons ("motives"), all at the highest level and break level. The substat
    # depends on the refine, which `sandbox.zon` picks, so it is written for every refine.
    motive_level = max(source('p_motiveleveltemplatetable'), key=lambda r: (r['Level'], r['BreakLevel']))
    refine_rows = {}
    for r in source('p_motiverefinetemplatetable'):
        refine_rows.setdefault(r['TemplateID'], {})[r['RefineLevel']] = r
    motive_rows = {r['ID']: r for r in source('p_motivetable')}

    motives = []
    for weapon in load('weapons_with_items'):
        row = motive_rows[weapon['weapon_id']]
        refines = refine_rows[row['RefineTemplateID']]
        assert sorted(refines) == list(range(1, len(refines) + 1)), refines.keys()
        base = Bonuses()
        base.add('MAXHP', row['MAXHP'], motive_level['Scale_MAXHP'])
        base.add('ATK', row['ATK'], motive_level['Scale_ATK'])
        per_refine = []
        for level in sorted(refines):
            sub = Bonuses()
            for name, value in zip(row['SubAttributeType'], row['SubAttributeValue']):
                sub.add(name, value, refines[level]['SubAttributeScale'])
            per_refine.append(sub.zon())
        motives.append((weapon['weapon_id'],
            '.{ .id = %d, .item_id = %d, .identity_type = %d, .rarity = %d, .level = %d, .break_level = %d, '
            '.base_bonuses = %s, .refine_bonuses = .{%s} }' % (
                weapon['weapon_id'], weapon['item_id'], row['Identity'], row['Rare'],
                motive_level['Level'], motive_level['BreakLevel'], base.zon(), ', '.join(per_refine))))
    motive_ids = [m[0] for m in motives]
    write('s_motivetable', [m[1] for m in motives])

    # --- gear: every core ("main") piece, and the best tier of the set ("sub") pieces
    gear = {g['gear_id']: g for g in load('equipment')}
    main_refine = {(r['RefineID'], r['SubAttributeLevel']): r['SubAttributeScale']
                   for r in source('p_mainequipmentrefinetable')}
    sub_groups = {r['ID']: r for r in source('p_subequipmentattrgrouptable')}
    sub_scale = {(r['ScaleID'], r['Rare'], r['EquipmentLevel']): r['AttributeScale']
                 for r in source('p_subequipmentattrscaletable')}

    equipment = []
    for row in source('p_mainequipmenttable'):
        info = gear[row['ID']]
        refine_levels = info['example_maxed_refine_level_array']
        bonuses = Bonuses()
        bonuses.add(row['MainAttributeType1'], row['MainAttributeValue1'])
        bonuses.add(row['MainAttributeType2'], row['MainAttributeValue2'])
        for i in range(3):
            scale = main_refine[(row['SubAttributeRefineID'][i], refine_levels[i])]
            bonuses.add(row['SubAttributeType%d' % (i + 1)], row['SubAttributeBaseValue%d' % (i + 1)], scale)
        bonuses.add(row['AffixAttributeType'], row['AffixAttributeValue'])
        equipment.append((row['ID'], info['slot'], refine_levels, bonuses))

    sub_rows = source('p_subequipmenttable')
    best_level = max(r['EquipmentLevel'] for r in sub_rows)
    best_rare = max(gear[r['ID']]['rare'] for r in sub_rows if r['EquipmentLevel'] == best_level)
    for row in sub_rows:
        info = gear[row['ID']]
        if row['EquipmentLevel'] != best_level or info['rare'] != best_rare:
            continue
        group = sub_groups[row['AttributeGroupID']]
        bonuses = Bonuses()
        # Not every group fills all of its attribute columns.
        for i, scale_id in enumerate(group['MainAttributeScaleID']):
            scale = sub_scale[(scale_id, info['rare'], row['EquipmentLevel'])]
            bonuses.add(group['MainAttributeType%d' % (i + 1)], group['MainAttributeValue%d' % (i + 1)], scale)
        for i, scale_id in enumerate(group['SubAttributeScaleID']):
            scale = sub_scale[(scale_id, info['rare'], row['EquipmentLevel'])]
            bonuses.add(group['SubAttributeType%d' % (i + 1)], group['SubAttributeBaseValue%d' % (i + 1)], scale)
        equipment.append((row['ID'], row['Slot'], [], bonuses))

    equipment_ids = [e[0] for e in equipment]
    write('s_equipmenttable', [
        '.{ .id = %d, .slot = %d, .refine_levels = %s, .bonuses = %s }' % (gid, slot, zon_list(refine), bonuses.zon())
        for gid, slot, refine, bonuses in equipment])

    # --- per character growth: talents, constellations and the default loadout
    talents = {}
    for t in load('talents'):
        talents.setdefault(t['character_id'], []).append(t)
    talent_attrs = {}
    for r in source('p_talentattributecontenttable'):
        talent_attrs.setdefault(r['CharacterID'], []).append(r)
    constellations = {c['character_id']: c['point_ids'] for c in load('constellations')}
    constellation_attrs = {}
    for r in source('p_constellationtable'):
        constellation_attrs.setdefault(r['CharacterID'], []).append(r)

    # The trial character presets tell which weapon and core gear the designers pair a
    # character with. Preset ids start with the character id.
    preset_motives = {}
    for r in source('p_tmpmotivetable'):
        if r['MotiveID'] in motive_ids:
            preset_motives.setdefault(r['ID'] // 100000, set()).add(r['MotiveID'])
    preset_gear = {}
    for r in source('p_tmpmainequipmenttable'):
        if r['EquipmentID'] in equipment_ids:
            preset_gear.setdefault(r['ID'] // 10000, set()).add(r['EquipmentID'])

    rarity = {r['ID']: r['Rare_Type'] for r in source('p_charactertable')}

    growth = []
    for character_id in sorted(talents):
        talent_bonuses = Bonuses()
        for r in talent_attrs.get(character_id, []):
            talent_bonuses.add(r['AttributeType'], r['AttributeValue'])
        # Psyche (constellation) points in activation order; `sandbox.zon` picks how many.
        points = constellations.get(character_id, [])
        rows = {r['Point']: r for r in constellation_attrs.get(character_id, [])}
        per_point = []
        for point in points:
            bonuses = Bonuses()
            r = rows.get(point)
            for name, value in (zip(r['AttributeType'], r['AttributeValue']) if r else []):
                bonuses.add(name, value)
            per_point.append(bonuses.zon())
        nodes = ', '.join('.{ .id = %d, .level = %d }' % (t['node_id'], t['max_level'])
                          for t in sorted(talents[character_id], key=lambda t: t['node_id']))
        growth.append(
            '.{ .character_id = %d, .rarity = %d, .talent_nodes = .{%s}, .constellation_points = %s, '
            '.preferred_motives = %s, .preferred_equipment = %s, .talent_bonuses = %s, '
            '.constellation_bonuses = .{%s} }' % (
                character_id, rarity[character_id], nodes, zon_list(points),
                zon_list(sorted(preset_motives.get(character_id, []))),
                # Best (highest tier) preset first.
                zon_list(sorted(preset_gear.get(character_id, []), reverse=True)),
                talent_bonuses.zon(), ', '.join(per_point)))
    write('s_charactergrowthtable', growth)

    # --- the rest are plain id lists
    write('s_silvercreaturetable', ['.{ .id = %d, .level = %d }' % (c['silver_creature_id'], c['base_level'])
                                    for c in load('silver_creatures')])
    write('s_dungeongrouptable', [str(g['group_id']) for g in load('dungeon_groups')])
    # ShowType 18 is "wind road" (the Circuitways).
    write('s_windroaditemtable', [str(i['item_id']) for i in load('items') if i['show_type'] == 18])
    # Regular catalysts use ordinary bag items (one copy is their hold limit).
    item_ids = {i['item_id'] for i in load('items')}
    catalysts = [g['ID'] for g in load('p_gemtable')]
    assert len(catalysts) == len(set(catalysts)) and set(catalysts) <= item_ids
    write('s_catalysttable', [str(g) for g in catalysts])

    # --- city NPCs that are monsters in disguise: sub region -> NPC group -> weighted battles
    expose = {}
    for row in load('city_battle_pools'):
        groups = expose.setdefault(row['subregion_id'], {})
        groups.setdefault(row['npc_group_id'], []).append((row['enter_battle_id'], row['weight']))
    write('s_exposetable', [
        '.{ .sub_region_id = %d, .groups = .{%s} }' % (sub_region_id, ', '.join(
            '.{ .id = %d, .battles = .{%s} }' % (group_id, ', '.join(
                '.{ .id = %d, .weight = %d }' % battle for battle in battles))
            for group_id, battles in groups.items()))
        for sub_region_id, groups in expose.items()])

    # --- shops. The ones whose goods groups don't resolve are kept, empty.
    stock = {}
    for row in load('shop_stock'):
        stock.setdefault(row['shop_id'], []).append(row)
    write('s_shoptable', [
        '.{ .id = %d, .goods = .{%s} }' % (shop['ID'], ', '.join(
            '.{ .id = %d, .money_id = %d, .money_num = %d }' % (g['goods_id'], g['cost_item_id'], g['cost_num'])
            for g in sorted(stock.get(shop['ID'], []), key=lambda g: g['priority'])))
        for shop in load('p_shoptable')])

    # --- the highest account ("team") level and world level the game defines
    caps = {'team_level': max(r['ID'] for r in load('p_teamleveltable')),
            'world_level': max(r['ID'] for r in load('p_worldleveltable'))}
    with open(os.path.join(out_dir, 's_levelcap.zon'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('.{ .team_level = %(team_level)d, .world_level = %(world_level)d }\n' % caps)
    print('%-28s %s' % ('s_levelcap', caps))

    # --- Thought Experiment ("abyss"): mode -> layers -> rooms, and the tasks that award stars
    import_abyss(write, load)

    # --- City Records ("newbie"): the stages and their objectives
    write('s_newbiestagetable', [str(r['ID']) for r in load('p_newbiestagetable')])
    write('s_newbietable', ['.{ .id = %d, .need_count = %d }' % (r['ID'], r['NeedCount'])
                            for r in load('p_newbietable')])

    # --- everything that can be unlocked by progressing
    write('s_unlockconditiontable', [str(r['ID']) for r in load('p_unlockconditiontable')])

    if unknown_attrs:
        print('attributes left out (attrib_type unknown): %s' % unknown_attrs)


if __name__ == '__main__':
    main()

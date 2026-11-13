//! Computes the attributes of a character from everything it has: its own level,
//! the weapon it holds, the gear it wears, its talents and constellations.

const std = @import("std");
const mem = std.mem;

const roze = @import("roze.zig");
const assets = roze.assets;
const Gameplay = roze.Gameplay;
const Attr = Gameplay.Attr;

pub const Sheet = struct {
    /// Indexed by position of the attribute in `Attr`, see `slotOf`.
    values: [Attr.count]Value,

    pub const Value = struct {
        /// Sum of the base values of all sources.
        base: i32 = 0,
        /// Sum of the percentage increases of all sources, permyriad.
        multi: i32 = 0,
        /// Sum of the flat increases of all sources.
        add: i32 = 0,
    };

    pub const empty: Sheet = .{ .values = @splat(.{}) };

    pub fn get(sheet: *const Sheet, attr: Attr) Value {
        return sheet.values[slotOf(attr)];
    }

    /// The value the attribute ends up at.
    pub fn total(sheet: *const Sheet, attr: Attr) i32 {
        const value = sheet.get(attr);
        const scaled = @divTrunc(@as(i64, value.base) * (10000 + @as(i64, value.multi)), 10000);
        return @intCast(std.math.clamp(scaled + value.add, 0, std.math.maxInt(i32)));
    }

    fn apply(sheet: *Sheet, bonuses: []const assets.tables.S_AttributeBonus) void {
        for (bonuses) |bonus| {
            // The tables are generated against `Attr`, an unknown number means they're out of sync.
            const attr = std.enums.fromInt(Attr, bonus.attr) orelse continue;
            const value = &sheet.values[slotOf(attr)];
            value.base +|= bonus.base;
            value.multi +|= bonus.multi;
            value.add +|= bonus.add;
        }
    }
};

pub fn slotOf(attr: Attr) usize {
    return mem.findScalar(Attr, std.enums.values(Attr), attr).?;
}

pub fn compute(
    asset_index: *const assets.Index,
    gameplay: *const Gameplay,
    index: Gameplay.Character.Index,
) Sheet {
    var sheet: Sheet = .empty;

    const bits = gameplay.character.bits[index.toInt()];
    const dev_attributes = asset_index.getDevelopAttributes(index);

    inline for (@typeInfo(assets.tables.P_DevelopAttribute).@"struct".field_names[1..]) |attr_name| {
        const attr = @field(Attr, attr_name);
        var base_value = @field(dev_attributes, attr_name);

        switch (attr) {
            .maxhp => base_value *= assets.getScaleForLevel(.scale_maxhp, bits.level, bits.break_level),
            .atk => base_value *= assets.getScaleForLevel(.scale_atk, bits.level, bits.break_level),
            .def => base_value *= assets.getScaleForLevel(.scale_def, bits.level, bits.break_level),
            else => {},
        }

        sheet.values[slotOf(attr)].base = base_value;
    }

    const sandbox = &gameplay.transient.sandbox;
    if (gameplay.character.motives[index.toInt()].unwrap()) |motive| {
        sheet.apply(motive.config().base_bonuses);
        sheet.apply(sandbox.refineBonuses(motive));
    }

    for (gameplay.equipment.worn[index.toInt()]) |worn| {
        if (worn.unwrap()) |equipment| sheet.apply(equipment.config().bonuses);
    }

    if (asset_index.getCharacterGrowth(index)) |growth| {
        sheet.apply(growth.talent_bonuses);
        for (growth.constellation_bonuses[0..sandbox.psycheOf(growth)]) |bonuses| sheet.apply(bonuses);
    }

    return sheet;
}

/// The amount of HP the character has when it's at full health.
pub fn maxHp(
    asset_index: *const assets.Index,
    gameplay: *const Gameplay,
    index: Gameplay.Character.Index,
) i32 {
    return compute(asset_index, gameplay, index).total(.maxhp);
}

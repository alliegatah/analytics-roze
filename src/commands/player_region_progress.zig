const std = @import("std");
const ArrayList = std.ArrayList;

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;
const assets = roze.assets;

/// GUESS: we don't have a wind road ("Circuitway") table. The region sequences of this type
/// are the only entries we know of that could be them: their parameters are per sub region ids
/// that don't match any functional NPC. If the guess is wrong, the client is expected to
/// ignore ids it doesn't know, and this can go back to an empty list.
const wind_road_sequence_type = 9;

/// Every wind road we know (or rather, guess) of, grouped by sub region.
const unlocked_wind_roads: []const protobuf.gen.WindRoadData = unlocked_wind_roads: {
    @setEvalBranchQuota(100_000);

    const sub_regions = assets.tables.sub_region_config_read_target;
    var result: [sub_regions.len]protobuf.gen.WindRoadData = undefined;

    for (&result, sub_regions) |*data, sub_region| {
        // Sub region `100001RRRSSS` owns the sequences with ids `11RSxxxxxx`.
        const sequence_id_prefix = 1100 + (sub_region.id / 1000 % 1000) * 10 + sub_region.id % 1000;

        var ids: []const u64 = &.{};
        for (@typeInfo(assets.tables.region_sequence_sheets).@"struct".decl_names) |sheet_name| {
            for (@field(assets.tables.region_sequence_sheets, sheet_name)) |sequence| {
                if (sequence.type != wind_road_sequence_type) continue;
                if (sequence.id / 1_000_000 != sequence_id_prefix) continue;
                ids = ids ++ sequence.param_id;
            }
        }

        data.* = .{ .sub_region_id = sub_region.id, .wind_road_id = ids };
    }

    const final = result;
    break :unlocked_wind_roads &final;
};

pub fn CS_REQ_UNLOCKED_WIND_ROADS(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_RES_UNLOCKED_WIND_ROADS, @as(
        protobuf.gen.SC_Res_Unlocked_Wind_Roads,
        .{ .wind_roads = unlocked_wind_roads },
    ));
}

pub fn CS_REQ_REGION_PROGRESS(scope: *Scope) Scope.Error!void {
    var regions: [assets.tables.region.len]protobuf.gen.RegionProgress = undefined;
    var sub_region_buf: [assets.tables.sub_region_config_read_target.len]protobuf.gen.SubRegionProgress = undefined;
    var sub_region_list: ArrayList(protobuf.gen.SubRegionProgress) = .initBuffer(&sub_region_buf);

    const progress_entries_count = comptime count: {
        var count: usize = 0;
        for (@typeInfo(assets.tables.region_progress_sheets).@"struct".decl_names) |decl_name| {
            for (@field(assets.tables.region_progress_sheets, decl_name)) |sub_region_config| {
                count += sub_region_config.sequence_id.len;
            }
        }

        break :count count;
    };

    var progress_buf: [progress_entries_count]protobuf.gen.ProgressData = undefined;
    var progress_list: ArrayList(protobuf.gen.ProgressData) = .initBuffer(&progress_buf);

    for (&regions, assets.tables.region) |*region_progress, region_config| {
        const sub_regions = sub_region_list.addManyAsSliceAssumeCapacity(region_config.sub_region_id.len);
        var sub_region_i: usize = 0;

        for (assets.tables.sub_region_config_read_target) |sub_region_config| {
            if (sub_region_config.id / 1000 != region_config.id) continue;
            defer sub_region_i += 1;

            const progress_config = scope.asset_index.sub_region_progress.get(sub_region_config.id).?;
            const progress = progress_list.addManyAsSliceAssumeCapacity(progress_config.sequence_id.len);

            for (progress, progress_config.sequence_id) |*progress_data, sequence_id| {
                const sequence_config = scope.asset_index.sub_region_sequence.get(sequence_id).?;

                progress_data.* = .{
                    .sequence_id = sequence_id,
                    .count = sequence_config.param_num,
                };
            }

            sub_regions[sub_region_i] = .{
                .sub_region_id = sub_region_config.id,
                .progress = progress,
                .cur_progress = 100,
            };
        }

        region_progress.* = .{
            .region_id = region_config.id,
            .sub_region_progress = sub_regions,
        };
    }

    try scope.sink.send(.SC_RES_REGION_PROGRESS, @as(
        protobuf.gen.SC_Res_Region_Progress,
        .{
            .region_progress = &regions,
        },
    ));
}

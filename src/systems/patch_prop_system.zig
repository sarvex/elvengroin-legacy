const std = @import("std");
const math = std.math;
const flecs = @import("flecs");
const zm = @import("zmath");
const fd = @import("../flecs_data.zig");
const fr = @import("../flecs_relation.zig");
const IdLocal = @import("../variant.zig").IdLocal;
const world_patch_manager = @import("../worldpatch/world_patch_manager.zig");
const tides_math = @import("../core/math.zig");

const WorldLoaderData = struct {
    ent: flecs.EntityId = 0,
    pos_old: ?[3]f32 = null,
};

const Patch = struct {
    loaded: bool = false,
    entities: std.ArrayList(flecs.EntityId),
    lod: u32 = 1, // todo
    lookup: world_patch_manager.PatchLookup,
};

const SystemState = struct {
    flecs_sys: flecs.EntityId,
    allocator: std.mem.Allocator,
    flecs_world: *flecs.World,
    world_patch_mgr: *world_patch_manager.WorldPatchManager,

    cam_pos_old: ?[3]f32 = null,
    patches: std.ArrayList(Patch),
    loaders: [1]WorldLoaderData = .{.{}},
    requester_id: world_patch_manager.RequesterId,
    comp_query_loader: flecs.Query,
};

pub fn create(
    name: IdLocal,
    allocator: std.mem.Allocator,
    flecs_world: *flecs.World,
    world_patch_mgr: *world_patch_manager.WorldPatchManager,
) !*SystemState {
    var query_builder_loader = flecs.QueryBuilder.init(flecs_world.*);
    _ = query_builder_loader.with(fd.WorldLoader)
        .with(fd.Transform);
    const comp_query_loader = query_builder_loader.buildQuery();

    var system = allocator.create(SystemState) catch unreachable;
    var flecs_sys = flecs_world.newWrappedRunSystem(name.toCString(), .on_update, fd.NOCOMP, update, .{ .ctx = system });
    system.* = .{
        .flecs_sys = flecs_sys,
        .allocator = allocator,
        .flecs_world = flecs_world,
        .world_patch_mgr = world_patch_mgr,
        .comp_query_loader = comp_query_loader,
        .requester_id = world_patch_mgr.registerRequester(IdLocal.init("props")),
        .patches = std.ArrayList(Patch).initCapacity(allocator, 32 * 32) catch unreachable,
    };

    // flecs_world.observer(ObserverCallback, .on_set, system);

    // initStateData(system);
    return system;
}

pub fn destroy(system: *SystemState) void {
    system.comp_query_loader.deinit();
    system.patches.deinit();
    system.allocator.destroy(system);
}

fn update(iter: *flecs.Iterator(fd.NOCOMP)) void {
    var system = @ptrCast(*SystemState, @alignCast(@alignOf(SystemState), iter.iter.ctx));
    updateLoaders(system);
    updatePatches(system);
}

fn updateLoaders(system: *SystemState) void {
    var entity_iter = system.comp_query_loader.iterator(struct {
        WorldLoader: *fd.WorldLoader,
        transform: *fd.Transform,
    });

    var arena_state = std.heap.ArenaAllocator.init(system.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    while (entity_iter.next()) |comps| {
        var loader_comp = comps.WorldLoader;
        if (!loader_comp.props) {
            continue;
        }

        var loader = blk: {
            for (&system.loaders) |*loader| {
                if (loader.ent == entity_iter.entity().id) {
                    break :blk loader;
                }
            }

            // HACK
            system.loaders[0].ent = entity_iter.entity().id;
            break :blk &system.loaders[0];

            // unreachable;
        };

        const pos_new = comps.transform.getPos00();
        if (loader.pos_old) |pos_old| {
            if (tides_math.dist3_xz(pos_new, pos_old) < 32) {
                continue;
            }
        }

        const patch_type_id = system.world_patch_mgr.getPatchTypeId(IdLocal.init("props"));
        var lookups_old = std.ArrayList(world_patch_manager.PatchLookup).initCapacity(arena, 1024) catch unreachable;
        var lookups_new = std.ArrayList(world_patch_manager.PatchLookup).initCapacity(arena, 1024) catch unreachable;

        const lod = 1;
        const radius = 1024;
        if (loader.pos_old) |pos_old| {
            const area_old = world_patch_manager.RequestRectangle{
                .x = pos_old[0] - radius,
                .z = pos_old[2] - radius,
                .width = radius * 2,
                .height = radius * 2,
            };

            world_patch_manager.WorldPatchManager.getLookupsFromRectangle(patch_type_id, area_old, lod, &lookups_old);
        }

        const area_new = world_patch_manager.RequestRectangle{
            .x = pos_new[0] - radius,
            .z = pos_new[2] - radius,
            .width = radius * 2,
            .height = radius * 2,
        };

        world_patch_manager.WorldPatchManager.getLookupsFromRectangle(patch_type_id, area_new, lod, &lookups_new);

        var i_old: u32 = 0;
        blk: while (i_old < lookups_old.items.len) {
            var i_new: u32 = 0;
            while (i_new < lookups_new.items.len) {
                if (lookups_old.items[i_old].eql(lookups_new.items[i_new])) {
                    _ = lookups_old.swapRemove(i_old);
                    _ = lookups_new.swapRemove(i_new);
                    continue :blk;
                }
                i_new += 1;
            }
            i_old += 1;
        }

        // HACK
        if (loader.pos_old != null) {
            system.world_patch_mgr.removeLoadRequestFromLookups(system.requester_id, lookups_old.items);

            for (lookups_old.items) |lookup| {
                for (system.patches.items, 0..) |*patch, i| {
                    if (patch.lookup.eql(lookup)) {
                        // TODO: Batch delete
                        for (patch.entities.items) |ent| {
                            system.flecs_world.delete(ent);
                        }

                        patch.entities.deinit();
                        _ = system.patches.swapRemove(i);
                        break;
                    }
                }
            }
        }
        loader.pos_old = pos_new;

        system.world_patch_mgr.addLoadRequestFromLookups(system.requester_id, lookups_new.items, .medium);

        for (lookups_new.items) |lookup| {
            system.patches.appendAssumeCapacity(.{
                .lookup = lookup,
                .lod = 1,
                .entities = std.ArrayList(flecs.EntityId).init(system.allocator),
            });
        }
    }
}

// hack
var added_spawn = false;

fn updatePatches(system: *SystemState) void {
    for (system.patches.items) |*patch| {
        if (patch.loaded) {
            continue;
        }

        const Prop = struct {
            id: IdLocal,
            pos: [3]f32,
            rot: f32,
        };

        const patch_info = system.world_patch_mgr.tryGetPatch(patch.lookup, Prop);
        if (patch_info.status != .not_loaded) {
            patch.loaded = true;
            if (patch_info.status == .loaded_empty or patch_info.status == .nonexistent) {
                break;
            }
            const data = patch_info.data_opt.?;

            const tree_id = IdLocal.init("tree");
            const wall_id = IdLocal.init("wall");
            const house_id = IdLocal.init("house");
            const city_id = IdLocal.init("city");
            var rand1 = std.rand.DefaultPrng.init(data.len);
            var rand = rand1.random();
            for (data) |prop| {
                const prop_pos = fd.Position.init(prop.pos[0], prop.pos[1], prop.pos[2]);
                const prop_scale: f32 = 1.0 + rand.float(f32) * 0.2;
                const prop_rot = fd.EulerRotation.init(0, prop.rot + std.math.pi * 0.5, 0);

                var prop_transform: fd.Transform = undefined;
                const z_prop_scale_matrix = zm.scaling(prop_scale, prop_scale, prop_scale);
                const z_prop_rot_matrix = zm.matFromRollPitchYaw(prop_rot.pitch, prop_rot.yaw, prop_rot.roll);
                const z_prop_translate_matrix = zm.translation(prop_pos.x, prop_pos.y, prop_pos.z);
                const z_prop_sr_matrix = zm.mul(z_prop_scale_matrix, z_prop_rot_matrix);
                const z_prop_srt_matrix = zm.mul(z_prop_sr_matrix, z_prop_translate_matrix);
                zm.storeMat43(prop_transform.matrix[0..], z_prop_srt_matrix);

                var prop_ent = system.flecs_world.newEntity();
                prop_ent.set(prop_transform);
                if (prop.id.hash == city_id.hash) {
                    // var light_ent = system.flecs_world.newEntity();
                    // light_ent.set(fd.Transform.initFromPosition(.{ .x = prop.pos[0], .y = prop.pos[1] + 2 + 10, .z = prop.pos[2] }));
                    // light_ent.set(fd.Light{ .radiance = .{ .r = 4, .g = 2, .b = 1 }, .range = 100 });

                    // // var light_viz_ent = system.flecs_world.newEntity();
                    // // light_viz_ent.set(fd.Position.init(city_pos.x, city_height + 2 + city_params.light_range * 0.1, city_pos.z));
                    // // light_viz_ent.set(fd.Scale.createScalar(1));
                    // // light_viz_ent.set(fd.CIShapeMeshInstance{
                    // //     .id = IdLocal.id64("sphere"),
                    // //     .basecolor_roughness = city_params.center_color,
                    // // });

                    // if (!added_spawn) {
                    //     added_spawn = true;
                    //     var spawn_pos = fd.Position.init(prop.pos[0], prop.pos[1], prop.pos[2]);
                    //     var spawn_ent = system.flecs_world.newEntity();
                    //     spawn_ent.set(spawn_pos);
                    //     spawn_ent.set(fd.SpawnPoint{ .active = true, .id = IdLocal.id64("player") });
                    //     spawn_ent.addPair(fr.Hometown, prop_ent);
                    //     // spawn_ent.set(fd.Scale.createScalar(city_params.center_scale));
                    // }
                } else {
                    prop_ent.set(fd.CIShapeMeshInstance{
                        .id = blk: {
                            if (prop.id.hash == tree_id.hash) {
                                break :blk IdLocal.id64("pine");
                            } else if (prop.id.hash == wall_id.hash) {
                                break :blk IdLocal.id64("long_house");
                            } else if (prop.id.hash == house_id.hash) {
                                break :blk IdLocal.id64("small_house");
                            }
                            unreachable;
                        },
                        .basecolor_roughness = .{ .r = 0.6, .g = 0.6, .b = 0.1, .roughness = 1.0 },
                    });
                }
                patch.entities.append(prop_ent.id) catch unreachable;
            }
        }
    }
}

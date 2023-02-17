const std = @import("std");
const img = @import("zigimg");
const Pool = @import("zpool").Pool;
const IdLocal = @import("../variant.zig").IdLocal;
const BucketQueue = @import("../core/bucket_queue.zig").BucketQueue;
const AssetManager = @import("../core/asset_manager.zig").AssetManager;
const util = @import("../util.zig");

const LoD = u4;
const min_patch_size = 64; // 2^6 m
const max_patch_size = 8192; // 2^(6+7) m
const max_world_size = 512 * 1024; // 500 km
const max_patch = max_world_size / min_patch_size; // 8k patches
const max_patch_int_bits = 16; // 2**13 = 8k
const max_patch_int = std.meta.Int(.unsigned, max_patch_int_bits);
const lod_0_patch_size = 64;

const max_requesters = 8;
const max_patch_types = 8;
pub const Priority = enum {
    come_on_do_it_do_it_come_on_do_it_now,
    high,
    medium,
    low,
};
pub const RequesterId = u8;
pub const PatchTypeId = u8;

const PatchRequest = struct {
    requester_id: u64,
    prio: Priority,
};

// const PatchLookup = u32;
// fn calcPatchLookup(x: u32, z: u32, lod: LoD) u32 {
//     const res = x | (z << max_patch_int_bits) | (lod << (max_patch_int_bits * 2));
//     return res;
// }
pub const PatchLookup = struct {
    world_x: max_patch_int,
    world_z: max_patch_int,
    lod: LoD,
    patch_type_id: PatchTypeId,

    // comptime {
    //     std.debug.assert(@sizeOf(@This()) == @sizeOf(u32));
    // }
};

// pub const PatchLookupHashContext = struct {
//     pub fn hash(self: @This(), pl: PatchLookup) u32 {
//         _ = self;
//         return @ptrCast();
//     }
//     pub fn eql(self: @This(), a: PatchLookup, b: PatchLookup, b_index: usize) bool {
//         _ = self;
//         _ = b_index;
//         return eqlString(a, b);
//     }
// };

// pub const PatchLoader = struct {
//     __v = *const VTable,

//     pub usingnamespace Methods(@This);

//     pub fn Methods(comptime T:type) type {
//         return extern struct {
//             pub inline load(self)
//         }
//     }
// }

pub const Patch = struct {
    lookup: PatchLookup,
    patch_x: u32,
    patch_z: u32,
    data: ?[]u8 = null,
    requesters: [max_requesters]PatchRequest = undefined,
    request_count: u8 = 0,
    highest_prio: Priority = .low,
    patch_type_id: PatchTypeId,
};

pub const PatchPool = Pool(16, 16, void, struct {
    patch: Patch,
});

pub const PatchHandle = PatchPool.Handle;
pub const PatchQueue = BucketQueue(PatchHandle, Priority);

pub const RequestArea = struct {
    x: f32,
    z: f32,
    width: f32,
    height: f32,
};

pub const PatchType = struct {
    id: IdLocal,
    loadFunc: *const fn (*Patch) void,
};

pub const WorldPatchManager = struct {
    allocator: std.mem.Allocator,
    requesters: std.ArrayList(IdLocal) = undefined,
    patch_types: std.ArrayList(PatchType) = undefined,
    patch_map_by_handle: std.AutoArrayHashMap(PatchHandle, Patch) = undefined,
    handle_map_by_lookup: std.AutoArrayHashMap(PatchLookup, PatchHandle) = undefined,
    // patch_queue: std.PriorityQueue(QueuedPatch) = undefined,
    patch_pool: PatchPool = undefined,
    bucket_queue: PatchQueue = undefined,
    asset_manager: AssetManager = undefined,

    pub fn create(allocator: std.mem.Allocator, asset_manager: AssetManager) WorldPatchManager {
        var res = WorldPatchManager{
            .allocator = allocator,
            .requesters = std.ArrayList(IdLocal).initCapacity(allocator, max_requesters) catch unreachable,
            .patch_types = std.ArrayList(PatchType).initCapacity(allocator, max_patch_types) catch unreachable,
            .patch_map_by_handle = std.AutoArrayHashMap(PatchHandle, Patch).init(allocator),
            .handle_map_by_lookup = std.AutoArrayHashMap(PatchLookup, PatchHandle).init(allocator),
            .patch_pool = PatchPool.initCapacity(allocator, 8) catch unreachable, // temporarily low for testing
            .bucket_queue = PatchQueue.create(allocator, [_]u32{ 64, 64, 64, 64 }), // temporarily low for testing
            .asset_manager = asset_manager,
        };

        return res;
    }

    pub fn destroy(self: *WorldPatchManager) void {
        self.patch_pool.deinit();
    }

    pub fn registerRequester(self: *WorldPatchManager, id: IdLocal) RequesterId {
        const requester_id = @intCast(u8, self.requesters.items.len);
        self.requesters.appendAssumeCapacity(id);
        return requester_id;
    }

    pub fn registerPatchType(self: *WorldPatchManager, patch_type: PatchType) PatchTypeId {
        const patch_type_id = @intCast(u8, self.patch_types.items.len);
        self.patch_types.appendAssumeCapacity(patch_type);
        return patch_type_id;
    }

    pub fn getPatchTypeId(self: *WorldPatchManager, id: IdLocal) PatchTypeId {
        for (self.patch_types) |patch_type, i| {
            if (patch_type.id.eql(id)) {
                return i;
            }
        }
        unreachable;
    }

    pub fn getLookup(world_x: f32, world_z: f32, lod: LoD, patch_type_id: PatchTypeId) PatchLookup {
        const world_stride = lod_0_patch_size * std.math.pow(f32, 2.0, @intToFloat(f32, lod));
        const world_x_begin = world_stride * @divFloor(world_x, world_stride);
        const world_z_begin = world_stride * @divFloor(world_z, world_stride);
        const patch_x_begin = @floatToInt(u16, @divExact(world_x_begin, world_stride));
        const patch_z_begin = @floatToInt(u16, @divExact(world_z_begin, world_stride));
        return PatchLookup{
            .world_x = patch_x_begin,
            .world_z = patch_z_begin,
            .lod = lod,
            .patch_type_id = patch_type_id,
        };
    }

    pub fn addLoadRequest(self: *WorldPatchManager, requester_id: RequesterId, patch_type_id: PatchTypeId, area: RequestArea, lod: LoD, prio: Priority) void {
        const world_stride = lod_0_patch_size * std.math.pow(f32, 2.0, @intToFloat(f32, lod));
        const world_x_begin = @divFloor(area.x, world_stride);
        const world_z_begin = @divFloor(area.z, world_stride);
        const world_x_end = world_stride * (@divFloor(area.x + area.width - 1, world_stride) + 1);
        const world_z_end = world_stride * (@divFloor(area.z + area.height - 1, world_stride) + 1);
        const patch_x_begin = @floatToInt(u16, @divExact(world_x_begin, world_stride));
        const patch_z_begin = @floatToInt(u16, @divExact(world_z_begin, world_stride));
        const patch_x_end = @floatToInt(u16, @divExact(world_x_end, world_stride));
        const patch_z_end = @floatToInt(u16, @divExact(world_z_end, world_stride));

        var patch_z = patch_z_begin;
        while (patch_z < patch_z_end) : (patch_z += 1) {
            var patch_x = patch_x_begin;
            while (patch_x < patch_x_end) : (patch_x += 1) {
                const patch_lookup = PatchLookup{
                    .world_x = patch_x,
                    .world_z = patch_z,
                    .lod = lod,
                    .patch_type_id = patch_type_id,
                };

                const patch_handle_opt = self.handle_map_by_lookup.get(patch_lookup);
                if (patch_handle_opt) |patch_handle| {
                    const patch_opt = self.patch_map_by_handle.getPtr(patch_handle);
                    if (patch_opt) |patch| {
                        patch.requesters[patch.request_count].requester_id = requester_id;
                        patch.requesters[patch.request_count].prio = prio;
                        patch.request_count += 1;
                        patch.highest_prio = @intToEnum(
                            Priority,
                            std.math.min(
                                @enumToInt(patch.highest_prio),
                                @enumToInt(prio),
                            ),
                        );
                        continue;
                    }

                    unreachable;
                }

                var patch = Patch{
                    .lookup = patch_lookup,
                    .patch_x = patch_x,
                    .patch_z = patch_z,
                    .patch_type_id = patch_type_id,
                };
                patch.requesters[patch.request_count].requester_id = requester_id;
                patch.requesters[patch.request_count].prio = prio;
                patch.request_count = 1;
                patch.highest_prio = @intToEnum(
                    Priority,
                    std.math.min(
                        @enumToInt(patch.highest_prio),
                        @enumToInt(prio),
                    ),
                );
                patch.patch_type_id = patch_type_id;

                const patch_handle = self.patch_pool.add(.{ .patch = patch }) catch unreachable;
                self.bucket_queue.pushElems(util.sliceOfInstanceConst(PatchHandle, &patch_handle), prio);

                self.handle_map_by_lookup.put(patch_lookup, patch_handle) catch unreachable;
                // self.patch_map_by_handle.put(patch_handle, patch);
            }
        }
    }

    pub fn removeLoadRequest(self: *WorldPatchManager, requester_id: RequesterId, patch_type_id: PatchTypeId, area: RequestArea, lod: LoD) void {
        const world_stride = lod_0_patch_size * std.math.pow(f32, @intToFloat(f32, lod), 2);
        const world_x_begin = @divFloor(area.x, world_stride);
        const world_z_begin = @divFloor(area.z, world_stride);
        const world_x_end = @divFloor(area.x + area.width - 1, world_stride) + 1;
        const world_z_end = @divFloor(area.z + area.height - 1, world_stride) + 1;
        const patch_x_begin = @divExact(world_x_begin, world_stride);
        const patch_z_begin = @divExact(world_z_begin, world_stride);
        const patch_x_end = @divExact(world_x_end, world_stride);
        const patch_z_end = @divExact(world_z_end, world_stride);

        var patch_z = patch_z_begin;
        while (patch_z < patch_z_end) {
            var patch_x = patch_x_begin;
            while (patch_x < patch_x_end) {
                const patch_lookup = PatchLookup{
                    .x = patch_x,
                    .z = patch_z,
                    .lod = lod,
                    .patch_type_id = patch_type_id,
                };

                const patch_opt = self.patch_map_by_lookup.remove(patch_lookup);
                if (patch_opt) |*patch| {
                    for (patch.requesters) |*requester, i| {
                        _ = i;

                        if (requester.id == requester_id) {
                            if (requester.prio == patch.highest_prio) {
                                // TODO: Update highest
                            }
                            requester = patch.requesters[patch.request_count - 1];
                            patch.request_count -= 1;

                            if (patch.request_count == 0) {
                                // TODO: Remove from queue
                            }

                            break;
                        }
                    }
                }
            }
        }
    }

    pub fn tryGetPatch(self: WorldPatchManager, patch_lookup: PatchLookup, comptime T: type) ?[]T {
        const patch_handle_opt = self.handle_map_by_lookup.get(patch_lookup);
        if (patch_handle_opt) |patch_handle| {
            const patch_opt: ?*Patch = self.patch_pool.getColumnPtrIfLive(patch_handle, .patch);
            if (patch_opt) |patch| {
                return patch.data;
            }
        }
        return null;
    }

    pub fn tick(self: *WorldPatchManager) void {
        var patch_handle: PatchHandle = PatchHandle.init(0, 0);
        // var lol1: *[1]PatchHandle = &patch_handle;
        // var lol2: []PatchHandle = lol1;
        while (self.bucket_queue.popElems(util.sliceOfInstance(PatchHandle, &patch_handle)) > 0) {
            // if (self.bucket_queue.popElems((&patch_handle)[0..])) {
            var patch_opt = self.patch_pool.getColumnPtrIfLive(patch_handle, .patch);
            if (patch_opt) |patch| {

                // const patch_type = &self.patch_types[patch.patch_type_id];
                // patch_type.loadFunc(patch);
                var heightmap_namebuf: [256]u8 = undefined;
                const heightmap_path = std.fmt.bufPrintZ(
                    heightmap_namebuf[0..heightmap_namebuf.len],
                    "content/patch/heightmap/lod{}/heightmap_x{}_y{}.dds",
                    .{
                        patch.lookup.lod,
                        patch.patch_x,
                        patch.patch_z,
                    },
                ) catch unreachable;

                const asset_id = IdLocal.init(heightmap_path);
                var data = self.asset_manager.loadAssetBlocking(asset_id, .instant_blocking);
                patch.data = data;

                // const file = std.fs.cwd().openFile(heightmap_path, .{}) catch unreachable;
                // defer file.close();
                // var stream_source = std.io.StreamSource{ .file = file };
                // const image = png.PNG.readImage(self.allocator, &stream_source);
                // _ = image;
            }
        }
    }
};

// test "world_patch_manager" {
//     const TestPatchLoader = struct {
//         pub fn load(patch: *Patch) void {
//             _ = patch;
//         }
//     };
//     var world_patch_manager = WorldPatchManager.create(std.testing.allocator, 64);
//     const rid = world_patch_manager.registerRequester(IdLocal.init("test_requester"));
//     const patch_type = world_patch_manager.registerPatchType(.{
//         .id = IdLocal.init("test_heightmap"),
//         .loadFunc = TestPatchLoader.load,
//     });
//     world_patch_manager.addLoadRequest(
//         rid,
//         patch_type,
//         .{ .x = 0, .z = 0, .width = 64, .height = 64 },
//         0,
//         Priority.high,
//     );
//     world_patch_manager.tick();
// }

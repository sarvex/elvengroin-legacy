const std = @import("std");
const assert = std.debug.assert;
const zwin32 = @import("zwin32");
const d3d12 = zwin32.d3d12;
const zd3d12 = @import("zd3d12");

pub const TextureDesc = struct {
    state: d3d12.RESOURCE_STATES, // TODO: Replace this with non-d3d12 state enum
    name: [*:0]const u16,
};

pub const Texture = struct {
    valid: bool = false,
    resource: zd3d12.ResourceHandle,
    persistent_descriptor: zd3d12.PersistentDescriptor,
};

pub const TextureHandle = struct {
    index: u16 align(4) = 0,
    generation: u16 = 0,
};

pub const TexturePool = struct {
    const max_num_textures = 1024; // TODO: Figure out how many we need as we go

    textures: []Texture,
    generations: []u16,

    pub fn init(allocator: std.mem.Allocator) TexturePool {
        return .{
            .textures = blk: {
                var textures = allocator.alloc(
                    Texture,
                    max_num_textures + 1,
                ) catch unreachable;
                for (textures) |*texture| {
                    texture.* = .{
                        .resource = undefined,
                        .persistent_descriptor = undefined,
                    };
                }
                break :blk textures;
            },
            .generations = blk: {
                var generations = allocator.alloc(
                    u16,
                    max_num_textures + 1,
                ) catch unreachable;
                for (generations) |*gen| gen.* = 0;
                break :blk generations;
            },
        };
    }

    pub fn deinit(pool: *TexturePool, allocator: std.mem.Allocator, gctx: *zd3d12.GraphicsContext) void {
        for (pool.textures) |texture| {
            if (texture.valid) {
                gctx.destroyResource(texture.resource);
            }
        }

        allocator.free(pool.textures);
        allocator.free(pool.generations);
        pool.* = undefined;
    }

    pub fn addTexture(pool: *TexturePool, texture: Texture) TextureHandle {
        var slot_idx: u32 = 1;
        while (slot_idx <= max_num_textures) : (slot_idx += 1) {
            if (!pool.textures[slot_idx].valid)
                break;
        }
        assert(slot_idx <= max_num_textures);

        pool.textures[slot_idx] = .{
            .valid = true,
            .resource = texture.resource,
            .persistent_descriptor = .{
                .cpu_handle = texture.persistent_descriptor.cpu_handle,
                .gpu_handle = texture.persistent_descriptor.gpu_handle,
                .index = texture.persistent_descriptor.index,
            },
        };
        const handle = TextureHandle{
            .index = @intCast(u16, slot_idx),
            .generation = blk: {
                pool.generations[slot_idx] += 1;
                break :blk pool.generations[slot_idx];
            },
        };
        return handle;
    }

    pub fn destroyTexture(pool: *TexturePool, handle: TextureHandle, gctx: *zd3d12.GraphicsContext) void {
        var texture = pool.lookupTexture(handle);
        if (texture == null)
            return;

        gctx.destroyResource(texture.?.resource);

        texture.?.* = .{
            .valid = false,
            .resource = undefined,
            .persistent_descriptor = undefined,
        };
    }

    fn isTextureValid(pool: TexturePool, handle: TextureHandle) bool {
        return handle.index > 0 and
            handle.index <= max_num_textures and
            handle.generation > 0 and
            handle.generation == pool.generations[handle.index] and
            pool.textures[handle.index].valid;
    }

    pub fn lookupTexture(pool: TexturePool, handle: TextureHandle) ?*Texture {
        if (pool.isTextureValid(handle)) {
            return &pool.textures[handle.index];
        }

        return null;
    }
};

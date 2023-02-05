const std = @import("std");
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const assert = std.debug.assert;
const math = std.math;

const glfw = @import("glfw");
const zm = @import("zmath");
const zmu = @import("zmathutil");
const flecs = @import("flecs");

const config = @import("../config.zig");
const gfx = @import("../gfx_d3d12.zig");
const zd3d12 = @import("zd3d12");
const zwin32 = @import("zwin32");
const w32 = zwin32.w32;
const dxgi = zwin32.dxgi;
const wic = zwin32.wic;
const hrPanic = zwin32.hrPanic;
const hrPanicOnFail = zwin32.hrPanicOnFail;
const d3d12 = zwin32.d3d12;
const dds_loader = @import("../renderer/d3d12/dds_loader.zig");

const fd = @import("../flecs_data.zig");
const IdLocal = @import("../variant.zig").IdLocal;
const IndexType = u32;

const zmesh = @import("zmesh");

const TerrainLayer = struct {
    diffuse: gfx.TextureHandle,
    normal: gfx.TextureHandle,
    arm: gfx.TextureHandle,
};

const TerrainLayerTextureIndices = extern struct {
    diffuse_index: u32,
    normal_index: u32,
    arm_index: u32,
    padding: u32,
};

const FrameUniforms = extern struct {
    world_to_clip: zm.Mat,
    camera_position: [3]f32,
    time: f32,
    padding1: u32,
    padding2: u32,
    padding3: u32,
    light_count: u32,
    light_positions: [32][4]f32,
    light_radiances: [32][4]f32,
};

const DrawUniforms = struct {
    start_instance_location: u32,
    vertex_offset: i32,
    vertex_buffer_index: u32,
    instance_data_buffer_index: u32,
    terrain_layers_buffer_index: u32,
};

const Vertex = struct {
    position: [3]f32,
    normal: [3]f32,
    uv: [2]f32,
    tangent: [4]f32,
};

const InstanceData = struct {
    object_to_world: zm.Mat,
    heightmap_index: u32,
    splatmap_index: u32,
    padding1: u32,
    padding2: u32,
};

const max_instances = 100;
const max_instances_per_draw_call = 20;

const DrawCall = struct {
    mesh_index: u32,
    index_count: u32,
    instance_count: u32,
    index_offset: u32,
    vertex_offset: i32,
    start_instance_location: u32,
};

const Mesh = struct {
    index_offset: u32,
    vertex_offset: i32,
    num_indices: u32,
    num_vertices: u32,
};

const QuadTreeNode = struct {
    center: [2]f32,
    size: [2]f32,
    child_indices: [4]u32,
    mesh_lod: u32,
    patch_index: [2]u32,
    // TODO: Do not store these here when we implement streaming
    heightmap_handle: gfx.TextureHandle,
    splatmap_handle: gfx.TextureHandle,

    pub inline fn containsPoint(self: *QuadTreeNode, point: [2]f32) bool {
        return !(point[0] < (self.center[0] - self.size[0]) or
            point[0] > (self.center[0] + self.size[0]) or
            point[1] < (self.center[1] - self.size[1]) or
            point[1] > (self.center[1] + self.size[1]));
    }

    pub fn containedInsideChildren(self: *QuadTreeNode, point: [2]f32, nodes: *std.ArrayList(QuadTreeNode)) bool {
        if (!self.containsPoint(point)) {
            return false;
        }

        for (self.child_indices) |child_index| {
            var node = nodes.items[child_index];
            if (node.containsPoint(point)) {
                return true;
            }
        }

        return false;
    }
};

const SystemState = struct {
    allocator: std.mem.Allocator,
    flecs_world: *flecs.World,
    sys: flecs.EntityId,

    gfx: *gfx.D3D12State,

    query_camera: flecs.Query,
    query_lights: flecs.Query,

    vertex_buffer: gfx.BufferHandle,
    index_buffer: gfx.BufferHandle,
    terrain_layers_buffer: gfx.BufferHandle,
    instance_data_buffers: [gfx.D3D12State.num_buffered_frames]gfx.BufferHandle,
    instance_data: std.ArrayList(InstanceData),
    draw_calls: std.ArrayList(DrawCall),
    gpu_frame_profiler_index: u64 = undefined,

    // NOTE(gmodarelli): This should be part of gfx_d3d12.zig or texture.zig
    // but for now it's here to speed test it out and speed things along
    textures_heap: *d3d12.IHeap,
    textures_heap_offset: u64 = 0,

    terrain_quad_tree_nodes: std.ArrayList(QuadTreeNode),
    terrain_lod_meshes: std.ArrayList(Mesh),
    quads_to_render: std.ArrayList(u32),

    camera: struct {
        position: [3]f32 = .{ 0.0, 4.0, -4.0 },
        forward: [3]f32 = .{ 0.0, 0.0, 1.0 },
        pitch: f32 = 0.15 * math.pi,
        yaw: f32 = 0.0,
    } = .{},
};

fn loadMesh(
    allocator: std.mem.Allocator,
    path: []const u8,
    meshes: *std.ArrayList(Mesh),
    meshes_indices: *std.ArrayList(IndexType),
    meshes_vertices: *std.ArrayList(Vertex),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.log.warn("Unable to open file: {s}", .{@errorName(err)});
        return err;
    };
    defer file.close();

    var buffer_reader = std.io.bufferedReader(file.reader());
    var in_stream = buffer_reader.reader();

    var mesh = Mesh{
        .index_offset = @intCast(u32, meshes_indices.items.len),
        .vertex_offset = @intCast(i32, meshes_vertices.items.len),
        .num_indices = 0,
        .num_vertices = 0,
    };

    // var unique_indices_map = std.StringHashMap(u32).init(allocator);
    var unique_indices_map = std.HashMap([]const u8, u32, std.hash_map.StringContext, 80).init(allocator);
    try unique_indices_map.ensureTotalCapacity(10 * 1024);
    defer unique_indices_map.deinit();

    var indices = std.ArrayList(IndexType).init(arena);
    var vertices = std.ArrayList(Vertex).init(arena);

    var positions = std.ArrayList([3]f32).init(arena);
    var normals = std.ArrayList([3]f32).init(arena);
    var uvs = std.ArrayList([2]f32).init(arena);

    var buf: [1024]u8 = undefined;

    while (try in_stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        var it = std.mem.split(u8, line, " ");

        var first = it.first();
        if (std.mem.eql(u8, first, "v")) {
            var position: [3]f32 = undefined;
            position[0] = std.fmt.parseFloat(f32, it.next().?) catch unreachable;
            position[1] = std.fmt.parseFloat(f32, it.next().?) catch unreachable;
            position[2] = std.fmt.parseFloat(f32, it.next().?) catch unreachable;
            positions.append(position) catch unreachable;
        } else if (std.mem.eql(u8, first, "vn")) {
            var normal: [3]f32 = undefined;
            normal[0] = std.fmt.parseFloat(f32, it.next().?) catch unreachable;
            normal[1] = std.fmt.parseFloat(f32, it.next().?) catch unreachable;
            normal[2] = std.fmt.parseFloat(f32, it.next().?) catch unreachable;
            normals.append(normal) catch unreachable;
        } else if (std.mem.eql(u8, first, "vt")) {
            var uv: [2]f32 = undefined;
            uv[0] = std.fmt.parseFloat(f32, it.next().?) catch unreachable;
            uv[1] = std.fmt.parseFloat(f32, it.next().?) catch unreachable;
            uvs.append(uv) catch unreachable;
        } else if (std.mem.eql(u8, first, "f")) {
            var triangle_index: u32 = 0;
            while (triangle_index < 3) : (triangle_index += 1) {
                var vertex_components = it.next().?;
                var triangles_iterator = std.mem.split(u8, vertex_components, "/");

                // NOTE(gmodarelli): We're assuming Positions, UV's and Normals are exported with the OBJ file.
                // TODO(gmodarelli): Parse the OBJ in 2 passes. First collect all attributes and then generate
                // vertices and indices. Positions and UV's must be present, Normals can be calculated.
                var position_index = std.fmt.parseInt(IndexType, triangles_iterator.next().?, 10) catch unreachable;
                position_index -= 1;
                var uv_index = std.fmt.parseInt(IndexType, triangles_iterator.next().?, 10) catch unreachable;
                uv_index -= 1;
                var normal_index = std.fmt.parseInt(IndexType, triangles_iterator.next().?, 10) catch unreachable;
                normal_index -= 1;

                const unique_vertex_index = @intCast(u32, vertices.items.len);
                indices.append(unique_vertex_index) catch unreachable;
                vertices.append(.{
                    .position = positions.items[position_index],
                    .normal = normals.items[normal_index],
                    .uv = uvs.items[uv_index],
                    .tangent = [4]f32{ 0.0, 0.0, 0.0, 0.0 },
                }) catch unreachable;
            }
        }
    }

    // Calculate tangents for every vertex
    {
        var tangents = std.ArrayList([3]f32).init(arena);
        tangents.resize(vertices.items.len) catch unreachable;
        var bitangents = std.ArrayList([3]f32).init(arena);
        bitangents.resize(vertices.items.len) catch unreachable;

        var i: u32 = 0;
        while (i < tangents.items.len) : (i += 1) {
            var t = &tangents.items[i];
            t[0] = 0.0;
            t[1] = 0.0;
            t[2] = 0.0;

            var b = &bitangents.items[i];
            b[0] = 0.0;
            b[1] = 0.0;
            b[2] = 0.0;
        }

        var index: u32 = 0;
        while (index < indices.items.len) : (index += 3) {
            const vertex_0 = vertices.items[indices.items[index + 0]];
            const vertex_1 = vertices.items[indices.items[index + 1]];
            const vertex_2 = vertices.items[indices.items[index + 2]];

            var p0 = zm.loadArr3(vertex_0.position);
            var p1 = zm.loadArr3(vertex_1.position);
            var p2 = zm.loadArr3(vertex_2.position);

            var e1 = p1 - p0;
            var e2 = p2 - p0;
            const x1 = vertex_1.uv[0] - vertex_0.uv[0];
            const x2 = vertex_2.uv[0] - vertex_0.uv[0];
            const y1 = vertex_1.uv[1] - vertex_0.uv[1];
            const y2 = vertex_2.uv[1] - vertex_0.uv[1];
            const vec_x1 = zm.Vec{ x1, x1, x1, 0.0 };
            const vec_x2 = zm.Vec{ x2, x2, x2, 0.0 };
            const vec_y1 = zm.Vec{ y1, y1, y1, 0.0 };
            const vec_y2 = zm.Vec{ y2, y2, y2, 0.0 };

            const r = 1.0 / (x1 * y2 - x2 * y1);
            const vec_r = zm.Vec{ r, r, r, 0.0 };
            var tangent = [3]f32{ 0.0, 0.0, 0.0 };
            zm.storeArr3(&tangent, (e1 * vec_y2 - e2 * vec_y1) * vec_r);
            var bitangent = [3]f32{ 0.0, 0.0, 0.0 };
            zm.storeArr3(&bitangent, (e2 * vec_x1 - e1 * vec_x2) * vec_r);

            tangents.items[indices.items[index + 0]][0] += tangent[0];
            tangents.items[indices.items[index + 0]][1] += tangent[1];
            tangents.items[indices.items[index + 0]][2] += tangent[2];

            tangents.items[indices.items[index + 1]][0] += tangent[0];
            tangents.items[indices.items[index + 1]][1] += tangent[1];
            tangents.items[indices.items[index + 1]][2] += tangent[2];

            tangents.items[indices.items[index + 2]][0] += tangent[0];
            tangents.items[indices.items[index + 2]][1] += tangent[1];
            tangents.items[indices.items[index + 2]][2] += tangent[2];

            bitangents.items[indices.items[index + 0]][0] += bitangent[0];
            bitangents.items[indices.items[index + 0]][1] += bitangent[1];
            bitangents.items[indices.items[index + 0]][2] += bitangent[2];

            bitangents.items[indices.items[index + 1]][0] += bitangent[0];
            bitangents.items[indices.items[index + 1]][1] += bitangent[1];
            bitangents.items[indices.items[index + 1]][2] += bitangent[2];

            bitangents.items[indices.items[index + 2]][0] += bitangent[0];
            bitangents.items[indices.items[index + 2]][1] += bitangent[1];
            bitangents.items[indices.items[index + 2]][2] += bitangent[2];
        }

        var vi: u32 = 0;
        while (vi < vertices.items.len) : (vi += 1) {
            var vertex = &vertices.items[vi];

            const tangent = zm.loadArr3(tangents.items[vi]);
            const binormal = zm.loadArr3(tangents.items[vi]);
            const normal = zm.normalize3(zm.loadArr3(vertex.normal));

            const reject = tangent - zm.dot3(tangent, normal) * normal;
            var new_tangent = [3]f32{ 0.0, 0.0, 0.0 };
            zm.storeArr3(&new_tangent, zm.normalize3(reject));
            var result = [3]f32{ 0.0, 0.0, 0.0 };
            zm.storeArr3(&result, zm.dot3(zm.cross3(tangent, binormal), normal));
            var handedness: f32 = if (result[0] > 0.0) 1.0 else -1.0;

            vertex.tangent[0] = new_tangent[0];
            vertex.tangent[1] = new_tangent[1];
            vertex.tangent[2] = new_tangent[2];
            vertex.tangent[3] = handedness;
        }
    }

    var remapped_indices = std.ArrayList(u32).init(arena);
    remapped_indices.resize(indices.items.len) catch unreachable;

    const num_unique_vertices = zmesh.opt.generateVertexRemap(
        remapped_indices.items,
        indices.items,
        Vertex,
        vertices.items,
    );

    var optimized_vertices = std.ArrayList(Vertex).init(arena);
    optimized_vertices.resize(num_unique_vertices) catch unreachable;

    zmesh.opt.remapVertexBuffer(
        Vertex,
        optimized_vertices.items,
        vertices.items,
        remapped_indices.items,
    );

    mesh.num_indices = @intCast(u32, remapped_indices.items.len);
    mesh.num_vertices = @intCast(u32, optimized_vertices.items.len);

    meshes.append(mesh) catch unreachable;
    meshes_indices.appendSlice(remapped_indices.items) catch unreachable;
    meshes_vertices.appendSlice(optimized_vertices.items) catch unreachable;
}

// NOTE(gmodarelli) This should live inside gfx_d3d12.zig or texture.zig
// NOTE(gmodarelli) The caller must release the IFormatConverter
// eg. image_conv.Release();
fn loadTexture(gctx: *zd3d12.GraphicsContext, path: []const u8) !struct {
    image: *wic.IFormatConverter,
    format: dxgi.FORMAT,
} {
    var path_u16: [300]u16 = undefined;
    assert(path.len < path_u16.len - 1);
    const path_len = std.unicode.utf8ToUtf16Le(path_u16[0..], path) catch unreachable;
    path_u16[path_len] = 0;

    const bmp_decoder = blk: {
        var maybe_bmp_decoder: ?*wic.IBitmapDecoder = undefined;
        hrPanicOnFail(gctx.wic_factory.CreateDecoderFromFilename(
            @ptrCast(w32.LPCWSTR, &path_u16),
            null,
            w32.GENERIC_READ,
            .MetadataCacheOnDemand,
            &maybe_bmp_decoder,
        ));
        break :blk maybe_bmp_decoder.?;
    };
    defer _ = bmp_decoder.Release();

    const bmp_frame = blk: {
        var maybe_bmp_frame: ?*wic.IBitmapFrameDecode = null;
        hrPanicOnFail(bmp_decoder.GetFrame(0, &maybe_bmp_frame));
        break :blk maybe_bmp_frame.?;
    };
    defer _ = bmp_frame.Release();

    const pixel_format = blk: {
        var pixel_format: w32.GUID = undefined;
        hrPanicOnFail(bmp_frame.GetPixelFormat(&pixel_format));
        break :blk pixel_format;
    };

    const eql = std.mem.eql;
    const asBytes = std.mem.asBytes;
    const num_components: u32 = blk: {
        if (eql(u8, asBytes(&pixel_format), asBytes(&wic.GUID_PixelFormat24bppRGB))) break :blk 4;
        if (eql(u8, asBytes(&pixel_format), asBytes(&wic.GUID_PixelFormat32bppRGB))) break :blk 4;
        if (eql(u8, asBytes(&pixel_format), asBytes(&wic.GUID_PixelFormat32bppRGBA))) break :blk 4;
        if (eql(u8, asBytes(&pixel_format), asBytes(&wic.GUID_PixelFormat32bppPRGBA))) break :blk 4;

        if (eql(u8, asBytes(&pixel_format), asBytes(&wic.GUID_PixelFormat24bppBGR))) break :blk 4;
        if (eql(u8, asBytes(&pixel_format), asBytes(&wic.GUID_PixelFormat32bppBGR))) break :blk 4;
        if (eql(u8, asBytes(&pixel_format), asBytes(&wic.GUID_PixelFormat32bppBGRA))) break :blk 4;
        if (eql(u8, asBytes(&pixel_format), asBytes(&wic.GUID_PixelFormat32bppPBGRA))) break :blk 4;
        if (eql(u8, asBytes(&pixel_format), asBytes(&wic.GUID_PixelFormat64bppRGBA))) break :blk 4;

        if (eql(u8, asBytes(&pixel_format), asBytes(&wic.GUID_PixelFormat8bppGray))) break :blk 1;
        if (eql(u8, asBytes(&pixel_format), asBytes(&wic.GUID_PixelFormat8bppAlpha))) break :blk 1;


        unreachable;
    };

    const wic_format = if (num_components == 1)
        &wic.GUID_PixelFormat8bppGray
    else
        &wic.GUID_PixelFormat32bppRGBA;

    const dxgi_format = if (num_components == 1) dxgi.FORMAT.R8_UNORM else dxgi.FORMAT.R8G8B8A8_UNORM;

    const image_conv = blk: {
        var maybe_image_conv: ?*wic.IFormatConverter = null;
        hrPanicOnFail(gctx.wic_factory.CreateFormatConverter(&maybe_image_conv));
        break :blk maybe_image_conv.?;
    };

    hrPanicOnFail(image_conv.Initialize(
        @ptrCast(*wic.IBitmapSource, bmp_frame),
        wic_format,
        .None,
        null,
        0.0,
        .Custom,
    ));

    return .{ .image = image_conv, .format = dxgi_format };
}

fn createDDSTextureFromFile(
    path: []const u8,
    arena: std.mem.Allocator,
    gfxstate: *gfx.D3D12State,
    heap: *d3d12.IHeap,
    heap_size: u64,
    heap_offset: *u64,
) !gfx.Texture {
    // Generate Path
    std.log.debug("Creating texture from DDS {s}", .{path});

    // NOTE:(gmodarelli) If I schedule all of these uploads in a single frame I end up with all the textures
    // having the data from the first uploaded texture :(
    gfxstate.gctx.beginFrame();

    // Load DDS data into D3D12_SUBRESOURCE_DATA
    var subresources = std.ArrayList(d3d12.SUBRESOURCE_DATA).init(arena);
    const dds_info = dds_loader.loadTextureFromFile(path, arena, &subresources) catch unreachable;

    // Create a texture and upload all its subresources to the GPU
    const resource = blk: {
        // Reserve space for the texture (subresources) from a pre-allocated HEAP
        var resource = allocateTextureMemory(
            gfxstate,
            heap,
            heap_size,
            heap_offset,
            dds_info.width,
            dds_info.height,
            dds_info.format,
            dds_info.mip_map_count,
        ) catch unreachable;

        // Set a debug name
        {
            var path_u16: [300]u16 = undefined;
            assert(path.len < path_u16.len - 1);
            const path_len = std.unicode.utf8ToUtf16Le(path_u16[0..], path) catch unreachable;
            path_u16[path_len] = 0;
            _ = resource.SetName(@ptrCast(w32.LPCWSTR, &path_u16));
        }

        // Upload all subresources
        uploadSubResources(gfxstate, resource, &subresources, d3d12.RESOURCE_STATES.GENERIC_READ);

        break :blk resource;
    };

    // NOTE:(gmodarelli) If I schedule all of these uploads in a single frame I end up with all the textures
    // having the data from the first uploaded texture :(
    gfxstate.gctx.endFrame();
    gfxstate.gctx.finishGpuCommands();

    // Create a persisten SRV descriptor for the texture
    const srv_allocation = gfxstate.gctx.allocatePersistentGpuDescriptors(1);
    gfxstate.gctx.device.CreateShaderResourceView(
        resource,
        null,
        srv_allocation.cpu_handle,
    );

    return gfx.Texture{
        .resource = resource,
        .persistent_descriptor = srv_allocation,
    };
}

fn allocateTextureMemory(gfxstate: *gfx.D3D12State, heap: *d3d12.IHeap, heap_size: u64, heap_offset: *u64, width: u32, height: u32, format: dxgi.FORMAT, mip_count: u32) !*d3d12.IResource {
    assert(gfxstate.gctx.is_cmdlist_opened);

    var resource: *d3d12.IResource = undefined;
    const desc = desc_blk: {
        var desc = d3d12.RESOURCE_DESC.initTex2d(
            format,
            width,
            height,
            mip_count,
        );
        desc.Flags = .{};
        break :desc_blk desc;
    };

    const descs = [_]d3d12.RESOURCE_DESC{desc};
    const allocation_info = gfxstate.gctx.device.GetResourceAllocationInfo(0, 1, &descs);
    assert(heap_offset.* + allocation_info.SizeInBytes < heap_size);

    hrPanicOnFail(gfxstate.gctx.device.CreatePlacedResource(
        heap,
        heap_offset.*,
        &desc,
        .{ .COPY_DEST = true },
        null,
        &d3d12.IID_IResource,
        @ptrCast(*?*anyopaque, &resource),
    ));

    // NOTE(gmodarelli): The heap is aligned to 64KB and our textures are smaller than that
    // TODO(gmodarelli): Use atlases so we don't wast as much space
    heap_offset.* += allocation_info.SizeInBytes;

    return resource;
}

fn uploadDataToTexture(gfxstate: *gfx.D3D12State, resource: *d3d12.IResource, data: *wic.IFormatConverter, state_after: d3d12.RESOURCE_STATES) !void {
    assert(gfxstate.gctx.is_cmdlist_opened);

    const desc = resource.GetDesc();

    var layout: [1]d3d12.PLACED_SUBRESOURCE_FOOTPRINT = undefined;
    var required_size: u64 = undefined;
    gfxstate.gctx.device.GetCopyableFootprints(&desc, 0, 1, 0, &layout, null, null, &required_size);

    const upload = gfxstate.gctx.allocateUploadBufferRegion(u8, @intCast(u32, required_size));
    layout[0].Offset = upload.buffer_offset;

    hrPanicOnFail(data.CopyPixels(
        null,
        layout[0].Footprint.RowPitch,
        layout[0].Footprint.RowPitch * layout[0].Footprint.Height,
        upload.cpu_slice.ptr,
    ));

    gfxstate.gctx.cmdlist.CopyTextureRegion(&d3d12.TEXTURE_COPY_LOCATION{
        .pResource = resource,
        .Type = .SUBRESOURCE_INDEX,
        .u = .{ .SubresourceIndex = 0 },
    }, 0, 0, 0, &d3d12.TEXTURE_COPY_LOCATION{
        .pResource = upload.buffer,
        .Type = .PLACED_FOOTPRINT,
        .u = .{ .PlacedFootprint = layout[0] },
    }, null);

    const barrier = d3d12.RESOURCE_BARRIER{
        .Type = .TRANSITION,
        .Flags = .{},
        .u = .{
            .Transition = .{
                .pResource = resource,
                .Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
                .StateBefore = .{ .COPY_DEST = true },
                .StateAfter = state_after,
            },
        },
    };
    var barriers = [_]d3d12.RESOURCE_BARRIER{barrier};
    gfxstate.gctx.cmdlist.ResourceBarrier(1, &barriers);
}

const max_subresources: u32 = 12;
fn uploadSubResources(gfxstate: *gfx.D3D12State, resource: *d3d12.IResource, subresources: *std.ArrayList(d3d12.SUBRESOURCE_DATA), state_after: d3d12.RESOURCE_STATES) void {
    assert(gfxstate.gctx.is_cmdlist_opened);

    const resource_desc = resource.GetDesc();

    var required_size: u64 = undefined;
    var layouts: [max_subresources]d3d12.PLACED_SUBRESOURCE_FOOTPRINT = undefined;
    var num_rows: [max_subresources]u32 = undefined;
    var row_sizes_in_bytes: [max_subresources]u64 = undefined;
    // TODO: pass first subresource in
    const first_subresource: u32 = 0;

    gfxstate.gctx.device.GetCopyableFootprints(
        &resource_desc,
        first_subresource,
        @intCast(c_uint, subresources.items.len),
        0,
        @ptrCast([*]d3d12.PLACED_SUBRESOURCE_FOOTPRINT, &layouts),
        @ptrCast([*]c_uint, &num_rows),
        @ptrCast([*]c_ulonglong, &row_sizes_in_bytes),
        &required_size,
    );

    // NOTE(gmodarelli): upload.cpu_slice is mapped
    const upload = gfxstate.gctx.allocateUploadBufferRegion(u8, @intCast(u32, required_size));

    var subresource_index: u32 = 0;
    while (subresource_index < subresources.items.len) : (subresource_index += 1) {
        assert(row_sizes_in_bytes[subresource_index] < std.math.maxInt(u32));
        // TODO(gmodarelli): Add support for cubemaps
        assert(layouts[subresource_index].Footprint.Depth == 1);

        const memcpy_dest = d3d12.MEMCPY_DEST{
            .pData = upload.cpu_slice.ptr + layouts[subresource_index].Offset,
            .RowPitch = layouts[subresource_index].Footprint.RowPitch,
            .SlicePitch = @intCast(c_uint, layouts[subresource_index].Footprint.RowPitch) * @intCast(c_uint, num_rows[subresource_index]),
        };

        var subresource = &subresources.items[subresource_index];
        var row: u32 = 0;
        while (row < num_rows[subresource_index]) : (row += 1) {
            @memcpy(
                memcpy_dest.pData.? + (memcpy_dest.RowPitch * row),
                subresource.pData.? + (subresource.RowPitch * row),
                row_sizes_in_bytes[subresource_index],
            );
        }
    }

    subresource_index = 0;
    while (subresource_index < subresources.items.len) : (subresource_index += 1) {
        const dest = d3d12.TEXTURE_COPY_LOCATION{
            .pResource = resource,
            .Type = .SUBRESOURCE_INDEX,
            .u = .{ .SubresourceIndex = subresource_index },
        };

        const source = d3d12.TEXTURE_COPY_LOCATION{
            .pResource = upload.buffer,
            .Type = .PLACED_FOOTPRINT,
            .u = .{ .PlacedFootprint = layouts[subresource_index] },
        };

        gfxstate.gctx.cmdlist.CopyTextureRegion(&dest, 0, 0, 0, &source, null);
    }

    const barrier = d3d12.RESOURCE_BARRIER{
        .Type = .TRANSITION,
        .Flags = .{},
        .u = .{
            .Transition = .{
                .pResource = resource,
                .Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
                .StateBefore = .{ .COPY_DEST = true },
                .StateAfter = state_after,
            },
        },
    };
    var barriers = [_]d3d12.RESOURCE_BARRIER{barrier};
    gfxstate.gctx.cmdlist.ResourceBarrier(1, &barriers);
}

fn loadTerrainLayer(
    name: []const u8,
    arena: std.mem.Allocator,
    gfxstate: *gfx.D3D12State,
    textures_heap: *d3d12.IHeap,
    heap_size: u64,
    textures_heap_offset: *u64,
) !TerrainLayer {
    // TODO:(gmodarelli) Convert this main blk into a createTextureFromDDSFile function
    const diffuse = blk: {
        // Generate Path
        var namebuf: [256]u8 = undefined;
        const path = std.fmt.bufPrintZ(
            namebuf[0..namebuf.len],
            "content/textures/{s}_diff_2k.dds",
            .{name},
        ) catch unreachable;

        break :blk createDDSTextureFromFile(path, arena, gfxstate, textures_heap, heap_size, textures_heap_offset) catch unreachable;
    };

    const normal = blk: {
        // Generate Path
        var namebuf: [256]u8 = undefined;
        const path = std.fmt.bufPrintZ(
            namebuf[0..namebuf.len],
            "content/textures/{s}_nor_dx_2k.dds",
            .{name},
        ) catch unreachable;

        break :blk createDDSTextureFromFile(path, arena, gfxstate, textures_heap, heap_size, textures_heap_offset) catch unreachable;
    };

    const arm = blk: {
        // Generate Path
        var namebuf: [256]u8 = undefined;
        const path = std.fmt.bufPrintZ(
            namebuf[0..namebuf.len],
            "content/textures/{s}_arm_2k.dds",
            .{name},
        ) catch unreachable;

        break :blk createDDSTextureFromFile(path, arena, gfxstate, textures_heap, heap_size, textures_heap_offset) catch unreachable;
    };

    return .{
        .diffuse = gfxstate.texture_pool.addTexture(diffuse),
        .normal = gfxstate.texture_pool.addTexture(normal),
        .arm = gfxstate.texture_pool.addTexture(arm),
    };
}

fn loadHeightAndSplatMaps(
    gfxstate: *gfx.D3D12State,
    textures_heap: *d3d12.IHeap,
    heap_size: u64,
    textures_heap_offset: *u64,
    node: *QuadTreeNode,
) !void {
    var heightmap_namebuf: [256]u8 = undefined;
    const heightmap_path = std.fmt.bufPrintZ(
        heightmap_namebuf[0..heightmap_namebuf.len],
        "content/patch/lod{}/heightmap_x{}_y{}.png",
        .{
            node.mesh_lod,
            node.patch_index[0],
            node.patch_index[1],
        },
    ) catch unreachable;

    var splatmap_namebuf: [256]u8 = undefined;
    const splatmap_path = std.fmt.bufPrintZ(
        splatmap_namebuf[0..splatmap_namebuf.len],
        "content/patch/splatmap/lod{}/heightmap_x{}_y{}.png",
        .{
            node.mesh_lod,
            node.patch_index[0],
            node.patch_index[1],
        },
    ) catch unreachable;

    var heightmap_texture_data = loadTexture(&gfxstate.gctx, heightmap_path) catch unreachable;
    defer _ = heightmap_texture_data.image.Release();
    var splatmap_texture_data = loadTexture(&gfxstate.gctx, splatmap_path) catch unreachable;
    defer _ = splatmap_texture_data.image.Release();

    const heightmap_wh = blk: {
        var width: u32 = undefined;
        var height: u32 = undefined;
        hrPanicOnFail(heightmap_texture_data.image.GetSize(&width, &height));
        break :blk .{ .w = width, .h = height };
    };

    var heightmap_texture_resource = allocateTextureMemory(
        gfxstate,
        textures_heap,
        heap_size,
        textures_heap_offset,
        heightmap_wh.w,
        heightmap_wh.h,
        heightmap_texture_data.format,
        1,
    ) catch unreachable;

    uploadDataToTexture(gfxstate, heightmap_texture_resource, heightmap_texture_data.image, d3d12.RESOURCE_STATES.GENERIC_READ) catch unreachable;

    const splatmap_wh = blk: {
        var width: u32 = undefined;
        var splat: u32 = undefined;
        hrPanicOnFail(splatmap_texture_data.image.GetSize(&width, &splat));
        break :blk .{ .w = width, .h = splat };
    };

    var splatmap_texture_resource = allocateTextureMemory(
        gfxstate,
        textures_heap,
        heap_size,
        textures_heap_offset,
        splatmap_wh.w,
        splatmap_wh.h,
        splatmap_texture_data.format,
        1,
    ) catch unreachable;

    uploadDataToTexture(gfxstate, splatmap_texture_resource, splatmap_texture_data.image, d3d12.RESOURCE_STATES.GENERIC_READ) catch unreachable;

    const heightmap = blk: {
        const srv_allocation = gfxstate.gctx.allocatePersistentGpuDescriptors(1);
        gfxstate.gctx.device.CreateShaderResourceView(
            heightmap_texture_resource,
            null,
            srv_allocation.cpu_handle,
        );

        const t = gfx.Texture{
            .resource = heightmap_texture_resource,
            .persistent_descriptor = srv_allocation,
        };

        break :blk t;
    };

    const splatmap = blk: {
        const srv_allocation = gfxstate.gctx.allocatePersistentGpuDescriptors(1);
        gfxstate.gctx.device.CreateShaderResourceView(
            splatmap_texture_resource,
            null,
            srv_allocation.cpu_handle,
        );

        const t = gfx.Texture{
            .resource = splatmap_texture_resource,
            .persistent_descriptor = srv_allocation,
        };

        break :blk t;
    };

    node.heightmap_handle = gfxstate.texture_pool.addTexture(heightmap);
    node.splatmap_handle = gfxstate.texture_pool.addTexture(splatmap);
}

fn loadResources(
    allocator: std.mem.Allocator,
    quad_tree_nodes: *std.ArrayList(QuadTreeNode),
    gfxstate: *gfx.D3D12State,
    textures_heap: *d3d12.IHeap,
    textures_heap_offset: *u64,
    meshes: *std.ArrayList(Mesh),
    meshes_indices: *std.ArrayList(IndexType),
    meshes_vertices: *std.ArrayList(Vertex),
    terrain_layers: *std.ArrayList(TerrainLayer),
) !void {
    loadMesh(allocator, "content/meshes/LOD0.obj", meshes, meshes_indices, meshes_vertices) catch unreachable;
    loadMesh(allocator, "content/meshes/LOD1.obj", meshes, meshes_indices, meshes_vertices) catch unreachable;
    loadMesh(allocator, "content/meshes/LOD2.obj", meshes, meshes_indices, meshes_vertices) catch unreachable;
    loadMesh(allocator, "content/meshes/LOD3.obj", meshes, meshes_indices, meshes_vertices) catch unreachable;

    var heap_desc = textures_heap.GetDesc();

    // Load terrain layers textures
    {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const dry_ground = loadTerrainLayer("dry_ground_rocks", arena, gfxstate, textures_heap, heap_desc.SizeInBytes, textures_heap_offset) catch unreachable;
        const forest_ground = loadTerrainLayer("forrest_ground_01", arena, gfxstate, textures_heap, heap_desc.SizeInBytes, textures_heap_offset) catch unreachable;
        const rock_ground = loadTerrainLayer("rock_ground", arena, gfxstate, textures_heap, heap_desc.SizeInBytes, textures_heap_offset) catch unreachable;
        const snow = loadTerrainLayer("snow_02", arena, gfxstate, textures_heap, heap_desc.SizeInBytes, textures_heap_offset) catch unreachable;

        // NOTE: There's an implicit dependency on the order of the Splatmap here
        // - 0 dirt
        // - 1 grass
        // - 2 rock
        // - 3 snow
        terrain_layers.append(dry_ground) catch unreachable;
        terrain_layers.append(forest_ground) catch unreachable;
        terrain_layers.append(rock_ground) catch unreachable;
        terrain_layers.append(snow) catch unreachable;
    }

    // TODO: Schedule the upload instead of uploading immediately
    gfxstate.gctx.beginFrame();
    // Load all LOD's heightmaps
    {
        var i: u32 = 0;
        while (i < quad_tree_nodes.items.len) : (i += 1) {
            var node = &quad_tree_nodes.items[i];
            loadHeightAndSplatMaps(gfxstate, textures_heap, heap_desc.SizeInBytes, textures_heap_offset, node) catch unreachable;
        }
    }

    // TODO: Schedule the upload instead of uploading immediately
    gfxstate.gctx.endFrame();
    gfxstate.gctx.finishGpuCommands();
}

fn divideQuadTreeNode(
    nodes: *std.ArrayList(QuadTreeNode),
    node: *QuadTreeNode,
) void {
    if (node.mesh_lod == 0) {
        return;
    }

    const invalid_index = std.math.maxInt(u32);
    var child_index: u32 = 0;
    while (child_index < 4) : (child_index += 1) {
        var center_x = if (child_index % 2 == 0) node.center[0] - node.size[0] * 0.5 else node.center[0] + node.size[0] * 0.5;
        var center_y = if (child_index < 2) node.center[1] - node.size[1] * 0.5 else node.center[1] + node.size[1] * 0.5;
        var patch_index_x: u32 = if (child_index % 2 == 0) 0 else 1;
        var patch_index_y: u32 = if (child_index < 2) 1 else 0;

        var child_node = QuadTreeNode{
            .center = [2]f32{ center_x, center_y },
            .size = [2]f32{ node.size[0] * 0.5, node.size[1] * 0.5 },
            .child_indices = [4]u32{ invalid_index, invalid_index, invalid_index, invalid_index },
            .mesh_lod = node.mesh_lod - 1,
            .patch_index = [2]u32{ node.patch_index[0] * 2 + patch_index_x, node.patch_index[1] * 2 + patch_index_y },
            .heightmap_handle = undefined,
            .splatmap_handle = undefined,
        };

        node.child_indices[child_index] = @intCast(u32, nodes.items.len);
        nodes.appendAssumeCapacity(child_node);

        assert(node.child_indices[child_index] < nodes.items.len);
        divideQuadTreeNode(nodes, &nodes.items[node.child_indices[child_index]]);
    }
}

pub fn create(name: IdLocal, allocator: std.mem.Allocator, gfxstate: *gfx.D3D12State, flecs_world: *flecs.World) !*SystemState {
    // Queries
    var query_builder_camera = flecs.QueryBuilder.init(flecs_world.*);
    _ = query_builder_camera
        .withReadonly(fd.Camera)
        .withReadonly(fd.Transform);
    var query_camera = query_builder_camera.buildQuery();

    var query_builder_lights = flecs.QueryBuilder.init(flecs_world.*);
    _ = query_builder_lights
        .with(fd.Light)
        .with(fd.Transform);
    var query_lights = query_builder_lights.buildQuery();

    // NOTE(gmodarelli): This should be part of gfx_d3d12.zig or texture.zig
    // but for now it's here to speed test it out and speed things along
    // NOTE(gmodarelli): We're currently loading 85 1-channel PNGs per sector, so we need roughly
    // 100MB of space.
    const heap_desc = d3d12.HEAP_DESC{
        .SizeInBytes = 1000 * 1024 * 1024,
        .Properties = d3d12.HEAP_PROPERTIES.initType(.DEFAULT),
        .Alignment = 0, // 64KiB
        .Flags = d3d12.HEAP_FLAGS.ALLOW_ONLY_NON_RT_DS_TEXTURES,
    };
    var textures_heap: *d3d12.IHeap = undefined;
    hrPanicOnFail(gfxstate.gctx.device.CreateHeap(&heap_desc, &d3d12.IID_IHeap, @ptrCast(*?*anyopaque, &textures_heap)));
    var textures_heap_offset: u64 = 0;

    const invalid_index = std.math.maxInt(u32);
    // TODO(gmodarelli): This is just enough for a single sector, but it's good for testing
    const max_quad_tree_nodes: usize = 85 * 64;
    var terrain_quad_tree_nodes = std.ArrayList(QuadTreeNode).initCapacity(allocator, max_quad_tree_nodes) catch unreachable;
    var quads_to_render = std.ArrayList(u32).init(allocator);

    // Create initial sectors
    {
        var patch_half_size = @intToFloat(f32, config.patch_width) / 2.0;
        var patch_y: u32 = 0;
        while (patch_y < 8) : (patch_y += 1) {
            var patch_x: u32 = 0;
            while (patch_x < 8) : (patch_x += 1) {
                terrain_quad_tree_nodes.appendAssumeCapacity(.{
                    .center = [2]f32{ @intToFloat(f32, patch_x * config.patch_width) - 2048.0, -(@intToFloat(f32, patch_y * config.patch_width)) + 2048.0 },
                    .size = [2]f32{ patch_half_size, patch_half_size },
                    .child_indices = [4]u32{ invalid_index, invalid_index, invalid_index, invalid_index },
                    .mesh_lod = 3,
                    .patch_index = [2]u32{ patch_x, patch_y },
                    .heightmap_handle = undefined,
                    .splatmap_handle = undefined,
                });
            }
        }

        assert(terrain_quad_tree_nodes.items.len == 64);

        var sector_index: u32 = 0;
        while (sector_index < 64) : (sector_index += 1) {
            var node = &terrain_quad_tree_nodes.items[sector_index];
            divideQuadTreeNode(&terrain_quad_tree_nodes, node);
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    zmesh.init(arena);
    defer zmesh.deinit();

    var meshes = std.ArrayList(Mesh).init(allocator);
    var meshes_indices = std.ArrayList(IndexType).init(arena);
    var meshes_vertices = std.ArrayList(Vertex).init(arena);
    var terrain_layers = std.ArrayList(TerrainLayer).init(arena);
    loadResources(allocator, &terrain_quad_tree_nodes, gfxstate, textures_heap, &textures_heap_offset, &meshes, &meshes_indices, &meshes_vertices, &terrain_layers) catch unreachable;

    const total_num_vertices = @intCast(u32, meshes_vertices.items.len);
    const total_num_indices = @intCast(u32, meshes_indices.items.len);

    // Create a vertex buffer.
    var vertex_buffer = gfxstate.createBuffer(.{
        .size = total_num_vertices * @sizeOf(Vertex),
        .state = d3d12.RESOURCE_STATES.GENERIC_READ,
        .name = L("Terrain Quad Tree Vertex Buffer"),
        .persistent = true,
        .has_cbv = false,
        .has_srv = true,
        .has_uav = false,
    }) catch unreachable;

    // Create an index buffer.
    var index_buffer = gfxstate.createBuffer(.{
        .size = total_num_indices * @sizeOf(IndexType),
        .state = .{ .INDEX_BUFFER = true },
        .name = L("Terrain Quad Tree Index Buffer"),
        .persistent = false,
        .has_cbv = false,
        .has_srv = false,
        .has_uav = false,
    }) catch unreachable;

    var terrain_layers_buffer = gfxstate.createBuffer(.{
        .size = terrain_layers.items.len * @sizeOf(TerrainLayerTextureIndices),
        .state = d3d12.RESOURCE_STATES.GENERIC_READ,
        .name = L("Terrain Layers Buffer"),
        .persistent = true,
        .has_cbv = false,
        .has_srv = true,
        .has_uav = false,
    }) catch unreachable;

    // Create instance buffers.
    const instance_data_buffers = blk: {
        var buffers: [gfx.D3D12State.num_buffered_frames]gfx.BufferHandle = undefined;
        for (buffers) |_, buffer_index| {
            const bufferDesc = gfx.BufferDesc{
                .size = max_instances * @sizeOf(InstanceData),
                .state = d3d12.RESOURCE_STATES.GENERIC_READ,
                .name = L("Terrain Quad Tree Instance Data Buffer"),
                .persistent = true,
                .has_cbv = false,
                .has_srv = true,
                .has_uav = false,
            };

            buffers[buffer_index] = gfxstate.createBuffer(bufferDesc) catch unreachable;
        }

        break :blk buffers;
    };

    var draw_calls = std.ArrayList(DrawCall).init(allocator);
    var instance_data = std.ArrayList(InstanceData).init(allocator);

    gfxstate.scheduleUploadDataToBuffer(Vertex, vertex_buffer, 0, meshes_vertices.items);
    gfxstate.scheduleUploadDataToBuffer(IndexType, index_buffer, 0, meshes_indices.items);

    var terrain_layer_texture_indices = std.ArrayList(TerrainLayerTextureIndices).initCapacity(arena, terrain_layers.items.len) catch unreachable;
    var terrain_layer_index: u32 = 0;
    while (terrain_layer_index < terrain_layers.items.len) : (terrain_layer_index += 1) {
        const terrain_layer = &terrain_layers.items[terrain_layer_index];
        const diffuse = gfxstate.lookupTexture(terrain_layer.diffuse);
        const normal = gfxstate.lookupTexture(terrain_layer.normal);
        const arm = gfxstate.lookupTexture(terrain_layer.arm);
        terrain_layer_texture_indices.appendAssumeCapacity(.{
            .diffuse_index = diffuse.?.persistent_descriptor.index,
            .normal_index = normal.?.persistent_descriptor.index,
            .arm_index = arm.?.persistent_descriptor.index,
            .padding = 42,
        });
    }
    gfxstate.scheduleUploadDataToBuffer(TerrainLayerTextureIndices, terrain_layers_buffer, 0, terrain_layer_texture_indices.items);

    var state = allocator.create(SystemState) catch unreachable;
    var sys = flecs_world.newWrappedRunSystem(name.toCString(), .on_update, fd.NOCOMP, update, .{ .ctx = state });

    state.* = .{
        .allocator = allocator,
        .flecs_world = flecs_world,
        .sys = sys,
        .gfx = gfxstate,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .instance_data_buffers = instance_data_buffers,
        .draw_calls = draw_calls,
        .textures_heap = textures_heap,
        .textures_heap_offset = textures_heap_offset,
        .instance_data = instance_data,
        .terrain_layers_buffer = terrain_layers_buffer,
        .terrain_lod_meshes = meshes,
        .terrain_quad_tree_nodes = terrain_quad_tree_nodes,
        .quads_to_render = quads_to_render,
        .query_camera = query_camera,
        .query_lights = query_lights,
    };

    return state;
}

pub fn destroy(state: *SystemState) void {
    state.query_camera.deinit();
    state.query_lights.deinit();

    _ = state.textures_heap.Release();
    state.textures_heap.* = undefined;

    state.terrain_lod_meshes.deinit();
    state.instance_data.deinit();
    state.terrain_quad_tree_nodes.deinit();
    state.quads_to_render.deinit();
    state.draw_calls.deinit();
    state.allocator.destroy(state);
}

// ██╗   ██╗██████╗ ██████╗  █████╗ ████████╗███████╗
// ██║   ██║██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝██╔════╝
// ██║   ██║██████╔╝██║  ██║███████║   ██║   █████╗
// ██║   ██║██╔═══╝ ██║  ██║██╔══██║   ██║   ██╔══╝
// ╚██████╔╝██║     ██████╔╝██║  ██║   ██║   ███████╗
//  ╚═════╝ ╚═╝     ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝

fn update(iter: *flecs.Iterator(fd.NOCOMP)) void {
    var state = @ptrCast(*SystemState, @alignCast(@alignOf(SystemState), iter.iter.ctx));

    const CameraQueryComps = struct {
        cam: *const fd.Camera,
        transform: *const fd.Transform,
    };
    var camera_comps: ?CameraQueryComps = blk: {
        var entity_iter_camera = state.query_camera.iterator(CameraQueryComps);
        while (entity_iter_camera.next()) |comps| {
            if (comps.cam.active) {
                break :blk comps;
            }
        }

        break :blk null;
    };

    if (camera_comps == null) {
        return;
    }

    const cam = camera_comps.?.cam;
    const camera_position = camera_comps.?.transform.getPos00();
    const cam_world_to_clip = zm.loadMat(cam.world_to_clip[0..]);
    state.gpu_frame_profiler_index = state.gfx.gpu_profiler.startProfile(state.gfx.gctx.cmdlist, "Terrain Quad Tree");

    const pipeline_info = state.gfx.getPipeline(IdLocal.init("terrain_quad_tree"));
    state.gfx.gctx.setCurrentPipeline(pipeline_info.?.pipeline_handle);

    state.gfx.gctx.cmdlist.IASetPrimitiveTopology(.TRIANGLELIST);
    const index_buffer = state.gfx.lookupBuffer(state.index_buffer);
    const index_buffer_resource = state.gfx.gctx.lookupResource(index_buffer.?.resource);
    state.gfx.gctx.cmdlist.IASetIndexBuffer(&.{
        .BufferLocation = index_buffer_resource.?.GetGPUVirtualAddress(),
        .SizeInBytes = @intCast(c_uint, index_buffer_resource.?.GetDesc().Width),
        .Format = if (@sizeOf(IndexType) == 2) .R16_UINT else .R32_UINT,
    });

    // Upload per-frame constant data.
    {
        const environment_info = state.flecs_world.getSingletonMut(fd.EnvironmentInfo).?;
        const world_time = environment_info.world_time;
        const mem = state.gfx.gctx.allocateUploadMemory(FrameUniforms, 1);
        mem.cpu_slice[0].world_to_clip = zm.transpose(cam_world_to_clip);
        mem.cpu_slice[0].camera_position = camera_position;
        mem.cpu_slice[0].time = world_time;
        mem.cpu_slice[0].light_count = 0;

        var entity_iter_lights = state.query_lights.iterator(struct {
            light: *fd.Light,
            transform: *fd.Transform,
        });

        var light_i: u32 = 0;
        while (entity_iter_lights.next()) |comps| {
            const light_pos = comps.transform.getPos00();
            std.mem.copy(f32, mem.cpu_slice[0].light_positions[light_i][0..], light_pos[0..]);
            std.mem.copy(f32, mem.cpu_slice[0].light_radiances[light_i][0..3], comps.light.radiance.elemsConst().*[0..]);
            mem.cpu_slice[0].light_radiances[light_i][3] = comps.light.range;

            light_i += 1;
        }
        mem.cpu_slice[0].light_count = light_i;

        state.gfx.gctx.cmdlist.SetGraphicsRootConstantBufferView(1, mem.gpu_base);
    }

    // Reset transforms, materials and draw calls array list
    state.quads_to_render.clearRetainingCapacity();
    state.instance_data.clearRetainingCapacity();
    state.draw_calls.clearRetainingCapacity();

    {
        var sector_index: u32 = 0;
        while (sector_index < 64) : (sector_index += 1) {
            const lod3_node = &state.terrain_quad_tree_nodes.items[sector_index];
            const camera_point = [2]f32{ camera_position[0], camera_position[2] };

            collectQuadsToRenderForSector(
                camera_point,
                lod3_node,
                sector_index,
                &state.terrain_quad_tree_nodes,
                &state.quads_to_render,
            ) catch unreachable;
        }
    }

    {
        // TODO: Batch quads together by mesh lod
        var start_instance_location: u32 = 0;
        for (state.quads_to_render.items) |quad_index| {
            const quad = &state.terrain_quad_tree_nodes.items[quad_index];

            const object_to_world = zm.translation(quad.center[0], 0.0, quad.center[1]);
            // TODO: Generate from quad.patch_index
            const heightmap = state.gfx.lookupTexture(quad.heightmap_handle);
            const splatmap = state.gfx.lookupTexture(quad.splatmap_handle);
            // TODO: Add splatmap and UV offset and tiling (for atlases)
            state.instance_data.append(.{
                .object_to_world = zm.transpose(object_to_world),
                .heightmap_index = heightmap.?.persistent_descriptor.index,
                .splatmap_index = splatmap.?.persistent_descriptor.index,
                .padding1 = 42,
                .padding2 = 42,
            }) catch unreachable;

            const mesh = state.terrain_lod_meshes.items[quad.mesh_lod];

            state.draw_calls.append(.{
                .mesh_index = 0,
                .index_count = mesh.num_indices,
                .instance_count = 1,
                .index_offset = mesh.index_offset,
                .vertex_offset = mesh.vertex_offset,
                .start_instance_location = start_instance_location,
            }) catch unreachable;

            start_instance_location += 1;
        }
    }

    const frame_index = state.gfx.gctx.frame_index;
    if (state.instance_data.items.len > 0) {
        state.gfx.uploadDataToBuffer(InstanceData, state.instance_data_buffers[frame_index], 0, state.instance_data.items);
    }

    const vertex_buffer = state.gfx.lookupBuffer(state.vertex_buffer);
    const instance_data_buffer = state.gfx.lookupBuffer(state.instance_data_buffers[frame_index]);
    const terrain_layers_buffer = state.gfx.lookupBuffer(state.terrain_layers_buffer);

    for (state.draw_calls.items) |draw_call| {
        const mem = state.gfx.gctx.allocateUploadMemory(DrawUniforms, 1);
        mem.cpu_slice[0].start_instance_location = draw_call.start_instance_location;
        mem.cpu_slice[0].vertex_offset = draw_call.vertex_offset;
        mem.cpu_slice[0].vertex_buffer_index = vertex_buffer.?.persistent_descriptor.index;
        mem.cpu_slice[0].instance_data_buffer_index = instance_data_buffer.?.persistent_descriptor.index;
        mem.cpu_slice[0].terrain_layers_buffer_index = terrain_layers_buffer.?.persistent_descriptor.index;
        state.gfx.gctx.cmdlist.SetGraphicsRootConstantBufferView(0, mem.gpu_base);

        state.gfx.gctx.cmdlist.DrawIndexedInstanced(
            draw_call.index_count,
            draw_call.instance_count,
            draw_call.index_offset,
            draw_call.vertex_offset,
            draw_call.start_instance_location,
        );
    }

    state.gfx.gpu_profiler.endProfile(state.gfx.gctx.cmdlist, state.gpu_frame_profiler_index, state.gfx.gctx.frame_index);
}

// Algorithm that walks a quad tree and generates a list of quad tree nodes to render
fn collectQuadsToRenderForSector(position: [2]f32, node: *QuadTreeNode, node_index: u32, nodes: *std.ArrayList(QuadTreeNode), quads_to_render: *std.ArrayList(u32)) !void {
    assert(node_index != std.math.maxInt(u32));

    if (node.mesh_lod == 0) {
        return;
    }

    if (node.containedInsideChildren(position, nodes)) {
        var higher_lod_node_index: u32 = std.math.maxInt(u32);
        for (node.child_indices) |node_child_index| {
            var child_node = &nodes.items[node_child_index];
            if (child_node.containsPoint(position)) {
                if (child_node.mesh_lod == 1) {
                    quads_to_render.appendSlice(child_node.child_indices[0..4]) catch unreachable;
                } else {
                    higher_lod_node_index = node_child_index;
                }
            } else {
                quads_to_render.append(node_child_index) catch unreachable;
            }
        }

        if (higher_lod_node_index != std.math.maxInt(u32)) {
            var child_node = &nodes.items[higher_lod_node_index];
            collectQuadsToRenderForSector(position, child_node, higher_lod_node_index, nodes, quads_to_render) catch unreachable;
        }
    } else {
        quads_to_render.append(node_index) catch unreachable;
    }
}

//! wgpu render backend for dvui.
//!
//! Renders dvui's 2D triangles using wgpu-native.
//! Implements the dvui render backend interface: drawClippedTriangles,
//! textureCreate/Update/Destroy, begin, end.

const std = @import("std");
const dvui = @import("dvui");
const wgpu = @import("wgpu");

pub const kind: dvui.enums.RenderBackend = .wgpu;

const Vertex = dvui.Vertex;

// GPU state
device: wgpu.WGPUDevice,
queue: wgpu.WGPUQueue,
pipeline: wgpu.WGPURenderPipeline,
uniform_buffer: wgpu.WGPUBuffer,
uniform_bind_group: wgpu.WGPUBindGroup,
texture_bgl: wgpu.WGPUBindGroupLayout,
sampler: wgpu.WGPUSampler,
white_texture: wgpu.WGPUTexture,
white_view: wgpu.WGPUTextureView,
white_bind_group: wgpu.WGPUBindGroup,
surface_format: wgpu.WGPUTextureFormat,

// Dynamic buffers (capacity in bytes)
vertex_buffer: wgpu.WGPUBuffer,
vertex_buf_size: u64,
index_buffer: wgpu.WGPUBuffer,
index_buf_size: u64,

// Per-frame sub-allocation offsets (bytes)
vtx_byte_offset: u64 = 0,
idx_byte_offset: u64 = 0,

// Frame state
current_pass: ?wgpu.WGPURenderPassEncoder = null,
command_encoder: ?wgpu.WGPUCommandEncoder = null,
main_surface_view: ?wgpu.WGPUTextureView = null,
viewport_width: f32 = 0,
viewport_height: f32 = 0,

// Texture registry
textures: std.AutoHashMap(usize, wgpu.WGPUTextureView),
bind_groups: std.AutoHashMap(usize, wgpu.WGPUBindGroup),
// Render target textures (key = texture ptr → texture view for rendering into)
target_views: std.AutoHashMap(usize, wgpu.WGPUTextureView),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, device: wgpu.WGPUDevice, queue: wgpu.WGPUQueue, surface_format: wgpu.WGPUTextureFormat) !@This() {
    // Create shader module
    const shader_code = @embedFile("wgpu_shader.wgsl");
    var shader_source = wgpu.WGPUShaderSourceWGSL{
        .chain = .{ .next = null, .sType = wgpu.WGPUSType_ShaderSourceWGSL },
        .code = .{ .data = shader_code.ptr, .length = shader_code.len },
    };
    const shader_module = wgpu.wgpuDeviceCreateShaderModule(device, &wgpu.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&shader_source),
        .label = .{ .data = "dvui_shader", .length = 11 },
    }) orelse return error.BackendError;
    defer wgpu.wgpuShaderModuleRelease(shader_module);

    // Uniform bind group layout (group 0: projection matrix)
    const uniform_bgl = wgpu.wgpuDeviceCreateBindGroupLayout(device, &wgpu.WGPUBindGroupLayoutDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_uniform_bgl", .length = 16 },
        .entryCount = 1,
        .entries = &[_]wgpu.WGPUBindGroupLayoutEntry{.{
            .nextInChain = null,
            .binding = 0,
            .visibility = wgpu.WGPUShaderStage_Vertex,
            .buffer = .{
                .nextInChain = null,
                .type = wgpu.WGPUBufferBindingType_Uniform,
                .hasDynamicOffset = @intFromBool(false),
                .minBindingSize = 64,
            },
            .sampler = std.mem.zeroes(wgpu.WGPUSamplerBindingLayout),
            .texture = std.mem.zeroes(wgpu.WGPUTextureBindingLayout),
            .storageTexture = std.mem.zeroes(wgpu.WGPUStorageTextureBindingLayout),
        }},
    }) orelse return error.BackendError;
    defer wgpu.wgpuBindGroupLayoutRelease(uniform_bgl);

    // Texture bind group layout (group 1: texture + sampler)
    const texture_bgl = wgpu.wgpuDeviceCreateBindGroupLayout(device, &wgpu.WGPUBindGroupLayoutDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_texture_bgl", .length = 16 },
        .entryCount = 2,
        .entries = &[_]wgpu.WGPUBindGroupLayoutEntry{
            .{
                .nextInChain = null,
                .binding = 0,
                .visibility = wgpu.WGPUShaderStage_Fragment,
                .buffer = std.mem.zeroes(wgpu.WGPUBufferBindingLayout),
                .sampler = std.mem.zeroes(wgpu.WGPUSamplerBindingLayout),
                .texture = .{
                    .nextInChain = null,
                    .sampleType = wgpu.WGPUTextureSampleType_Float,
                    .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                    .multisampled = @intFromBool(false),
                },
                .storageTexture = std.mem.zeroes(wgpu.WGPUStorageTextureBindingLayout),
            },
            .{
                .nextInChain = null,
                .binding = 1,
                .visibility = wgpu.WGPUShaderStage_Fragment,
                .buffer = std.mem.zeroes(wgpu.WGPUBufferBindingLayout),
                .sampler = .{
                    .nextInChain = null,
                    .type = wgpu.WGPUSamplerBindingType_Filtering,
                },
                .texture = std.mem.zeroes(wgpu.WGPUTextureBindingLayout),
                .storageTexture = std.mem.zeroes(wgpu.WGPUStorageTextureBindingLayout),
            },
        },
    }) orelse return error.BackendError;

    // Pipeline layout
    const pipeline_layout = wgpu.wgpuDeviceCreatePipelineLayout(device, &wgpu.WGPUPipelineLayoutDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_pipeline_layout", .length = 20 },
        .bindGroupLayoutCount = 2,
        .bindGroupLayouts = &[_]wgpu.WGPUBindGroupLayout{ uniform_bgl, texture_bgl },
    }) orelse return error.BackendError;
    defer wgpu.wgpuPipelineLayoutRelease(pipeline_layout);

    // Render pipeline
    const vertex_attributes = [_]wgpu.WGPUVertexAttribute{
        .{ .format = wgpu.WGPUVertexFormat_Float32x2, .offset = @offsetOf(Vertex, "pos"), .shaderLocation = 0 },
        .{ .format = wgpu.WGPUVertexFormat_Unorm8x4, .offset = @offsetOf(Vertex, "col"), .shaderLocation = 1 },
        .{ .format = wgpu.WGPUVertexFormat_Float32x2, .offset = @offsetOf(Vertex, "uv"), .shaderLocation = 2 },
    };

    const pipeline = wgpu.wgpuDeviceCreateRenderPipeline(device, &wgpu.WGPURenderPipelineDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_pipeline", .length = 13 },
        .layout = pipeline_layout,
        .vertex = .{
            .nextInChain = null,
            .module = shader_module,
            .entryPoint = .{ .data = "vs_main", .length = 7 },
            .constantCount = 0,
            .constants = null,
            .bufferCount = 1,
            .buffers = &[_]wgpu.WGPUVertexBufferLayout{.{
                .arrayStride = @sizeOf(Vertex),
                .stepMode = wgpu.WGPUVertexStepMode_Vertex,
                .attributeCount = vertex_attributes.len,
                .attributes = &vertex_attributes,
            }},
        },
        .primitive = .{
            .nextInChain = null,
            .topology = wgpu.WGPUPrimitiveTopology_TriangleList,
            .stripIndexFormat = wgpu.WGPUIndexFormat_Undefined,
            .frontFace = wgpu.WGPUFrontFace_CCW,
            .cullMode = wgpu.WGPUCullMode_None,
            .unclippedDepth = @intFromBool(false),
        },
        .depthStencil = null,
        .multisample = .{
            .nextInChain = null,
            .count = 1,
            .mask = 0xFFFFFFFF,
            .alphaToCoverageEnabled = @intFromBool(false),
        },
        .fragment = &.{
            .nextInChain = null,
            .module = shader_module,
            .entryPoint = .{ .data = "fs_main", .length = 7 },
            .constantCount = 0,
            .constants = null,
            .targetCount = 1,
            .targets = &[_]wgpu.WGPUColorTargetState{.{
                .nextInChain = null,
                .format = surface_format,
                .blend = &.{
                    .color = .{
                        .operation = wgpu.WGPUBlendOperation_Add,
                        .srcFactor = wgpu.WGPUBlendFactor_One,
                        .dstFactor = wgpu.WGPUBlendFactor_OneMinusSrcAlpha,
                    },
                    .alpha = .{
                        .operation = wgpu.WGPUBlendOperation_Add,
                        .srcFactor = wgpu.WGPUBlendFactor_One,
                        .dstFactor = wgpu.WGPUBlendFactor_OneMinusSrcAlpha,
                    },
                },
                .writeMask = wgpu.WGPUColorWriteMask_All,
            }},
        },
    }) orelse return error.BackendError;

    // Uniform buffer (4x4 float matrix = 64 bytes)
    const uniform_buffer = wgpu.wgpuDeviceCreateBuffer(device, &wgpu.WGPUBufferDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_uniform", .length = 12 },
        .usage = wgpu.WGPUBufferUsage_Uniform | wgpu.WGPUBufferUsage_CopyDst,
        .size = 64,
        .mappedAtCreation = @intFromBool(false),
    }) orelse return error.BackendError;

    // Uniform bind group
    const uniform_bind_group = wgpu.wgpuDeviceCreateBindGroup(device, &wgpu.WGPUBindGroupDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_uniform_bg", .length = 15 },
        .layout = uniform_bgl,
        .entryCount = 1,
        .entries = &[_]wgpu.WGPUBindGroupEntry{.{
            .nextInChain = null,
            .binding = 0,
            .buffer = uniform_buffer,
            .offset = 0,
            .size = 64,
            .sampler = null,
            .textureView = null,
        }},
    }) orelse return error.BackendError;

    // Sampler
    const sampler = wgpu.wgpuDeviceCreateSampler(device, &wgpu.WGPUSamplerDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_sampler", .length = 12 },
        .addressModeU = wgpu.WGPUAddressMode_ClampToEdge,
        .addressModeV = wgpu.WGPUAddressMode_ClampToEdge,
        .addressModeW = wgpu.WGPUAddressMode_ClampToEdge,
        .magFilter = wgpu.WGPUFilterMode_Linear,
        .minFilter = wgpu.WGPUFilterMode_Linear,
        .mipmapFilter = wgpu.WGPUMipmapFilterMode_Nearest,
        .lodMinClamp = 0.0,
        .lodMaxClamp = 1.0,
        .compare = wgpu.WGPUCompareFunction_Undefined,
        .maxAnisotropy = 1,
    }) orelse return error.BackendError;

    // White 1x1 texture (fallback for untextured draws)
    const white_pixel = [_]u8{ 255, 255, 255, 255 };
    const white_texture = wgpu.wgpuDeviceCreateTexture(device, &wgpu.WGPUTextureDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_white", .length = 10 },
        .usage = wgpu.WGPUTextureUsage_TextureBinding | wgpu.WGPUTextureUsage_CopyDst,
        .dimension = wgpu.WGPUTextureDimension_2D,
        .size = .{ .width = 1, .height = 1, .depthOrArrayLayers = 1 },
        .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
        .mipLevelCount = 1,
        .sampleCount = 1,
        .viewFormatCount = 0,
        .viewFormats = null,
    }) orelse return error.BackendError;

    wgpu.wgpuQueueWriteTexture(queue, &.{
        .texture = white_texture,
        .mipLevel = 0,
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .aspect = wgpu.WGPUTextureAspect_All,
    }, &white_pixel, white_pixel.len, &.{
        .offset = 0,
        .bytesPerRow = 4,
        .rowsPerImage = 1,
    }, &.{ .width = 1, .height = 1, .depthOrArrayLayers = 1 });

    const white_view = wgpu.wgpuTextureCreateView(white_texture, null) orelse return error.BackendError;

    const white_bind_group = wgpu.wgpuDeviceCreateBindGroup(device, &wgpu.WGPUBindGroupDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_white_bg", .length = 13 },
        .layout = texture_bgl,
        .entryCount = 2,
        .entries = &[_]wgpu.WGPUBindGroupEntry{
            .{ .nextInChain = null, .binding = 0, .buffer = null, .offset = 0, .size = 0, .sampler = null, .textureView = white_view },
            .{ .nextInChain = null, .binding = 1, .buffer = null, .offset = 0, .size = 0, .sampler = sampler, .textureView = null },
        },
    }) orelse return error.BackendError;

    // Initial vertex/index buffers (sized in bytes)
    const initial_vtx_size: u64 = 4096 * @sizeOf(Vertex);
    const initial_idx_size: u64 = 8192 * @sizeOf(Vertex.Index);

    const vertex_buffer = wgpu.wgpuDeviceCreateBuffer(device, &wgpu.WGPUBufferDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_vtx", .length = 8 },
        .usage = wgpu.WGPUBufferUsage_Vertex | wgpu.WGPUBufferUsage_CopyDst,
        .size = initial_vtx_size,
        .mappedAtCreation = @intFromBool(false),
    }) orelse return error.BackendError;

    const index_buffer = wgpu.wgpuDeviceCreateBuffer(device, &wgpu.WGPUBufferDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_idx", .length = 8 },
        .usage = wgpu.WGPUBufferUsage_Index | wgpu.WGPUBufferUsage_CopyDst,
        .size = initial_idx_size,
        .mappedAtCreation = @intFromBool(false),
    }) orelse return error.BackendError;

    return .{
        .device = device,
        .queue = queue,
        .pipeline = pipeline,
        .uniform_buffer = uniform_buffer,
        .uniform_bind_group = uniform_bind_group,
        .texture_bgl = texture_bgl,
        .sampler = sampler,
        .white_texture = white_texture,
        .white_view = white_view,
        .white_bind_group = white_bind_group,
        .surface_format = surface_format,
        .vertex_buffer = vertex_buffer,
        .vertex_buf_size = initial_vtx_size,
        .index_buffer = index_buffer,
        .index_buf_size = initial_idx_size,
        .textures = std.AutoHashMap(usize, wgpu.WGPUTextureView).init(allocator),
        .bind_groups = std.AutoHashMap(usize, wgpu.WGPUBindGroup).init(allocator),
        .target_views = std.AutoHashMap(usize, wgpu.WGPUTextureView).init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *@This()) void {
    wgpu.wgpuBindGroupRelease(self.white_bind_group);
    wgpu.wgpuTextureViewRelease(self.white_view);
    wgpu.wgpuTextureRelease(self.white_texture);
    wgpu.wgpuSamplerRelease(self.sampler);
    wgpu.wgpuBufferRelease(self.uniform_buffer);
    wgpu.wgpuBindGroupRelease(self.uniform_bind_group);
    wgpu.wgpuBufferRelease(self.vertex_buffer);
    wgpu.wgpuBufferRelease(self.index_buffer);
    wgpu.wgpuRenderPipelineRelease(self.pipeline);

    var it = self.bind_groups.valueIterator();
    while (it.next()) |bg| wgpu.wgpuBindGroupRelease(bg.*);
    self.bind_groups.deinit();

    var vit = self.textures.valueIterator();
    while (vit.next()) |tv| wgpu.wgpuTextureViewRelease(tv.*);
    self.textures.deinit();

    var tit = self.target_views.valueIterator();
    while (tit.next()) |tv| wgpu.wgpuTextureViewRelease(tv.*);
    self.target_views.deinit();
}

pub fn setRenderPass(self: *@This(), pass: wgpu.WGPURenderPassEncoder) void {
    self.current_pass = pass;
}

pub fn setCommandEncoder(self: *@This(), encoder: wgpu.WGPUCommandEncoder, surface_view: wgpu.WGPUTextureView) void {
    self.command_encoder = encoder;
    self.main_surface_view = surface_view;
}

pub fn setViewportSize(self: *@This(), size: struct { width: f32, height: f32 }) void {
    self.viewport_width = size.width;
    self.viewport_height = size.height;

    // Update orthographic projection matrix
    const w = size.width;
    const h = size.height;
    const projection = [16]f32{
        2.0 / w, 0,        0, 0,
        0,       -2.0 / h, 0, 0,
        0,       0,        1, 0,
        -1,      1,        0, 1,
    };
    wgpu.wgpuQueueWriteBuffer(self.queue, self.uniform_buffer, 0, &projection, @sizeOf(@TypeOf(projection)));
}

pub fn begin(self: *@This(), _: std.mem.Allocator) !void {
    self.vtx_byte_offset = 0;
    self.idx_byte_offset = 0;
}

pub fn end(_: *@This()) !void {}

pub fn drawClippedTriangles(self: *@This(), _: dvui.Size.Physical, texture: ?dvui.Texture, vtx: []const Vertex, idx: []const Vertex.Index, clipr: ?dvui.Rect.Physical) !void {
    const pass = self.current_pass orelse return;

    if (vtx.len == 0 or idx.len == 0) return;

    const vtx_bytes: u64 = @intCast(vtx.len * @sizeOf(Vertex));
    const idx_bytes: u64 = @intCast(idx.len * @sizeOf(Vertex.Index));

    // wgpu requires COPY_BUFFER_ALIGNMENT (4 bytes) for writeBuffer size and offset
    const copy_align: u64 = 4;
    const vtx_bytes_aligned = (vtx_bytes + copy_align - 1) & ~(copy_align - 1);
    const idx_bytes_aligned = (idx_bytes + copy_align - 1) & ~(copy_align - 1);

    // Grow buffers if accumulated data exceeds capacity
    const needed_vtx = self.vtx_byte_offset + vtx_bytes_aligned;
    const needed_idx = self.idx_byte_offset + idx_bytes_aligned;

    if (needed_vtx > self.vertex_buf_size) {
        wgpu.wgpuBufferRelease(self.vertex_buffer);
        self.vertex_buf_size = @max(needed_vtx, self.vertex_buf_size * 2);
        self.vertex_buffer = wgpu.wgpuDeviceCreateBuffer(self.device, &wgpu.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = .{ .data = "dvui_vtx", .length = 8 },
            .usage = wgpu.WGPUBufferUsage_Vertex | wgpu.WGPUBufferUsage_CopyDst,
            .size = self.vertex_buf_size,
            .mappedAtCreation = @intFromBool(false),
        }) orelse return error.BackendError;
    }
    if (needed_idx > self.index_buf_size) {
        wgpu.wgpuBufferRelease(self.index_buffer);
        self.index_buf_size = @max(needed_idx, self.index_buf_size * 2);
        self.index_buffer = wgpu.wgpuDeviceCreateBuffer(self.device, &wgpu.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = .{ .data = "dvui_idx", .length = 8 },
            .usage = wgpu.WGPUBufferUsage_Index | wgpu.WGPUBufferUsage_CopyDst,
            .size = self.index_buf_size,
            .mappedAtCreation = @intFromBool(false),
        }) orelse return error.BackendError;
    }

    // Upload data at current offset (sub-allocated)
    wgpu.wgpuQueueWriteBuffer(self.queue, self.vertex_buffer, self.vtx_byte_offset, vtx.ptr, vtx_bytes_aligned);
    wgpu.wgpuQueueWriteBuffer(self.queue, self.index_buffer, self.idx_byte_offset, idx.ptr, idx_bytes_aligned);

    // Set pipeline and bind groups
    wgpu.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
    wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.uniform_bind_group, 0, null);

    // Texture bind group
    const tex_bg = if (texture) |t| blk: {
        const key = @intFromPtr(t.ptr);
        break :blk self.bind_groups.get(key) orelse self.white_bind_group;
    } else self.white_bind_group;
    wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, tex_bg, 0, null);

    // Scissor rect
    if (clipr) |clip| {
        const x: u32 = @intFromFloat(@max(0, clip.x));
        const y: u32 = @intFromFloat(@max(0, clip.y));
        const w: u32 = @intFromFloat(@max(0, clip.w));
        const h: u32 = @intFromFloat(@max(0, clip.h));
        wgpu.wgpuRenderPassEncoderSetScissorRect(pass, x, y, w, h);
    } else {
        wgpu.wgpuRenderPassEncoderSetScissorRect(pass, 0, 0, @intFromFloat(self.viewport_width), @intFromFloat(self.viewport_height));
    }

    // Bind this batch's slice of the buffer and draw
    const index_format = if (@sizeOf(Vertex.Index) == 2) wgpu.WGPUIndexFormat_Uint16 else wgpu.WGPUIndexFormat_Uint32;
    wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vertex_buffer, self.vtx_byte_offset, vtx_bytes_aligned);
    wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, self.index_buffer, index_format, self.idx_byte_offset, idx_bytes_aligned);
    wgpu.wgpuRenderPassEncoderDrawIndexed(pass, @intCast(idx.len), 1, 0, 0, 0);

    // Advance offsets for next batch
    self.vtx_byte_offset += vtx_bytes_aligned;
    self.idx_byte_offset += idx_bytes_aligned;
}

pub fn textureCreate(self: *@This(), pixels: [*]const u8, width: u32, height: u32, _: dvui.enums.TextureInterpolation, _: dvui.enums.TexturePixelFormat) !dvui.Texture {
    const tex = wgpu.wgpuDeviceCreateTexture(self.device, &wgpu.WGPUTextureDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_tex", .length = 8 },
        .usage = wgpu.WGPUTextureUsage_TextureBinding | wgpu.WGPUTextureUsage_CopyDst,
        .dimension = wgpu.WGPUTextureDimension_2D,
        .size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 },
        .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
        .mipLevelCount = 1,
        .sampleCount = 1,
        .viewFormatCount = 0,
        .viewFormats = null,
    }) orelse return error.TextureCreate;

    // Upload pixel data
    wgpu.wgpuQueueWriteTexture(self.queue, &.{
        .texture = tex,
        .mipLevel = 0,
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .aspect = wgpu.WGPUTextureAspect_All,
    }, pixels, width * height * 4, &.{
        .offset = 0,
        .bytesPerRow = width * 4,
        .rowsPerImage = height,
    }, &.{ .width = width, .height = height, .depthOrArrayLayers = 1 });

    const view = wgpu.wgpuTextureCreateView(tex, null) orelse return error.TextureCreate;

    // Create bind group for this texture
    const bg = wgpu.wgpuDeviceCreateBindGroup(self.device, &wgpu.WGPUBindGroupDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_tex_bg", .length = 11 },
        .layout = self.texture_bgl,
        .entryCount = 2,
        .entries = &[_]wgpu.WGPUBindGroupEntry{
            .{ .nextInChain = null, .binding = 0, .buffer = null, .offset = 0, .size = 0, .sampler = null, .textureView = view },
            .{ .nextInChain = null, .binding = 1, .buffer = null, .offset = 0, .size = 0, .sampler = self.sampler, .textureView = null },
        },
    }) orelse return error.TextureCreate;

    const key = @intFromPtr(tex);
    try self.textures.put(key, view);
    try self.bind_groups.put(key, bg);

    return .{ .ptr = tex, .width = width, .height = height, .format = .rgba_32 };
}

pub fn textureUpdate(self: *@This(), texture: dvui.Texture, pixels: [*]const u8) !void {
    const key = @intFromPtr(texture.ptr);
    const tex: wgpu.WGPUTexture = @ptrCast(texture.ptr);
    _ = self.textures.get(key) orelse return error.TextureUpdate;

    wgpu.wgpuQueueWriteTexture(self.queue, &.{
        .texture = tex,
        .mipLevel = 0,
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .aspect = wgpu.WGPUTextureAspect_All,
    }, pixels, texture.width * texture.height * 4, &.{
        .offset = 0,
        .bytesPerRow = texture.width * 4,
        .rowsPerImage = texture.height,
    }, &.{ .width = texture.width, .height = texture.height, .depthOrArrayLayers = 1 });
}

pub fn textureDestroy(self: *@This(), texture: dvui.Texture) void {
    const key = @intFromPtr(texture.ptr);
    if (self.bind_groups.fetchRemove(key)) |kv| wgpu.wgpuBindGroupRelease(kv.value);
    if (self.textures.fetchRemove(key)) |kv| wgpu.wgpuTextureViewRelease(kv.value);
    const tex: wgpu.WGPUTexture = @ptrCast(texture.ptr);
    wgpu.wgpuTextureRelease(tex);
}

pub fn textureCreateTarget(self: *@This(), width: u32, height: u32, _: dvui.enums.TextureInterpolation, format: dvui.enums.TexturePixelFormat) !dvui.TextureTarget {
    _ = format;
    const tex = wgpu.wgpuDeviceCreateTexture(self.device, &wgpu.WGPUTextureDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_target", .length = 11 },
        .usage = wgpu.WGPUTextureUsage_RenderAttachment | wgpu.WGPUTextureUsage_TextureBinding | wgpu.WGPUTextureUsage_CopyDst | wgpu.WGPUTextureUsage_CopySrc,
        .dimension = wgpu.WGPUTextureDimension_2D,
        .size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 },
        .format = self.surface_format,
        .mipLevelCount = 1,
        .sampleCount = 1,
        .viewFormatCount = 0,
        .viewFormats = null,
    }) orelse return error.TextureCreate;

    const view = wgpu.wgpuTextureCreateView(tex, null) orelse {
        wgpu.wgpuTextureRelease(tex);
        return error.TextureCreate;
    };

    // Create bind group for sampling this texture
    const bg = wgpu.wgpuDeviceCreateBindGroup(self.device, &wgpu.WGPUBindGroupDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_target_bg", .length = 14 },
        .layout = self.texture_bgl,
        .entryCount = 2,
        .entries = &[_]wgpu.WGPUBindGroupEntry{
            .{ .nextInChain = null, .binding = 0, .buffer = null, .offset = 0, .size = 0, .sampler = null, .textureView = view },
            .{ .nextInChain = null, .binding = 1, .buffer = null, .offset = 0, .size = 0, .sampler = self.sampler, .textureView = null },
        },
    }) orelse {
        wgpu.wgpuTextureViewRelease(view);
        wgpu.wgpuTextureRelease(tex);
        return error.TextureCreate;
    };

    const key = @intFromPtr(tex);
    try self.textures.put(key, view);
    try self.bind_groups.put(key, bg);
    // Store a second view for rendering into this texture
    const render_view = wgpu.wgpuTextureCreateView(tex, null) orelse {
        return error.TextureCreate;
    };
    try self.target_views.put(key, render_view);

    return .{ .ptr = tex, .width = width, .height = height, .format = .rgba_32 };
}

pub fn textureFromTarget(_: *@This(), target: dvui.TextureTarget) dvui.Texture {
    return .{ .ptr = target.ptr, .width = target.width, .height = target.height, .format = target.format };
}

pub fn textureFromTargetTemp(_: *@This(), target: dvui.TextureTarget) dvui.Texture {
    return .{ .ptr = target.ptr, .width = target.width, .height = target.height, .format = target.format };
}

pub fn textureDestroyTarget(self: *@This(), texture: dvui.Texture.Target) void {
    const key = @intFromPtr(texture.ptr);
    if (self.bind_groups.fetchRemove(key)) |kv| wgpu.wgpuBindGroupRelease(kv.value);
    if (self.textures.fetchRemove(key)) |kv| wgpu.wgpuTextureViewRelease(kv.value);
    if (self.target_views.fetchRemove(key)) |kv| wgpu.wgpuTextureViewRelease(kv.value);
    const tex: wgpu.WGPUTexture = @ptrCast(texture.ptr);
    wgpu.wgpuTextureRelease(tex);
}

pub fn textureClearTarget(self: *@This(), texture: dvui.Texture.Target) void {
    const key = @intFromPtr(texture.ptr);
    const render_view = self.target_views.get(key) orelse return;
    const encoder = self.command_encoder orelse return;

    // End current pass temporarily
    if (self.current_pass) |pass| {
        wgpu.wgpuRenderPassEncoderEnd(pass);
        wgpu.wgpuRenderPassEncoderRelease(pass);
    }

    // Clear pass on the target
    const clear_pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &wgpu.WGPURenderPassDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_clear", .length = 10 },
        .colorAttachmentCount = 1,
        .colorAttachments = &wgpu.WGPURenderPassColorAttachment{
            .view = render_view,
            .depthSlice = wgpu.WGPU_DEPTH_SLICE_UNDEFINED,
            .resolveTarget = null,
            .loadOp = wgpu.WGPULoadOp_Clear,
            .storeOp = wgpu.WGPUStoreOp_Store,
            .clearValue = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
        },
        .depthStencilAttachment = null,
        .occlusionQuerySet = null,
        .timestampWrites = null,
    }) orelse {
        // Restore main pass
        self.restoreMainPass();
        return;
    };
    wgpu.wgpuRenderPassEncoderEnd(clear_pass);
    wgpu.wgpuRenderPassEncoderRelease(clear_pass);

    // Restore main pass
    self.restoreMainPass();
}

pub fn textureReadTarget(_: *@This(), _: dvui.TextureTarget, _: [*]u8) !void {
    return error.NotImplemented;
}

pub fn renderTarget(self: *@This(), maybe_target: ?dvui.TextureTarget) void {
    const encoder = self.command_encoder orelse return;

    // End current pass
    if (self.current_pass) |pass| {
        wgpu.wgpuRenderPassEncoderEnd(pass);
        wgpu.wgpuRenderPassEncoderRelease(pass);
        self.current_pass = null;
    }

    if (maybe_target) |target| {
        // Render to the texture target
        const key = @intFromPtr(target.ptr);
        const render_view = self.target_views.get(key) orelse return;

        const new_pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &wgpu.WGPURenderPassDescriptor{
            .nextInChain = null,
            .label = .{ .data = "dvui_rt", .length = 7 },
            .colorAttachmentCount = 1,
            .colorAttachments = &wgpu.WGPURenderPassColorAttachment{
                .view = render_view,
                .depthSlice = wgpu.WGPU_DEPTH_SLICE_UNDEFINED,
                .resolveTarget = null,
                .loadOp = wgpu.WGPULoadOp_Load,
                .storeOp = wgpu.WGPUStoreOp_Store,
                .clearValue = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
            },
            .depthStencilAttachment = null,
            .occlusionQuerySet = null,
            .timestampWrites = null,
        }) orelse return;

        self.current_pass = new_pass;

        // Update projection for the target size
        const w: f32 = @floatFromInt(target.width);
        const h: f32 = @floatFromInt(target.height);
        const projection = [16]f32{
            2.0 / w, 0,        0, 0,
            0,       -2.0 / h, 0, 0,
            0,       0,        1, 0,
            -1,      1,        0, 1,
        };
        wgpu.wgpuQueueWriteBuffer(self.queue, self.uniform_buffer, 0, &projection, @sizeOf(@TypeOf(projection)));
    } else {
        // Restore to main surface
        self.restoreMainPass();
    }
}

fn restoreMainPass(self: *@This()) void {
    const encoder = self.command_encoder orelse return;
    const surface_view = self.main_surface_view orelse return;

    const new_pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &wgpu.WGPURenderPassDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_main", .length = 9 },
        .colorAttachmentCount = 1,
        .colorAttachments = &wgpu.WGPURenderPassColorAttachment{
            .view = surface_view,
            .depthSlice = wgpu.WGPU_DEPTH_SLICE_UNDEFINED,
            .resolveTarget = null,
            .loadOp = wgpu.WGPULoadOp_Load,
            .storeOp = wgpu.WGPUStoreOp_Store,
            .clearValue = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        },
        .depthStencilAttachment = null,
        .occlusionQuerySet = null,
        .timestampWrites = null,
    }) orelse return;

    self.current_pass = new_pass;

    // Restore viewport projection
    const w = self.viewport_width;
    const h = self.viewport_height;
    const projection = [16]f32{
        2.0 / w, 0,        0, 0,
        0,       -2.0 / h, 0, 0,
        0,       0,        1, 0,
        -1,      1,        0, 1,
    };
    wgpu.wgpuQueueWriteBuffer(self.queue, self.uniform_buffer, 0, &projection, @sizeOf(@TypeOf(projection)));
}

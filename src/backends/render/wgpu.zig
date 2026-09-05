//! wgpu render backend for dvui.
//!
//! Renders dvui's 2D triangles using wgpu-native.
//! Implements the dvui render backend interface: drawClippedTriangles,
//! textureCreate/Update/Destroy, begin, end.
//!
//! ## The host has to poll the device
//!
//! wgpu defers the actual freeing of a released resource until the device is
//! polled. A windowed host gets that for free from `wgpuSurfacePresent`, but a
//! **headless** one — a test harness, an offscreen renderer — presents nothing,
//! so nothing released is ever freed and the device runs out of memory while
//! every `Release` call in here has already been made. Call
//! `wgpuDevicePoll(device, false, null)` once a frame.
//!
//! `renderTargetViewCount` / `textureViewCount` are there for a host to assert
//! on: over a steady UI they must come back to the same number every frame.

const std = @import("std");
const dvui = @import("dvui");
const wgpu = @import("wgpu");

pub const kind: dvui.enums.RenderBackend = .wgpu;

const Vertex = dvui.Vertex;

/// GPU instance data for SDF rounded rects (72 bytes per instance).
/// Must match the vertex attribute layout in the SDF pipeline.
const SdfInstanceData = extern struct {
    rect_pos: [2]f32, // top-left position
    rect_size: [2]f32, // width, height
    radii: [4]f32, // TL, TR, BR, BL corner radii
    fill_color: [4]f32, // premultiplied RGBA
    border_color: [4]f32, // premultiplied RGBA
    border_softness: [2]f32, // border_width, softness (unused for now)
};

/// WebGPU's `minUniformBufferOffsetAlignment` guaranteed limit. A dynamic
/// uniform offset must be a multiple of it, so each projection gets a 256-byte
/// slot even though it only fills 64 of them.
const uniform_slot_stride: u64 = 256;
/// One 4x4 f32 orthographic projection.
const uniform_slot_size: u64 = 64;
/// Slot 0 is the window's projection and is never recycled; the rest are a
/// per-frame ring for render-target switches. A `BlurBackdrop` capture costs
/// roughly 2*log2(radius) switches, so this is many panels' worth.
const uniform_slot_count: u32 = 256;

// GPU state
device: wgpu.WGPUDevice,
queue: wgpu.WGPUQueue,
pipeline: wgpu.WGPURenderPipeline,
sdf_pipeline: wgpu.WGPURenderPipeline,
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

// SDF instance buffer
sdf_instance_buffer: wgpu.WGPUBuffer,
sdf_instance_buf_size: u64,
sdf_instance_byte_offset: u64 = 0,

// Per-frame sub-allocation offsets (bytes)
vtx_byte_offset: u64 = 0,
idx_byte_offset: u64 = 0,

// Frame state
current_pass: ?wgpu.WGPURenderPassEncoder = null,
command_encoder: ?wgpu.WGPUCommandEncoder = null,
main_surface_view: ?wgpu.WGPUTextureView = null,
viewport_width: f32 = 0,
viewport_height: f32 = 0,
// Size of whatever the *current* pass draws into: the window while the main
// pass is bound, the texture while a render target is. Scissor rects are
// validated against the attachment, not against the window, so a pass that
// renders into a 961x844 target with the window's 1400x860 scissor is rejected
// -- and wgpu rejects the whole submitted command buffer for it, so one stray
// scissor loses the entire frame.
pass_width: f32 = 0,
pass_height: f32 = 0,
// One projection matrix per render-target switch, in a single uniform buffer
// read through dynamic offsets. See `writeProjection`.
// The render target the current pass writes into, or null for the window.
current_target_view: ?wgpu.WGPUTextureView = null,
uniform_slot: u32 = 0,
uniform_slots_used: u32 = 1,
uniform_overflow_logged: bool = false,

// Texture registry
textures: std.AutoHashMap(usize, wgpu.WGPUTextureView),
bind_groups: std.AutoHashMap(usize, wgpu.WGPUBindGroup),
// Render target textures (key = texture ptr → texture view for rendering into)
target_views: std.AutoHashMap(usize, wgpu.WGPUTextureView),
// Views wrapped with `textureWrap` (key = view ptr). The renderer owns only the
// bind group for these; the view and its texture stay with the caller.
wrapped: std.AutoHashMap(usize, void),
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
                // Dynamic: every pass in one command encoder reads the uniform
                // buffer as it is at *submit* time, so writing the projection
                // between passes gives every pass the last value written. An
                // offset per pass is the only way each can read its own.
                .hasDynamicOffset = @intFromBool(true),
                .minBindingSize = uniform_slot_size,
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

    // Uniform buffer: `uniform_slot_count` projections, one per render-target
    // switch, addressed by dynamic offset.
    const uniform_buffer = wgpu.wgpuDeviceCreateBuffer(device, &wgpu.WGPUBufferDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_uniform", .length = 12 },
        .usage = wgpu.WGPUBufferUsage_Uniform | wgpu.WGPUBufferUsage_CopyDst,
        .size = uniform_slot_stride * uniform_slot_count,
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
            // One slot; the dynamic offset picks which.
            .size = uniform_slot_size,
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

    // --- SDF Rounded Rect Pipeline ---
    const sdf_shader_code = @embedFile("wgpu_sdf_rect.wgsl");
    var sdf_shader_source = wgpu.WGPUShaderSourceWGSL{
        .chain = .{ .next = null, .sType = wgpu.WGPUSType_ShaderSourceWGSL },
        .code = .{ .data = sdf_shader_code.ptr, .length = sdf_shader_code.len },
    };
    const sdf_shader_module = wgpu.wgpuDeviceCreateShaderModule(device, &wgpu.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&sdf_shader_source),
        .label = .{ .data = "dvui_sdf_shader", .length = 15 },
    }) orelse return error.BackendError;
    defer wgpu.wgpuShaderModuleRelease(sdf_shader_module);

    // SDF pipeline layout (only needs uniform bind group, no texture)
    const sdf_pipeline_layout = wgpu.wgpuDeviceCreatePipelineLayout(device, &wgpu.WGPUPipelineLayoutDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_sdf_layout", .length = 15 },
        .bindGroupLayoutCount = 1,
        .bindGroupLayouts = &[_]wgpu.WGPUBindGroupLayout{uniform_bgl},
    }) orelse return error.BackendError;
    defer wgpu.wgpuPipelineLayoutRelease(sdf_pipeline_layout);

    // SDF instance attributes (per-instance data)
    const sdf_instance_attributes = [_]wgpu.WGPUVertexAttribute{
        .{ .format = wgpu.WGPUVertexFormat_Float32x2, .offset = 0, .shaderLocation = 0 }, // rect_pos
        .{ .format = wgpu.WGPUVertexFormat_Float32x2, .offset = 8, .shaderLocation = 1 }, // rect_size
        .{ .format = wgpu.WGPUVertexFormat_Float32x4, .offset = 16, .shaderLocation = 2 }, // radii
        .{ .format = wgpu.WGPUVertexFormat_Float32x4, .offset = 32, .shaderLocation = 3 }, // fill_color
        .{ .format = wgpu.WGPUVertexFormat_Float32x4, .offset = 48, .shaderLocation = 4 }, // border_color
        .{ .format = wgpu.WGPUVertexFormat_Float32x2, .offset = 64, .shaderLocation = 5 }, // border_softness
    };

    const sdf_pipeline = wgpu.wgpuDeviceCreateRenderPipeline(device, &wgpu.WGPURenderPipelineDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_sdf_pipe", .length = 13 },
        .layout = sdf_pipeline_layout,
        .vertex = .{
            .nextInChain = null,
            .module = sdf_shader_module,
            .entryPoint = .{ .data = "vs_main", .length = 7 },
            .constantCount = 0,
            .constants = null,
            .bufferCount = 1,
            .buffers = &[_]wgpu.WGPUVertexBufferLayout{.{
                .arrayStride = @sizeOf(SdfInstanceData),
                .stepMode = wgpu.WGPUVertexStepMode_Instance,
                .attributeCount = sdf_instance_attributes.len,
                .attributes = &sdf_instance_attributes,
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
            .module = sdf_shader_module,
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

    // SDF instance buffer
    const initial_sdf_size: u64 = 256 * @sizeOf(SdfInstanceData);
    const sdf_instance_buffer = wgpu.wgpuDeviceCreateBuffer(device, &wgpu.WGPUBufferDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_sdf_inst", .length = 13 },
        .usage = wgpu.WGPUBufferUsage_Vertex | wgpu.WGPUBufferUsage_CopyDst,
        .size = initial_sdf_size,
        .mappedAtCreation = @intFromBool(false),
    }) orelse return error.BackendError;

    return .{
        .device = device,
        .queue = queue,
        .pipeline = pipeline,
        .sdf_pipeline = sdf_pipeline,
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
        .sdf_instance_buffer = sdf_instance_buffer,
        .sdf_instance_buf_size = initial_sdf_size,
        .textures = std.AutoHashMap(usize, wgpu.WGPUTextureView).init(allocator),
        .bind_groups = std.AutoHashMap(usize, wgpu.WGPUBindGroup).init(allocator),
        .target_views = std.AutoHashMap(usize, wgpu.WGPUTextureView).init(allocator),
        .wrapped = std.AutoHashMap(usize, void).init(allocator),
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
    wgpu.wgpuBufferRelease(self.sdf_instance_buffer);
    wgpu.wgpuRenderPipelineRelease(self.pipeline);
    wgpu.wgpuRenderPipelineRelease(self.sdf_pipeline);

    var it = self.bind_groups.valueIterator();
    while (it.next()) |bg| wgpu.wgpuBindGroupRelease(bg.*);
    self.bind_groups.deinit();

    var vit = self.textures.valueIterator();
    while (vit.next()) |tv| wgpu.wgpuTextureViewRelease(tv.*);
    self.textures.deinit();

    var tit = self.target_views.valueIterator();
    while (tit.next()) |tv| wgpu.wgpuTextureViewRelease(tv.*);
    self.target_views.deinit();

    // Wrapped views are not ours; their bind groups were released above.
    self.wrapped.deinit();
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
    if (self.current_target_view == null) {
        self.pass_width = size.width;
        self.pass_height = size.height;
    }

    // Slot 0 holds the window's projection for the life of the window, so the
    // main pass never has to compete for a slot with the frame's target
    // switches.
    self.writeProjectionAt(0, size.width, size.height);
    self.uniform_slot = 0;
}

/// The orthographic projection for a `w` x `h` attachment, written into `slot`.
fn writeProjectionAt(self: *@This(), slot: u32, w: f32, h: f32) void {
    if (!(w > 0) or !(h > 0)) return;
    const projection = [16]f32{
        2.0 / w, 0,        0, 0,
        0,       -2.0 / h, 0, 0,
        0,       0,        1, 0,
        -1,      1,        0, 1,
    };
    const offset: u64 = @as(u64, slot) * uniform_slot_stride;
    wgpu.wgpuQueueWriteBuffer(self.queue, self.uniform_buffer, offset, &projection, @sizeOf(@TypeOf(projection)));
}

/// Take the next free slot in this frame's ring and write `w` x `h`'s
/// projection into it, so the pass about to be opened reads its own matrix.
fn writeProjection(self: *@This(), w: f32, h: f32) void {
    const slot = dvui.render.nextRingSlot(&self.uniform_slots_used, uniform_slot_count);
    if (slot == null and !self.uniform_overflow_logged) {
        self.uniform_overflow_logged = true;
        dvui.log.warn("wgpu: more than {d} render-target switches in one frame; later ones share a projection slot", .{uniform_slot_count - 1});
    }
    self.uniform_slot = slot orelse (uniform_slot_count - 1);
    self.writeProjectionAt(self.uniform_slot, w, h);
}

pub fn begin(self: *@This(), _: std.mem.Allocator) !void {
    self.vtx_byte_offset = 0;
    self.idx_byte_offset = 0;
    self.sdf_instance_byte_offset = 0;
    // Slot 0 stays the window's; the ring starts after it.
    self.uniform_slots_used = 1;
    self.uniform_overflow_logged = false;
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
    const uniform_offsets = [_]u32{@intCast(@as(u64, self.uniform_slot) * uniform_slot_stride)};
    wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.uniform_bind_group, 1, &uniform_offsets);

    // Texture bind group
    const tex_bg = if (texture) |t| blk: {
        const key = @intFromPtr(t.ptr);
        break :blk self.bind_groups.get(key) orelse self.white_bind_group;
    } else self.white_bind_group;
    wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, tex_bg, 0, null);

    // Scissor rect, clamped to whatever this pass draws into.
    const scissor = dvui.render.clampScissor(clipr, self.pass_width, self.pass_height);
    wgpu.wgpuRenderPassEncoderSetScissorRect(pass, scissor.x, scissor.y, scissor.w, scissor.h);

    // Bind this batch's slice of the buffer and draw
    const index_format = if (@sizeOf(Vertex.Index) == 2) wgpu.WGPUIndexFormat_Uint16 else wgpu.WGPUIndexFormat_Uint32;
    wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vertex_buffer, self.vtx_byte_offset, vtx_bytes_aligned);
    wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, self.index_buffer, index_format, self.idx_byte_offset, idx_bytes_aligned);
    wgpu.wgpuRenderPassEncoderDrawIndexed(pass, @intCast(idx.len), 1, 0, 0, 0);

    // Advance offsets for next batch
    self.vtx_byte_offset += vtx_bytes_aligned;
    self.idx_byte_offset += idx_bytes_aligned;
}

pub fn drawSdfRect(self: *@This(), sdf_rect: dvui.SdfRect, clipr: ?dvui.Rect.Physical) !void {
    const pass = self.current_pass orelse return;

    // Convert Color (u8 RGBA) to premultiplied f32
    const fill_pma = dvui.Color.PMA.fromColor(sdf_rect.fill_color);
    const border_pma = dvui.Color.PMA.fromColor(sdf_rect.border_color);

    const instance = SdfInstanceData{
        .rect_pos = .{ sdf_rect.pos.x, sdf_rect.pos.y },
        .rect_size = .{ sdf_rect.size.w, sdf_rect.size.h },
        .radii = .{ sdf_rect.radii.x, sdf_rect.radii.y, sdf_rect.radii.w, sdf_rect.radii.h },
        .fill_color = .{
            @as(f32, @floatFromInt(fill_pma.r)) / 255.0,
            @as(f32, @floatFromInt(fill_pma.g)) / 255.0,
            @as(f32, @floatFromInt(fill_pma.b)) / 255.0,
            @as(f32, @floatFromInt(fill_pma.a)) / 255.0,
        },
        .border_color = .{
            @as(f32, @floatFromInt(border_pma.r)) / 255.0,
            @as(f32, @floatFromInt(border_pma.g)) / 255.0,
            @as(f32, @floatFromInt(border_pma.b)) / 255.0,
            @as(f32, @floatFromInt(border_pma.a)) / 255.0,
        },
        .border_softness = .{ sdf_rect.border_width, sdf_rect.softness },
    };

    const inst_bytes: u64 = @sizeOf(SdfInstanceData);
    const copy_align: u64 = 4;
    const inst_bytes_aligned = (inst_bytes + copy_align - 1) & ~(copy_align - 1);

    // Grow buffer if needed
    const needed = self.sdf_instance_byte_offset + inst_bytes_aligned;
    if (needed > self.sdf_instance_buf_size) {
        wgpu.wgpuBufferRelease(self.sdf_instance_buffer);
        self.sdf_instance_buf_size = @max(needed, self.sdf_instance_buf_size * 2);
        self.sdf_instance_buffer = wgpu.wgpuDeviceCreateBuffer(self.device, &wgpu.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = .{ .data = "dvui_sdf_inst", .length = 13 },
            .usage = wgpu.WGPUBufferUsage_Vertex | wgpu.WGPUBufferUsage_CopyDst,
            .size = self.sdf_instance_buf_size,
            .mappedAtCreation = @intFromBool(false),
        }) orelse return error.BackendError;
    }

    // Upload instance data
    wgpu.wgpuQueueWriteBuffer(self.queue, self.sdf_instance_buffer, self.sdf_instance_byte_offset, @as([*]const u8, @ptrCast(&instance)), inst_bytes_aligned);

    // Set SDF pipeline
    wgpu.wgpuRenderPassEncoderSetPipeline(pass, self.sdf_pipeline);
    const uniform_offsets = [_]u32{@intCast(@as(u64, self.uniform_slot) * uniform_slot_stride)};
    wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.uniform_bind_group, 1, &uniform_offsets);

    // Scissor rect, clamped to whatever this pass draws into.
    const scissor = dvui.render.clampScissor(clipr, self.pass_width, self.pass_height);
    wgpu.wgpuRenderPassEncoderSetScissorRect(pass, scissor.x, scissor.y, scissor.w, scissor.h);

    // Bind instance buffer and draw 6 vertices (quad) for 1 instance
    wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.sdf_instance_buffer, self.sdf_instance_byte_offset, inst_bytes_aligned);
    wgpu.wgpuRenderPassEncoderDraw(pass, 6, 1, 0, 0);

    // Advance offset
    self.sdf_instance_byte_offset += inst_bytes_aligned;
}

pub fn textureCreate(self: *@This(), pixels: [*]const u8, options: dvui.Texture.CreateOptions) !dvui.Texture {
    // One linear clamp sampler serves every texture; interpolation / wrap are
    // recorded on the returned texture but not (yet) honoured by the sampler.
    const width = options.width;
    const height = options.height;
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

    return .{
        .ptr = tex,
        .width = width,
        .height = height,
        .format = .rgba_32,
        .interpolation = options.interpolation,
        .wrap_u = options.wrap_u,
        .wrap_v = options.wrap_v,
    };
}

pub fn textureUpdate(self: *@This(), texture: dvui.Texture, pixels: [*]const u8) !void {
    const key = @intFromPtr(texture.ptr);
    const tex: wgpu.WGPUTexture = @ptrCast(texture.ptr);
    // Wrapped views (`textureWrap`) are not in `textures`, so they are refused here:
    // the caller renders into them, dvui never uploads pixels.
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
    if (self.wrapped.contains(key)) {
        // Not ours to destroy: drop only the renderer-side bind group.
        self.textureUnwrap(texture);
        return;
    }
    self.releaseRegistries(key);
    const tex: wgpu.WGPUTexture = @ptrCast(texture.ptr);
    wgpu.wgpuTextureRelease(tex);
}

/// Drop every renderer-side handle registered against one texture pointer.
///
/// Both destroy paths go through here because on this backend they are the same
/// texture. `textureFromTarget` is a *cast* — a render target that becomes a
/// sampled texture keeps its pointer — so a texture destroyed through
/// `textureDestroy` may still own the render view `textureCreateTarget` made
/// for it. Releasing only two of the three registries leaked that view, and a
/// live view holds its `WGPUTexture` open, so the `wgpuTextureRelease` below
/// freed nothing either: every `BlurBackdrop` capture orphaned a target
/// (measured at +5.3 entries per frame) until the device ran out of memory and
/// wgpu-native's default handler aborted the process.
fn releaseRegistries(self: *@This(), key: usize) void {
    if (self.bind_groups.fetchRemove(key)) |kv| wgpu.wgpuBindGroupRelease(kv.value);
    if (self.textures.fetchRemove(key)) |kv| wgpu.wgpuTextureViewRelease(kv.value);
    if (self.target_views.fetchRemove(key)) |kv| wgpu.wgpuTextureViewRelease(kv.value);
}

/// How many render-target views the renderer is holding open.
///
/// For a host's leak test: this is the number that used to climb by ~5 every
/// frame a backdrop was captured. Over a steady UI it must return to the same
/// value frame after frame.
pub fn renderTargetViewCount(self: *const @This()) usize {
    return self.target_views.count();
}

/// How many sampled-texture views the renderer is holding open. See
/// `renderTargetViewCount`.
pub fn textureViewCount(self: *const @This()) usize {
    return self.textures.count();
}

/// Wrap an existing `WGPUTextureView` as a `dvui.Texture` that `dvui.image`
/// (`ImageSource.texture`) and `dvui.renderTexture` can draw, WITHOUT taking
/// ownership of the view or its texture.
///
/// Semantics:
/// - The caller keeps ownership: the view must stay alive (and unchanged in
///   size) for as long as the returned texture is drawn. `textureDestroy` on a
///   wrapped texture only releases the renderer's own bind group; it never
///   releases the view. Call `textureUnwrap` (or `textureDestroy`) BEFORE
///   releasing the view, e.g. when an offscreen target is re-created on resize.
/// - The view must be a 2D, non-multisampled, filterable colour view (sample
///   type `Float`), because it is bound through the same texture bind group
///   layout dvui uses for its own RGBA8Unorm textures. `RGBA8Unorm` /
///   `BGRA8Unorm` targets whose contents are already display-referred (sRGB
///   encoded) draw exactly like dvui's own textures: the fragment shader copies
///   samples through unchanged, so the wrapped frame gets the same single
///   colour transform as the rest of the UI.
/// - `textureUpdate` is refused for wrapped textures (the caller renders into
///   the view; dvui never uploads pixels to it).
/// - `texture.ptr` is the view pointer; wrapping the same view twice returns
///   `error.TextureCreate` until it is unwrapped.
///
/// `interpolation` is recorded on the returned texture; sampling uses the
/// renderer's single linear clamp sampler (like every other texture here).
pub fn textureWrap(self: *@This(), view: wgpu.WGPUTextureView, width: u32, height: u32, interpolation: dvui.enums.TextureInterpolation) !dvui.Texture {
    const view_ptr = view orelse return error.TextureCreate;
    const key = @intFromPtr(view_ptr);
    if (self.bind_groups.contains(key)) return error.TextureCreate;

    const bg = wgpu.wgpuDeviceCreateBindGroup(self.device, &wgpu.WGPUBindGroupDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_wrap_bg", .length = 12 },
        .layout = self.texture_bgl,
        .entryCount = 2,
        .entries = &[_]wgpu.WGPUBindGroupEntry{
            .{ .nextInChain = null, .binding = 0, .buffer = null, .offset = 0, .size = 0, .sampler = null, .textureView = view },
            .{ .nextInChain = null, .binding = 1, .buffer = null, .offset = 0, .size = 0, .sampler = self.sampler, .textureView = null },
        },
    }) orelse return error.TextureCreate;
    errdefer wgpu.wgpuBindGroupRelease(bg);

    try self.wrapped.put(key, {});
    errdefer _ = self.wrapped.remove(key);
    try self.bind_groups.put(key, bg);

    return .{
        .ptr = @ptrCast(view_ptr),
        .width = width,
        .height = height,
        .format = .rgba_32,
        .interpolation = interpolation,
        .wrap_u = .clamp,
        .wrap_v = .clamp,
    };
}

/// Forget a texture made by `textureWrap`: releases the renderer's bind group
/// and nothing else. Safe to call on a texture that was already unwrapped or
/// destroyed (no-op). The caller releases the underlying view afterwards.
pub fn textureUnwrap(self: *@This(), texture: dvui.Texture) void {
    const key = @intFromPtr(texture.ptr);
    if (!self.wrapped.remove(key)) return;
    if (self.bind_groups.fetchRemove(key)) |kv| wgpu.wgpuBindGroupRelease(kv.value);
}

pub fn textureCreateTarget(self: *@This(), options: dvui.Texture.CreateOptions) !dvui.TextureTarget {
    const width = options.width;
    const height = options.height;
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

    return .{
        .ptr = tex,
        .width = width,
        .height = height,
        .format = .rgba_32,
        .interpolation = options.interpolation,
        .wrap_u = options.wrap_u,
        .wrap_v = options.wrap_v,
    };
}

pub fn textureFromTarget(_: *@This(), target: dvui.TextureTarget) dvui.Texture {
    return .cast(target);
}

pub fn textureFromTargetTemp(_: *@This(), target: dvui.TextureTarget) dvui.Texture {
    return .cast(target);
}

pub fn textureDestroyTarget(self: *@This(), texture: dvui.Texture.Target) void {
    const key = @intFromPtr(texture.ptr);
    self.releaseRegistries(key);
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

pub fn textureReadTarget(self: *@This(), texture: dvui.TextureTarget, pixels: [*]u8) !void {
    const tex: wgpu.WGPUTexture = @ptrCast(texture.ptr);
    const width = texture.width;
    const height = texture.height;

    // CopyTextureToBuffer requires bytesPerRow to be a multiple of 256.
    const unpadded_bytes_per_row = width * 4;
    const align_to: u32 = 256;
    const padded_bytes_per_row = (unpadded_bytes_per_row + align_to - 1) / align_to * align_to;
    const buffer_size: u64 = @as(u64, padded_bytes_per_row) * height;

    const readback = wgpu.wgpuDeviceCreateBuffer(self.device, &wgpu.WGPUBufferDescriptor{
        .nextInChain = null,
        .label = .{ .data = "dvui_readback", .length = 13 },
        .usage = wgpu.WGPUBufferUsage_MapRead | wgpu.WGPUBufferUsage_CopyDst,
        .size = buffer_size,
        .mappedAtCreation = 0,
    }) orelse return error.TextureRead;
    defer wgpu.wgpuBufferRelease(readback);

    const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.device, null) orelse return error.TextureRead;
    wgpu.wgpuCommandEncoderCopyTextureToBuffer(
        encoder,
        &wgpu.WGPUTexelCopyTextureInfo{
            .texture = tex,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = wgpu.WGPUTextureAspect_All,
        },
        &wgpu.WGPUTexelCopyBufferInfo{
            .layout = .{ .offset = 0, .bytesPerRow = padded_bytes_per_row, .rowsPerImage = height },
            .buffer = readback,
        },
        &wgpu.WGPUExtent3D{ .width = width, .height = height, .depthOrArrayLayers = 1 },
    );
    const cmd = wgpu.wgpuCommandEncoderFinish(encoder, null) orelse return error.TextureRead;
    wgpu.wgpuCommandEncoderRelease(encoder);
    wgpu.wgpuQueueSubmit(self.queue, 1, &cmd);
    wgpu.wgpuCommandBufferRelease(cmd);

    // Map the readback buffer and block until the GPU work + callback complete.
    const MapState = struct {
        var status: wgpu.WGPUMapAsyncStatus = wgpu.WGPUMapAsyncStatus_Force32;
        fn onMap(s: wgpu.WGPUMapAsyncStatus, _: wgpu.WGPUStringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            status = s;
        }
    };
    MapState.status = wgpu.WGPUMapAsyncStatus_Force32;
    _ = wgpu.wgpuBufferMapAsync(readback, wgpu.WGPUMapMode_Read, 0, buffer_size, .{
        .nextInChain = null,
        .mode = wgpu.WGPUCallbackMode_AllowProcessEvents,
        .callback = MapState.onMap,
        .userdata1 = null,
        .userdata2 = null,
    });
    while (MapState.status == wgpu.WGPUMapAsyncStatus_Force32) {
        _ = wgpu.wgpuDevicePoll(self.device, 1, null);
    }
    if (MapState.status != wgpu.WGPUMapAsyncStatus_Success) return error.TextureRead;

    const mapped: [*]const u8 = @ptrCast(wgpu.wgpuBufferGetMappedRange(readback, 0, buffer_size) orelse {
        wgpu.wgpuBufferUnmap(readback);
        return error.TextureRead;
    });
    defer wgpu.wgpuBufferUnmap(readback);

    // Copy row by row, stripping the 256-byte row padding. dvui expects RGBA;
    // if the surface is BGRA, swizzle R<->B.
    const swap_rb = self.surface_format == wgpu.WGPUTextureFormat_BGRA8Unorm or
        self.surface_format == wgpu.WGPUTextureFormat_BGRA8UnormSrgb;
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const src = mapped + row * padded_bytes_per_row;
        const dst = pixels + row * unpadded_bytes_per_row;
        if (swap_rb) {
            var i: u32 = 0;
            while (i < unpadded_bytes_per_row) : (i += 4) {
                dst[i + 0] = src[i + 2];
                dst[i + 1] = src[i + 1];
                dst[i + 2] = src[i + 0];
                dst[i + 3] = src[i + 3];
            }
        } else {
            @memcpy(dst[0..unpadded_bytes_per_row], src[0..unpadded_bytes_per_row]);
        }
    }
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
        self.current_target_view = render_view;

        // The attachment is the texture now, so the scissor is measured against
        // its size, not the window's.
        const w: f32 = @floatFromInt(target.width);
        const h: f32 = @floatFromInt(target.height);
        self.pass_width = w;
        self.pass_height = h;

        // Its own slot: the pass this projection belongs to has not been
        // submitted yet, and neither have the ones before it.
        self.writeProjection(w, h);
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
    self.current_target_view = null;
    self.pass_width = self.viewport_width;
    self.pass_height = self.viewport_height;

    // Slot 0 already holds the window's projection and nothing overwrites it,
    // so restoring the main pass is a change of offset, not a write.
    self.uniform_slot = 0;
}

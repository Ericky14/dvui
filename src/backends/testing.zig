//! Headless testing backend for dvui logic tests.
//!
//! Screen rendering is a no-op (logic tests stay fast), but rendering into a
//! render *target* (as dvui.Picture / dvui.testing.capturePng / saveImage /
//! snapshot images do) is rasterized on the CPU. That makes deterministic,
//! GPU-free component screenshots possible from plain `zig build test`.

allocator: std.mem.Allocator,

arena: std.mem.Allocator = undefined,

size: dvui.Size.Natural,
size_pixels: dvui.Size.Physical,
time: i128 = 0,
clipboard: ?[]const u8 = null,

/// Current CPU render target. Software rasterization only happens while this
/// is set; screen rendering (target == null) stays a no-op.
render_target: ?RenderTarget = null,

const RenderTarget = struct { pixels: []u8, width: u32, height: u32 };

pub const kind: dvui.enums.Backend = .testing;

pub const TestingBackend = @This();
pub const Context = *TestingBackend;

pub const InitOptions = struct {
    allocator: std.mem.Allocator,
    size: dvui.Size.Natural,
    size_pixels: dvui.Size.Physical,
};

pub fn init(opts: InitOptions) TestingBackend {
    return .{
        .allocator = opts.allocator,
        .size = opts.size,
        .size_pixels = opts.size_pixels,
    };
}

pub fn deinit(self: *TestingBackend) void {
    if (self.clipboard) |text| {
        self.allocator.free(text);
    }
    self.* = undefined;
}

/// Get monotonic nanosecond timestamp. Doesn't have to be system time.
pub fn nanoTime(self: *TestingBackend) i128 {
    defer self.time += 1 * std.time.ns_per_ms; // arbitrary clock increment
    return self.time; // maybe should return static value?
}

/// Sleep for nanoseconds.
pub fn sleep(_: *TestingBackend, _: u64) void {}

/// Called by dvui during Window.begin(), so prior to any dvui
/// rendering.  Use to setup anything needed for this frame.  The arena
/// arg is cleared before begin is called next, useful for any temporary
/// allocations needed only for this frame.
pub fn begin(self: *TestingBackend, arena: std.mem.Allocator) !void {
    self.arena = arena;
}

/// Called by dvui during Window.end(), but currently unused by any
/// backends.  Probably will be removed.
pub fn end(_: *TestingBackend) !void {}

/// Return size of the window in physical pixels.  For a 300x200 retina
/// window (so actually 600x400), this should return 600x400.
pub fn pixelSize(self: *TestingBackend) dvui.Size.Physical {
    return self.size_pixels;
}

/// Return size of the window in logical pixels.  For a 300x200 retina
/// window (so actually 600x400), this should return 300x200.
pub fn windowSize(self: *TestingBackend) dvui.Size.Natural {
    return self.size;
}

/// Return the detected additional scaling.  This represents the user's
/// additional display scaling (usually set in their window system's
/// settings).  Currently only called during Window.init(), so currently
/// this sets the initial content scale.
pub fn contentScale(_: *TestingBackend) f32 {
    return 1;
}

/// Render a triangle list using the idx indexes into the vtx vertexes
/// clipped to to clipr (if given).  Vertex positions and clipr are in
/// physical pixels.  If texture is given, the vertexes uv coords are
/// normalized (0-1).
pub fn drawClippedTriangles(self: *TestingBackend, texture: ?dvui.Texture, vtx: []const dvui.Vertex, idx: []const dvui.Vertex.Index, clipr: ?dvui.Rect.Physical) !void {
    // Only rasterize into an explicit render target (Picture/capturePng).
    // Screen draws stay no-op so logic-only tests remain fast.
    const tgt = self.render_target orelse return;
    const fw = tgt.width;
    const fh = tgt.height;
    const fb = tgt.pixels;

    // Clip bounds in integer pixels.
    var clip_x0: i64 = 0;
    var clip_y0: i64 = 0;
    var clip_x1: i64 = @intCast(fw);
    var clip_y1: i64 = @intCast(fh);
    if (clipr) |clip| {
        clip_x0 = @max(clip_x0, @as(i64, @intFromFloat(@floor(clip.x))));
        clip_y0 = @max(clip_y0, @as(i64, @intFromFloat(@floor(clip.y))));
        clip_x1 = @min(clip_x1, @as(i64, @intFromFloat(@ceil(clip.x + clip.w))));
        clip_y1 = @min(clip_y1, @as(i64, @intFromFloat(@ceil(clip.y + clip.h))));
    }
    if (clip_x0 >= clip_x1 or clip_y0 >= clip_y1) return;

    var tex_ptr: ?[*]const u8 = null;
    var tex_w: u32 = 0;
    var tex_h: u32 = 0;
    if (texture) |t| {
        tex_ptr = @ptrCast(t.ptr);
        tex_w = t.width;
        tex_h = t.height;
    }

    var tri: usize = 0;
    while (tri + 3 <= idx.len) : (tri += 3) {
        const va = vtx[idx[tri]];
        const vb = vtx[idx[tri + 1]];
        const vc = vtx[idx[tri + 2]];

        const ax = va.pos.x;
        const ay = va.pos.y;
        const bx = vb.pos.x;
        const by = vb.pos.y;
        const cx = vc.pos.x;
        const cy = vc.pos.y;

        const area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
        if (area == 0) continue; // degenerate
        const inv_area = 1.0 / area;

        var min_x: i64 = @intFromFloat(@floor(@min(ax, @min(bx, cx))));
        var max_x: i64 = @intFromFloat(@ceil(@max(ax, @max(bx, cx))));
        var min_y: i64 = @intFromFloat(@floor(@min(ay, @min(by, cy))));
        var max_y: i64 = @intFromFloat(@ceil(@max(ay, @max(by, cy))));
        min_x = @max(min_x, clip_x0);
        min_y = @max(min_y, clip_y0);
        max_x = @min(max_x, clip_x1);
        max_y = @min(max_y, clip_y1);

        var py: i64 = min_y;
        while (py < max_y) : (py += 1) {
            var px: i64 = min_x;
            while (px < max_x) : (px += 1) {
                const sx: f32 = @as(f32, @floatFromInt(px)) + 0.5;
                const sy: f32 = @as(f32, @floatFromInt(py)) + 0.5;

                // Barycentric weights (w0->va, w1->vb, w2->vc), winding-agnostic.
                const w0 = ((cx - bx) * (sy - by) - (cy - by) * (sx - bx)) * inv_area;
                const w1 = ((ax - cx) * (sy - cy) - (ay - cy) * (sx - cx)) * inv_area;
                const w2 = ((bx - ax) * (sy - ay) - (by - ay) * (sx - ax)) * inv_area;
                if (w0 < 0 or w1 < 0 or w2 < 0) continue;

                // Interpolated premultiplied-alpha color.
                var cr = w0 * toF32(va.col.r) + w1 * toF32(vb.col.r) + w2 * toF32(vc.col.r);
                var cg = w0 * toF32(va.col.g) + w1 * toF32(vb.col.g) + w2 * toF32(vc.col.g);
                var cb = w0 * toF32(va.col.b) + w1 * toF32(vb.col.b) + w2 * toF32(vc.col.b);
                var ca = w0 * toF32(va.col.a) + w1 * toF32(vb.col.a) + w2 * toF32(vc.col.a);

                if (tex_ptr) |tp| {
                    const uu = w0 * va.uv[0] + w1 * vb.uv[0] + w2 * vc.uv[0];
                    const vv = w0 * va.uv[1] + w1 * vb.uv[1] + w2 * vc.uv[1];
                    const texel = sampleNearest(tp, tex_w, tex_h, uu, vv);
                    cr = cr * toF32(texel.r) / 255.0;
                    cg = cg * toF32(texel.g) / 255.0;
                    cb = cb * toF32(texel.b) / 255.0;
                    ca = ca * toF32(texel.a) / 255.0;
                }

                const src_a: u32 = clamp255(ca);
                if (src_a == 0) continue;
                const src_r: u32 = clamp255(cr);
                const src_g: u32 = clamp255(cg);
                const src_b: u32 = clamp255(cb);

                // Premultiplied src-over: out = src + dst * (1 - src.a)
                const di: usize = (@as(usize, @intCast(py)) * fw + @as(usize, @intCast(px))) * 4;
                const inv: u32 = 255 - src_a;
                fb[di + 0] = @intCast(@min(255, src_r + (@as(u32, fb[di + 0]) * inv + 127) / 255));
                fb[di + 1] = @intCast(@min(255, src_g + (@as(u32, fb[di + 1]) * inv + 127) / 255));
                fb[di + 2] = @intCast(@min(255, src_b + (@as(u32, fb[di + 2]) * inv + 127) / 255));
                fb[di + 3] = @intCast(@min(255, src_a + (@as(u32, fb[di + 3]) * inv + 127) / 255));
            }
        }
    }
}

fn toF32(value: u8) f32 {
    return @floatFromInt(value);
}

fn clamp255(value: f32) u32 {
    return @intFromFloat(@min(255.0, @max(0.0, value + 0.5)));
}

fn sampleNearest(pixels: [*]const u8, width: u32, height: u32, u: f32, v: f32) dvui.Color.PMA {
    if (width == 0 or height == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    var ix: i64 = @intFromFloat(@floor(u * @as(f32, @floatFromInt(width))));
    var iy: i64 = @intFromFloat(@floor(v * @as(f32, @floatFromInt(height))));
    ix = std.math.clamp(ix, 0, @as(i64, @intCast(width)) - 1);
    iy = std.math.clamp(iy, 0, @as(i64, @intCast(height)) - 1);
    const offset: usize = (@as(usize, @intCast(iy)) * width + @as(usize, @intCast(ix))) * 4;
    return .{ .r = pixels[offset], .g = pixels[offset + 1], .b = pixels[offset + 2], .a = pixels[offset + 3] };
}

/// Create a texture from the given pixels in RGBA.  The returned
/// pointer is what will later be passed to drawClippedTriangles.
pub fn textureCreate(self: *TestingBackend, pixels: [*]const u8, options: dvui.Texture.CreateOptions) !dvui.Texture {
    const new_pixels = self.allocator.dupe(u8, pixels[0 .. options.width * options.height * 4]) catch @panic("Couldn't create texture: OOM");
    return .{
        .width = options.width,
        .height = options.height,
        .ptr = new_pixels.ptr,
        .format = options.format,
        .interpolation = options.interpolation,
        .wrap_u = options.wrap_u,
        .wrap_v = options.wrap_v,
    };
}

/// Create a texture that can be rendered to with renderTarget().  The
/// returned pointer is what will later be passed to drawClippedTriangles.
pub fn textureCreateTarget(self: *TestingBackend, options: dvui.Texture.CreateOptions) !dvui.TextureTarget {
    const buffer = self.allocator.alloc(u8, options.width * options.height * 4) catch return error.TextureCreate;
    @memset(buffer, 0);
    return .{
        .ptr = buffer.ptr,
        .width = options.width,
        .height = options.height,
        .format = options.format,
        .interpolation = options.interpolation,
        .wrap_u = options.wrap_u,
        .wrap_v = options.wrap_v,
    };
}

pub fn textureClearTarget(_: *TestingBackend, texture: dvui.TextureTarget) void {
    const ptr: [*]u8 = @ptrCast(texture.ptr);
    @memset(ptr[0 .. texture.width * texture.height * 4], 0);
}

/// Read pixel data (RGBA) from texture into pixel.
pub fn textureReadTarget(_: *TestingBackend, texture: dvui.TextureTarget, pixels: [*]u8) !void {
    const ptr: [*]const u8 = @ptrCast(texture.ptr);
    @memcpy(pixels, ptr[0..(texture.width * texture.height * 4)]);
}

/// Destroy texture that was previously made with textureCreate() or
/// textureFromTarget().  After this call, this texture pointer will not
/// be used by dvui.
pub fn textureDestroy(self: *TestingBackend, texture: dvui.Texture) void {
    const ptr: [*]const u8 = @ptrCast(texture.ptr);
    self.allocator.free(ptr[0..(texture.width * texture.height * 4)]);
}

pub fn textureDestroyTarget(self: *TestingBackend, texture: dvui.Texture.Target) void {
    if (self.render_target) |rt| {
        if (rt.pixels.ptr == @as([*]u8, @ptrCast(texture.ptr))) self.render_target = null;
    }
    const ptr: [*]u8 = @ptrCast(texture.ptr);
    self.allocator.free(ptr[0 .. texture.width * texture.height * 4]);
}

pub fn textureFromTarget(_: *TestingBackend, texture: dvui.TextureTarget) !dvui.Texture {
    return .cast(texture);
}

pub fn textureFromTargetTemp(_: *TestingBackend, texture: dvui.TextureTarget) !dvui.Texture {
    return .cast(texture);
}

/// Render future drawClippedTriangles() to the passed texture (or screen
/// if null).
pub fn renderTarget(self: *TestingBackend, target: ?dvui.TextureTarget) !void {
    if (target) |t| {
        const ptr: [*]u8 = @ptrCast(t.ptr);
        self.render_target = .{ .pixels = ptr[0 .. t.width * t.height * 4], .width = t.width, .height = t.height };
    } else {
        self.render_target = null;
    }
}

pub fn setCursor(_: *TestingBackend, _: dvui.enums.Cursor) void {}
pub fn textInputRect(_: *TestingBackend, _: ?dvui.Rect.Natural) void {}
pub fn renderPresent(_: *TestingBackend) void {}

/// Get clipboard content (text only)
pub fn clipboardText(self: *TestingBackend) std.mem.Allocator.Error![]const u8 {
    if (self.clipboard) |text| {
        return try self.arena.dupe(u8, text);
    } else {
        return "";
    }
}

/// Set clipboard content (text only)
pub fn clipboardTextSet(self: *TestingBackend, text: []const u8) std.mem.Allocator.Error!void {
    if (self.clipboard) |prev_text| {
        self.allocator.free(prev_text);
    }
    self.clipboard = try self.allocator.dupe(u8, text);
}

/// Open URL in system browser
pub fn openURL(_: *TestingBackend, _: []const u8, _: bool) std.mem.Allocator.Error!void {}

pub fn preferredColorScheme(_: *TestingBackend) ?dvui.enums.ColorScheme {
    return null;
}

pub fn prefersReducedMotion(_: *@This()) bool {
    return false;
}

/// Called by dvui.refresh() when it is called from a background
/// thread.  Used to wake up the gui thread.  It only has effect if you
/// are using waitTime() or some other method of waiting until a new
/// event comes in.
pub fn refresh(_: *TestingBackend) void {}
pub fn backend(self: *TestingBackend) dvui.Backend {
    return dvui.Backend.init(self);
}

test {
    //std.debug.print("testing backend test\n", .{});
    std.testing.refAllDecls(@This());
}

test "cpu raster capture" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 220, .h = 120 } });
    defer t.deinit();

    const Local = struct {
        fn frame() !dvui.App.Result {
            var outer = dvui.box(@src(), .{}, .{
                .expand = .both,
                .background = true,
                .color_fill = .{ .r = 28, .g = 30, .b = 40, .a = 255 },
            });
            defer outer.deinit();
            dvui.label(@src(), "Hello DVUI", .{}, .{ .color_text = .{ .r = 240, .g = 240, .b = 255, .a = 255 } });
            _ = dvui.button(@src(), "Click me", .{}, .{ .corners = .all(6) });
            return .ok;
        }
    };

    try dvui.testing.settle(Local.frame);
    try t.saveImage(Local.frame, null, "scene.png");
}

test "capture text entry" {
    const TextEntryWidget = dvui.TextEntryWidget;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 200, .h = 70 } });
    defer t.deinit();

    const Local = struct {
        var buffer: [256]u8 = @splat(0);
        fn frame() !dvui.App.Result {
            var outer = dvui.box(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = .{ .r = 20, .g = 22, .b = 28, .a = 255 } });
            defer outer.deinit();
            var entry: TextEntryWidget = undefined;
            entry.init(@src(), .{ .text = .{ .buffer = &buffer }, .focus_border = false }, .{
                .tag = "entry",
                .min_size_content = .{ .w = 150, .h = 18 },
                .padding = dvui.Rect.all(10),
                .border = dvui.Rect.all(2),
                .corners = .all(8),
                .margin = dvui.Rect.all(12),
                .color_fill = .{ .r = 245, .g = 245, .b = 245, .a = 255 },
                .color_border = .{ .r = 110, .g = 180, .b = 255, .a = 255 },
                .color_text = .{ .r = 12, .g = 12, .b = 12, .a = 255 },
            });
            defer entry.deinit();
            entry.processEvents();
            entry.draw();
            return .ok;
        }
    };

    try dvui.testing.settle(Local.frame);
    try dvui.testing.pressKey(.tab, .none); // focus
    try dvui.testing.settle(Local.frame);
    try dvui.testing.writeText("Hello");
    try dvui.testing.settle(Local.frame);
    try t.saveImage(Local.frame, null, "text_entry.png");

    // Overflow: type past the field width. Validates the caret stays inside the
    // padding and text is clipped with a gap (not flush against the border).
    try dvui.testing.writeText(" world this is a long line");
    try dvui.testing.settle(Local.frame);
    try t.saveImage(Local.frame, null, "text_entry_overflow.png");
}

pub const dvui = @import("dvui");
pub const std = @import("std");

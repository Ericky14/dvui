//! TVG (TinyVG) icon rendering.
//!
//! An icon up to `raster_limit` physical pixels is drawn the way a browser
//! draws an SVG: each fill and each stroke is scan-converted once by
//! `coverage.zig` into a texture of the icon's physical size (at its
//! subpixel phase), its overlapping pieces resolved by winding first, so a
//! stroke's segments and round joins are inked once and a curve is even
//! (`renderIconRaster`). The texture is cached by icon, size, phase and
//! options, and drawn as one quad.
//!
//! A bigger icon (or one drawn into a mesh by a caller) takes the mesh
//! path below: it emits `dvui.Triangles` built from
//! `dvui.Path.fillTriangles` / `dvui.Path.fillConvexTriangles` /
//! `dvui.Path.strokeTriangles` - i.e. the same AA'd polygon-fill and
//! bezier-flattening machinery every other widget uses. No raster
//! intermediate, no bespoke triangulator: concave fills and fills with
//! holes go through `Path.fillTriangles` (earcut-backed), which resolves
//! overlaps/holes/self-intersections and gets real edge AA for free.
//!
//! Meshes are authored once at an integer pixel height and cached in
//! `Window.icon_mesh_cache` (see `renderIcon`), then replayed
//! scaled+translated every frame.

/// Render options for a TVG render.
pub const RenderOptions = struct {
    /// If set, overrides every fill / stroke color or gradient in the TVG.
    color_override: ?ColorOrGradient = null,
    /// If set, overrides only fill colors (does not affect strokes).
    fill_color_override: ?ColorOrGradient = null,
    /// If set, overrides only stroke colors (does not affect fills).
    stroke_color_override: ?ColorOrGradient = null,
    /// If set, overrides the stroke width for all stroked paths.
    stroke_width_override: ?f32 = null,
    /// When true, all fill operations are skipped (only strokes are drawn).
    disable_fill: bool = false,
    /// Preserve TVG aspect ratio inside `rect` (letterbox).  When false the
    /// icon is stretched to fill the rect.
    keep_aspect: bool = true,
    /// Edge feather (physical px) for anti-aliasing of fills and stroke
    /// caps/joins (flat or gradient - see `fillContoursPhysical`).  0
    /// disables fill AA - sharp edges, useful for pixel-aligned UI strokes.
    fade: f32 = 1.0,
    /// Physical-pixel bounds a `color_override`/`fill_color_override`/
    /// `stroke_color_override` gradient is sampled against. Set by
    /// `appendTvg` from `rect`.
    bounds: Rect = .{},
};

/// Caller-owned accumulator that collects ALL triangles for a TVG render
/// (fills, stroke bands, round-join/cap discs) into one combined mesh, so
/// it can be cached once and replayed every frame with
/// `dvui.renderTriangles` instead of regenerating.
pub const MeshBuilder = struct {
    /// Allocator used to grow `vtx`/`idx`.  Stays with the builder so
    /// cached meshes can outlive the original render call.
    alloc: std.mem.Allocator,
    vtx: std.ArrayList(Vertex) = .empty,
    idx: std.ArrayList(Vertex.Index) = .empty,
    bounds_min_x: f32 = math.floatMax(f32),
    bounds_min_y: f32 = math.floatMax(f32),
    bounds_max_x: f32 = -math.floatMax(f32),
    bounds_max_y: f32 = -math.floatMax(f32),
    /// Ramp texture from the first gradient fill appended, if any - see
    /// `appendMesh`. `renderIcon` binds this for the whole mesh's one draw
    /// call.
    tex: ?dvui.Texture = null,
    /// `dvui.textureRetain`/`textureRelease` key for `tex`, if set - see
    /// `renderIcon`. This mesh (unlike a normal per-frame gradient fill)
    /// gets cached and replayed across frames without re-touching `tex` in
    /// the global texture cache, so whoever puts this mesh in
    /// `Window.icon_mesh_cache` must retain `tex_key` explicitly or it gets
    /// destroyed out from under the cached mesh after one frame.
    tex_key: ?dvui.Texture.Cache.Key = null,

    pub fn init(alloc: std.mem.Allocator) MeshBuilder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *MeshBuilder) void {
        self.vtx.deinit(self.alloc);
        self.idx.deinit(self.alloc);
    }

    fn appendMesh(self: *MeshBuilder, src: Triangles, tex_key: ?dvui.Texture.Cache.Key) !void {
        if (src.vertexes.len == 0 or src.indices.len == 0) return;
        const base: Vertex.Index = @intCast(self.vtx.items.len);
        try self.vtx.appendSlice(self.alloc, src.vertexes);
        try self.idx.ensureUnusedCapacity(self.alloc, src.indices.len);
        for (src.indices) |i| self.idx.appendAssumeCapacity(base + i);
        for (src.vertexes) |v| {
            if (v.pos.x < self.bounds_min_x) self.bounds_min_x = v.pos.x;
            if (v.pos.y < self.bounds_min_y) self.bounds_min_y = v.pos.y;
            if (v.pos.x > self.bounds_max_x) self.bounds_max_x = v.pos.x;
            if (v.pos.y > self.bounds_max_y) self.bounds_max_y = v.pos.y;
        }
        if (self.tex == null) {
            self.tex = src.texture;
            if (src.texture != null) self.tex_key = tex_key;
        }
    }

    /// Borrowed view of the accumulated geometry as a `dvui.Triangles`.
    pub fn toTriangles(self: *const MeshBuilder) Triangles {
        const empty_bounds = self.vtx.items.len == 0;
        return .{
            .vertexes = self.vtx.items,
            .indices = self.idx.items,
            .bounds = if (empty_bounds) .{} else .{
                .x = self.bounds_min_x,
                .y = self.bounds_min_y,
                .w = self.bounds_max_x - self.bounds_min_x,
                .h = self.bounds_max_y - self.bounds_min_y,
            },
            .texture = self.tex,
        };
    }
};

pub const MeshCache = struct {
    cache: Storage = .empty,

    pub const Storage = dvui.TrackingAutoHashMap(u64, MeshBuilder, .get_and_put, void);

    pub fn get(self: *MeshCache, key: u64) ?MeshBuilder {
        return self.cache.get(key);
    }

    pub fn add(self: *MeshCache, gpa: std.mem.Allocator, key: u64, mesh: MeshBuilder) std.mem.Allocator.Error!void {
        const prev = try self.cache.fetchPut(gpa, key, mesh);
        if (prev) |kv| {
            var m = kv.value;
            if (m.tex_key) |k| dvui.textureRelease(k);
            m.deinit();
        }
    }

    /// Frees every mesh that was not accessed since the last call to
    /// `reset`, releasing its retained gradient texture (see
    /// `MeshBuilder.tex_key`) first.
    pub fn reset(self: *MeshCache) void {
        var it = self.cache.iterator();
        while (it.next_resetting()) |kv| {
            var m = kv.value;
            if (m.tex_key) |k| dvui.textureRelease(k);
            m.deinit();
        }
    }

    pub fn deinit(self: *MeshCache, gpa: std.mem.Allocator) void {
        defer self.* = undefined;
        var it = self.cache.iterator();
        while (it.next()) |item| item.value_ptr.deinit();
        self.cache.deinit(gpa);
    }
};

fn hashValue(h: *dvui.fnv, v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .float => |f| {
            const Bits = @Int(.unsigned, f.bits);
            const bits: Bits = @bitCast(v);
            h.update(std.mem.asBytes(&bits));
        },
        .optional => {
            h.update(&[_]u8{if (v == null) 0 else 1});
            if (v) |val| hashValue(h, val);
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                h.update(std.mem.asBytes(&v.len));
                for (v) |item| hashValue(h, item);
            },
            else => @compileError("hashValue: unsupported pointer type " ++ @typeName(T)),
        },
        .@"struct" => |s| inline for (s.field_names) |field_name| hashValue(h, @field(v, field_name)),
        .@"union" => |u| {
            const tag = std.meta.activeTag(v);
            hashValue(h, tag);
            inline for (u.field_names, u.field_types) |field_name, FieldT| {
                if (@field(std.meta.Tag(T), field_name) == tag) {
                    if (FieldT != void) hashValue(h, @field(v, field_name));
                }
            }
        },
        .@"enum" => h.update(std.mem.asBytes(&@backingInt(v))),
        else => h.update(std.mem.asBytes(&v)),
    }
}

/// Only valid between `Window.begin` and `Window.end`.
pub fn renderIcon(name: []const u8, tvg_bytes: []const u8, rs: dvui.RectScale, opts: dvui.render.TextureOptions, icon_opts: dvui.IconRenderOptions) Backend.TextureError!void {
    if (rs.s == 0) return;
    if (dvui.clipGet().intersect(rs.r).empty()) return;

    // Ask for an integer size icon (used as the mesh authoring size).
    const ask_height = @ceil(rs.r.h);
    if (ask_height <= 0) return;
    const ask_width = dvui.iconWidth(name, tvg_bytes, ask_height) catch ask_height;

    const render_opts: RenderOptions = .{
        .fill_color_override = icon_opts.fill_color,
        .stroke_color_override = icon_opts.stroke_color,
        .stroke_width_override = icon_opts.stroke_width,
        .disable_fill = if (icon_opts.fill_color) |c| c.toColor().a == 0 else false,
        .keep_aspect = true,
        .fade = 1.0,
    };

    if (rs.r.w <= raster_limit and rs.r.h <= raster_limit) {
        return renderIconRaster(name, tvg_bytes, rs, opts, render_opts, icon_opts);
    }

    var h = dvui.fnv.init();
    h.update(std.mem.asBytes(&tvg_bytes.ptr));
    h.update(std.mem.asBytes(&ask_height));
    hashValue(&h, icon_opts);
    const hash = h.final();

    const cw = dvui.currentWindow();

    const mesh: MeshBuilder = cw.icon_mesh_cache.get(hash) orelse blk: {
        var mesh = MeshBuilder.init(cw.gpa);
        errdefer mesh.deinit();

        var scratch = std.heap.ArenaAllocator.init(cw.gpa);
        defer scratch.deinit();

        const local_rect: Rect = .{ .x = 0, .y = 0, .w = ask_width, .h = ask_height };

        appendTvg(scratch.allocator(), &mesh, tvg_bytes, local_rect, render_opts) catch |err| {
            mesh.deinit();
            dvui.logError(@src(), err, "Could not build mesh from tvg file \"{s}\"", .{name});
            return;
        };

        // `mesh` outlives this single render call (it's about to go into
        // `icon_mesh_cache` and get replayed frame after frame), but its
        // gradient ramp texture (if any) lives in the global texture cache,
        // which frees anything not re-touched within one frame. Retain it
        // now so `MeshCache.add`'s errdefer path below can safely release
        // it; the retain that keeps it alive long-term is re-asserted
        // every frame this entry is actually used (see below).
        if (mesh.tex_key) |k| dvui.textureRetain(k);

        cw.icon_mesh_cache.add(cw.gpa, hash, mesh) catch |err| {
            if (mesh.tex_key) |k| dvui.textureRelease(k);
            mesh.deinit();
            dvui.logError(@src(), err, "Could not cache mesh for icon \"{s}\"", .{name});
            return;
        };
        break :blk mesh;
    };

    // Re-touch the retain every frame this cache entry is used (not just
    // when it's built): a gradient's ramp texture is keyed only by its
    // stops/alpha, so a *different* mesh entry can share this same
    // `tex_key` (e.g. this same icon rebuilt every frame while an angle
    // animates, evicting the previous frame's entry each time). Evicting
    // that other entry releases the shared key (see `MeshCache.reset`),
    // which would otherwise leave this still-live entry's texture
    // unretained and unretouched (a cache hit skips `Gradient.apply`)
    // until it's destroyed out from under a later frame's render.
    if (mesh.tex_key) |k| dvui.textureRetain(k);

    if (mesh.idx.items.len == 0) return;

    // Dupe the cached (0,0)-anchored mesh into the per-frame arena, then
    // scale/translate from authoring size to `rs.r`.
    var tri = mesh.toTriangles().dupe(cw.lifo()) catch |err| {
        dvui.logError(@src(), err, "Could not dupe mesh for icon \"{s}\"", .{name});
        return;
    };
    defer tri.deinit(cw.lifo());

    const scale_h: f32 = rs.r.h / ask_height;
    const scale_w: f32 = rs.r.w / ask_width;
    const tx = rs.r.x;
    const ty = rs.r.y;
    for (tri.vertexes) |*v| {
        v.pos.x = v.pos.x * scale_w + tx;
        v.pos.y = v.pos.y * scale_h + ty;
    }
    tri.bounds.x = tri.bounds.x * scale_w + tx;
    tri.bounds.y = tri.bounds.y * scale_h + ty;
    tri.bounds.w *= scale_w;
    tri.bounds.h *= scale_h;

    if (opts.rotation != 0) {
        tri.rotate(rs.r.center(), opts.rotation);
    }

    tri.color(opts.colormod.opacity(cw.alpha));

    try dvui.renderTriangles(tri, tri.texture);
}

// ---------------------------------------------------------------------------
// Coverage raster: an icon drawn once into a texture
// ---------------------------------------------------------------------------

/// Icons up to this many physical pixels on a side are drawn from a
/// coverage raster (`renderIconRaster`); a larger one is drawn as a mesh.
pub const raster_limit: f32 = 512;

/// The raster flattens curves this many times larger than it draws them, so
/// the 0.5 px chord tolerance of `flattenArc` and `Path.Builder` is 1/8 px
/// on the icon: a circle stays round at a stroke two pixels wide.
const raster_oversample: f32 = 4;

/// Subpixel positions an icon is rasterised at, per axis: its top left lands
/// within 1/8 px of where the layout put it.
const raster_phases: f32 = 4;

/// Draw the icon from a texture rasterised for exactly this size and
/// subpixel position (cached in the texture cache), one quad a frame.
///
/// Every fill and every stroke is a shape the coverage rasteriser fills
/// once (`coverage.zig`): a stroke is the union of a band per segment and a
/// disc per joint and end, resolved by winding before any pixel is counted,
/// so its joints carry exactly the ink of the rest of it. A mesh of
/// separately anti-aliased pieces lays two fading edges over each other at
/// every joint and beads a curve.
fn renderIconRaster(name: []const u8, tvg_bytes: []const u8, rs: dvui.RectScale, opts: dvui.render.TextureOptions, render_opts: RenderOptions, icon_opts: dvui.IconRenderOptions) Backend.TextureError!void {
    // the icon's size, quantised so a size that wobbles by a rounding error
    // reuses its texture
    const width = @round(rs.r.w * 64) / 64;
    const height = @round(rs.r.h * 64) / 64;
    if (width <= 0 or height <= 0) return;

    // Where the texture goes and where the icon sits inside it. Unrotated:
    // the texture starts on the pixel the icon starts in, the icon at its
    // subpixel phase inside. Rotated: centred, so it turns about its middle.
    var draw: Rect = undefined;
    var offset: Point = undefined;
    if (opts.rotation == 0) {
        var left = @floor(rs.r.x);
        var top = @floor(rs.r.y);
        offset = .{
            .x = @round((rs.r.x - left) * raster_phases) / raster_phases,
            .y = @round((rs.r.y - top) * raster_phases) / raster_phases,
        };
        if (offset.x >= 1) {
            left += 1;
            offset.x = 0;
        }
        if (offset.y >= 1) {
            top += 1;
            offset.y = 0;
        }
        draw = .{ .x = left, .y = top, .w = @ceil(offset.x + width), .h = @ceil(offset.y + height) };
    } else {
        const texture_w = @ceil(width);
        const texture_h = @ceil(height);
        offset = .{ .x = (texture_w - width) / 2, .y = (texture_h - height) / 2 };
        const centre = rs.r.center();
        draw = .{ .x = centre.x - texture_w / 2, .y = centre.y - texture_h / 2, .w = texture_w, .h = texture_h };
    }

    var h = dvui.fnv.init();
    h.update("tvg raster");
    h.update(std.mem.asBytes(&tvg_bytes.ptr));
    h.update(std.mem.asBytes(&tvg_bytes.len));
    hashValue(&h, width);
    hashValue(&h, height);
    hashValue(&h, offset.x);
    hashValue(&h, offset.y);
    hashValue(&h, draw.w);
    hashValue(&h, draw.h);
    hashValue(&h, icon_opts);
    const key = h.final();

    const texture = dvui.textureGetCached(key) orelse blk: {
        const cw = dvui.currentWindow();
        var scratch = std.heap.ArenaAllocator.init(cw.gpa);
        defer scratch.deinit();
        const texture_w: u32 = @intFromFloat(draw.w);
        const texture_h: u32 = @intFromFloat(draw.h);
        const pixels = rasterTvg(scratch.allocator(), tvg_bytes, .{ .x = offset.x, .y = offset.y, .w = width, .h = height }, texture_w, texture_h, render_opts) catch |err| {
            dvui.logError(@src(), err, "Could not rasterise tvg file \"{s}\"", .{name});
            return;
        };
        const texture = try dvui.Texture.fromPixelsPMA(pixels, texture_w, texture_h, .linear);
        dvui.textureAddToCache(key, texture);
        break :blk texture;
    };

    try dvui.renderTexture(texture, .{ .r = draw, .s = rs.s }, opts);
}

/// Rasterise `tvg_bytes` fitted into `rect` (physical pixels, inside a
/// `texture_w` x `texture_h` image) into premultiplied pixels, every
/// command composited over the ones before it. Allocates from `arena`.
fn rasterTvg(arena: std.mem.Allocator, tvg_bytes: []const u8, rect: Rect, texture_w: u32, texture_h: u32, opts_in: RenderOptions) ![]Color.PMA {
    var fbs: std.Io.Reader = .fixed(tvg_bytes);
    var parser = try tvg.parse(arena, &fbs);
    defer parser.deinit();

    // all geometry is built `raster_oversample` times larger than drawn
    const big: Rect = .{
        .x = rect.x * raster_oversample,
        .y = rect.y * raster_oversample,
        .w = rect.w * raster_oversample,
        .h = rect.h * raster_oversample,
    };
    const xf = Transform.fromRect(big, @floatFromInt(parser.header.width), @floatFromInt(parser.header.height), opts_in.keep_aspect);
    var opts = opts_in;
    opts.bounds = big;

    var canvas: Canvas = try .init(arena, texture_w, texture_h);
    while (try parser.next()) |cmd| {
        try rasterCommand(arena, &canvas, parser.color_table, cmd, xf, opts);
    }
    return canvas.finish(arena);
}

/// The image a raster is composited into, and the scratch it fills shapes
/// with.
const Canvas = struct {
    width: usize,
    height: usize,
    /// premultiplied r, g, b, a per pixel
    pixels: []@Vector(4, f32),
    coverage: []f32,
    raster: coverage_raster.Rasterizer,

    fn init(arena: std.mem.Allocator, width: u32, height: u32) !Canvas {
        const count = @as(usize, width) * height;
        const pixels = try arena.alloc(@Vector(4, f32), count);
        @memset(pixels, @splat(0));
        var raster: coverage_raster.Rasterizer = .init(width, height);
        raster.scale = 1.0 / raster_oversample;
        return .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .coverage = try arena.alloc(f32, count),
            .raster = raster,
        };
    }

    /// Fill the shape added to `raster` by `rule` and lay `source` over the
    /// image through it; the raster is emptied for the next shape.
    fn paint(self: *Canvas, rule: coverage_raster.FillRule, source: ColorSource) void {
        defer self.raster.reset();
        if (self.raster.crossings.items.len == 0) return;
        self.raster.fill(rule, self.coverage);
        for (self.coverage, self.pixels, 0..) |share, *pixel, index| {
            if (share <= 0) continue;
            const color: Color.PMA = switch (source) {
                .flat => |pma| pma,
                // gradients are sampled where the geometry was built
                else => source.sample(.{
                    .x = (@as(f32, @floatFromInt(index % self.width)) + 0.5) * raster_oversample,
                    .y = (@as(f32, @floatFromInt(index / self.width)) + 0.5) * raster_oversample,
                }),
            };
            const src: @Vector(4, f32) = .{
                @as(f32, @floatFromInt(color.r)) / 255.0 * share,
                @as(f32, @floatFromInt(color.g)) / 255.0 * share,
                @as(f32, @floatFromInt(color.b)) / 255.0 * share,
                @as(f32, @floatFromInt(color.a)) / 255.0 * share,
            };
            pixel.* = src + pixel.* * @as(@Vector(4, f32), @splat(1 - src[3]));
        }
    }

    fn finish(self: *Canvas, arena: std.mem.Allocator) ![]Color.PMA {
        const out = try arena.alloc(Color.PMA, self.pixels.len);
        for (self.pixels, out) |pixel, *pma| {
            const bytes = @round(@min(@as(@Vector(4, f32), @splat(1)), @max(@as(@Vector(4, f32), @splat(0)), pixel)) * @as(@Vector(4, f32), @splat(255)));
            pma.* = .{ .r = @intFromFloat(bytes[0]), .g = @intFromFloat(bytes[1]), .b = @intFromFloat(bytes[2]), .a = @intFromFloat(bytes[3]) };
        }
        return out;
    }
};

fn rasterCommand(arena: std.mem.Allocator, canvas: *Canvas, color_table: []const tvg.Color, cmd: parsing.DrawCommand, xf: Transform, opts: RenderOptions) !void {
    const raster = &canvas.raster;
    switch (cmd) {
        .fill_polygon => |fp| if (!opts.disable_fill) {
            try addPolygon(arena, raster, fp.vertices, xf);
            canvas.paint(.evenodd, resolveStyleSource(fp.style, color_table, opts, xf, false));
        },
        .fill_rectangles => |fr| if (!opts.disable_fill) {
            for (fr.rectangles) |r| try addRectangle(arena, raster, r, xf);
            canvas.paint(.nonzero, resolveStyleSource(fr.style, color_table, opts, xf, false));
        },
        .fill_path => |fp| if (!opts.disable_fill) {
            try addPathFill(arena, raster, fp.path, xf);
            canvas.paint(.evenodd, resolveStyleSource(fp.style, color_table, opts, xf, false));
        },
        .draw_lines => |dl| {
            const half = (opts.stroke_width_override orelse dl.line_width) * xf.meanScale() / 2;
            for (dl.lines) |ln| try addStroke(arena, raster, &.{ xf.apply(ln.start), xf.apply(ln.end) }, false, half);
            canvas.paint(.nonzero, resolveStyleSource(dl.style, color_table, opts, xf, true));
        },
        .draw_line_loop => |ls| {
            try addPolylineStroke(arena, raster, ls.vertices, true, (opts.stroke_width_override orelse ls.line_width) * xf.meanScale() / 2, xf);
            canvas.paint(.nonzero, resolveStyleSource(ls.style, color_table, opts, xf, true));
        },
        .draw_line_strip => |ls| {
            try addPolylineStroke(arena, raster, ls.vertices, false, (opts.stroke_width_override orelse ls.line_width) * xf.meanScale() / 2, xf);
            canvas.paint(.nonzero, resolveStyleSource(ls.style, color_table, opts, xf, true));
        },
        .draw_line_path => |dp| {
            try addPathStroke(arena, raster, dp.path, (opts.stroke_width_override orelse dp.line_width) * xf.meanScale() / 2, xf);
            canvas.paint(.nonzero, resolveStyleSource(dp.style, color_table, opts, xf, true));
        },
        .outline_fill_polygon => |o| {
            if (!opts.disable_fill) {
                try addPolygon(arena, raster, o.vertices, xf);
                canvas.paint(.evenodd, resolveStyleSource(o.fill_style, color_table, opts, xf, false));
            }
            try addPolylineStroke(arena, raster, o.vertices, true, (opts.stroke_width_override orelse o.line_width) * xf.meanScale() / 2, xf);
            canvas.paint(.nonzero, resolveStyleSource(o.line_style, color_table, opts, xf, true));
        },
        .outline_fill_rectangles => |o| {
            const half = (opts.stroke_width_override orelse o.line_width) * xf.meanScale() / 2;
            for (o.rectangles) |r| {
                if (!opts.disable_fill) {
                    try addRectangle(arena, raster, r, xf);
                    canvas.paint(.nonzero, resolveStyleSource(o.fill_style, color_table, opts, xf, false));
                }
                const corners = [_]Point{
                    xf.applyXY(r.x, r.y),
                    xf.applyXY(r.x + r.width, r.y),
                    xf.applyXY(r.x + r.width, r.y + r.height),
                    xf.applyXY(r.x, r.y + r.height),
                };
                try addStroke(arena, raster, &corners, true, half);
                canvas.paint(.nonzero, resolveStyleSource(o.line_style, color_table, opts, xf, true));
            }
        },
        .outline_fill_path => |o| {
            if (!opts.disable_fill) {
                try addPathFill(arena, raster, o.path, xf);
                canvas.paint(.evenodd, resolveStyleSource(o.fill_style, color_table, opts, xf, false));
            }
            try addPathStroke(arena, raster, o.path, (opts.stroke_width_override orelse o.line_width) * xf.meanScale() / 2, xf);
            canvas.paint(.nonzero, resolveStyleSource(o.line_style, color_table, opts, xf, true));
        },
    }
}

fn addPolygon(arena: std.mem.Allocator, raster: *coverage_raster.Rasterizer, vertices: []const tvg.Point, xf: Transform) !void {
    const points = try arena.alloc(Point, vertices.len);
    for (vertices, points) |vertex, *point| point.* = xf.apply(vertex);
    try raster.addContour(arena, points);
}

fn addRectangle(arena: std.mem.Allocator, raster: *coverage_raster.Rasterizer, r: tvg.Rectangle, xf: Transform) !void {
    try raster.addContour(arena, &.{
        xf.applyXY(r.x, r.y),
        xf.applyXY(r.x + r.width, r.y),
        xf.applyXY(r.x + r.width, r.y + r.height),
        xf.applyXY(r.x, r.y + r.height),
    });
}

fn addPathFill(arena: std.mem.Allocator, raster: *coverage_raster.Rasterizer, path: tvg.Path, xf: Transform) !void {
    for (path.segments) |segment| {
        var points: std.ArrayList(Point) = .empty;
        try flattenSegment(segment, xf, &points, arena);
        stripTrailingDuplicatesOfFirst(&points);
        collapseRunDuplicates(&points);
        try raster.addContour(arena, points.items);
    }
}

fn addPathStroke(arena: std.mem.Allocator, raster: *coverage_raster.Rasterizer, path: tvg.Path, half: f32, xf: Transform) !void {
    for (path.segments) |segment| {
        var points: std.ArrayList(Point) = .empty;
        try flattenSegment(segment, xf, &points, arena);
        if (points.items.len == 0) continue;
        const closed = points.items.len > 1 and approxEqPoint(points.items[0], points.items[points.items.len - 1]);
        if (closed) stripTrailingDuplicatesOfFirst(&points);
        collapseRunDuplicates(&points);
        try addStroke(arena, raster, points.items, closed, half);
    }
}

fn addPolylineStroke(arena: std.mem.Allocator, raster: *coverage_raster.Rasterizer, vertices: []const tvg.Point, closed: bool, half: f32, xf: Transform) !void {
    var points: std.ArrayList(Point) = .empty;
    for (vertices) |vertex| try points.append(arena, xf.apply(vertex));
    collapseRunDuplicates(&points);
    try addStroke(arena, raster, points.items, closed, half);
}

/// Add a polyline stroked `half` either side with round joins and caps, as
/// the shapes it is the union of: a band along every segment and a disc on
/// every point. All run the same way round, so under the nonzero rule their
/// overlaps are covered once.
fn addStroke(arena: std.mem.Allocator, raster: *coverage_raster.Rasterizer, points: []const Point, closed: bool, half: f32) !void {
    if (points.len == 0 or !(half > 0)) return;
    const segments = if (closed and points.len > 2) points.len else points.len - 1;
    for (0..segments) |index| {
        const from = points[index];
        const to = points[(index + 1) % points.len];
        const along = to.diff(from);
        const length = along.length();
        if (length < 1e-6) continue;
        // the left normal, `half` long
        const side: Point = .{ .x = -along.y / length * half, .y = along.x / length * half };
        try raster.addContour(arena, &.{ from.plus(side), to.plus(side), to.diff(side), from.diff(side) });
    }

    // a disc as round as the flattening: within 1/8 px on the icon
    const tolerance = 0.125 * raster_oversample;
    const step = math.acos(math.clamp(half / (half + tolerance), -1.0, 1.0));
    const count: usize = math.clamp(@as(usize, @intFromFloat(@ceil(2 * math.pi / @max(step, 1e-3)))), 8, 256);
    const disc = try arena.alloc(Point, count);
    for (points) |centre| {
        for (disc, 0..) |*point, index| {
            // clockwise on screen, the way the bands run
            const angle = -2 * math.pi * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count));
            point.* = .{ .x = centre.x + half * @cos(angle), .y = centre.y + half * @sin(angle) };
        }
        try raster.addContour(arena, disc);
    }
}

pub fn appendTvg(
    scratch_alloc: std.mem.Allocator,
    mesh: *MeshBuilder,
    tvg_bytes: []const u8,
    rect: Rect,
    opts: RenderOptions,
) !void {
    var fbs: std.Io.Reader = .fixed(tvg_bytes);
    var parser = try tvg.parse(scratch_alloc, &fbs);
    defer parser.deinit();

    const xf = Transform.fromRect(rect, @floatFromInt(parser.header.width), @floatFromInt(parser.header.height), opts.keep_aspect);

    var opts_with_bounds = opts;
    opts_with_bounds.bounds = rect;

    while (try parser.next()) |cmd| {
        try renderCommand(scratch_alloc, mesh, parser.color_table, cmd, xf, opts_with_bounds);
    }
}

// ---------------------------------------------------------------------------
// Transform: TVG-space -> physical-pixel space
// ---------------------------------------------------------------------------

const Transform = struct {
    ox: f32,
    oy: f32,
    sx: f32,
    sy: f32,

    fn fromRect(rect: Rect, w: f32, h: f32, keep_aspect: bool) Transform {
        var sx = rect.w / w;
        var sy = rect.h / h;
        var ox = rect.x;
        var oy = rect.y;
        if (keep_aspect) {
            const s = @min(sx, sy);
            sx = s;
            sy = s;
            ox = rect.x + (rect.w - w * s) * 0.5;
            oy = rect.y + (rect.h - h * s) * 0.5;
        }
        return .{ .ox = ox, .oy = oy, .sx = sx, .sy = sy };
    }

    fn apply(self: Transform, p: tvg.Point) Point {
        return .{ .x = self.ox + p.x * self.sx, .y = self.oy + p.y * self.sy };
    }

    fn applyXY(self: Transform, x: f32, y: f32) Point {
        return .{ .x = self.ox + x * self.sx, .y = self.oy + y * self.sy };
    }

    /// Average of x/y scale - for stroke widths.
    fn meanScale(self: Transform) f32 {
        return (@abs(self.sx) + @abs(self.sy)) * 0.5;
    }
};

// ---------------------------------------------------------------------------
// Command dispatch
// ---------------------------------------------------------------------------

fn renderCommand(
    allocator: std.mem.Allocator,
    mesh: *MeshBuilder,
    color_table: []const tvg.Color,
    cmd: parsing.DrawCommand,
    xf: Transform,
    opts: RenderOptions,
) !void {
    switch (cmd) {
        .fill_polygon => |fp| {
            if (!opts.disable_fill) {
                try fillPolygonTvg(allocator, mesh, fp.vertices, fp.style, color_table, xf, opts);
            }
        },
        .fill_rectangles => |fr| {
            if (!opts.disable_fill) {
                const col = resolveStyleSource(fr.style, color_table, opts, xf, false);
                for (fr.rectangles) |r| try fillTvgRect(allocator, mesh, r, col, xf, opts.fade);
            }
        },
        .fill_path => |fp| {
            if (!opts.disable_fill) {
                try fillPathTvg(allocator, mesh, fp.path, fp.style, color_table, xf, opts);
            }
        },
        .draw_lines => |dl| {
            const col = resolveStyleSource(dl.style, color_table, opts, xf, true);
            const thickness = (opts.stroke_width_override orelse dl.line_width) * xf.meanScale();
            for (dl.lines) |ln| try strokeLine(allocator, mesh, xf.apply(ln.start), xf.apply(ln.end), col, thickness);
        },
        .draw_line_loop => |ls| {
            const col = resolveStyleSource(ls.style, color_table, opts, xf, true);
            try strokePolylineTvg(allocator, mesh, ls.vertices, true, opts.stroke_width_override orelse ls.line_width, col, xf);
        },
        .draw_line_strip => |ls| {
            const col = resolveStyleSource(ls.style, color_table, opts, xf, true);
            try strokePolylineTvg(allocator, mesh, ls.vertices, false, opts.stroke_width_override orelse ls.line_width, col, xf);
        },
        .draw_line_path => |dp| {
            const col = resolveStyleSource(dp.style, color_table, opts, xf, true);
            try strokePathTvg(allocator, mesh, dp.path, opts.stroke_width_override orelse dp.line_width, col, xf);
        },
        .outline_fill_polygon => |o| {
            if (!opts.disable_fill) {
                try fillPolygonTvg(allocator, mesh, o.vertices, o.fill_style, color_table, xf, opts);
            }
            const stroke_col = resolveStyleSource(o.line_style, color_table, opts, xf, true);
            try strokePolylineTvg(allocator, mesh, o.vertices, true, opts.stroke_width_override orelse o.line_width, stroke_col, xf);
        },
        .outline_fill_rectangles => |o| {
            const stroke_col = resolveStyleSource(o.line_style, color_table, opts, xf, true);
            const thickness = (opts.stroke_width_override orelse o.line_width) * xf.meanScale();
            for (o.rectangles) |r| {
                if (!opts.disable_fill) {
                    const fill_col = resolveStyleSource(o.fill_style, color_table, opts, xf, false);
                    try fillTvgRect(allocator, mesh, r, fill_col, xf, opts.fade);
                }
                try strokeTvgRect(allocator, mesh, r, stroke_col, thickness, xf);
            }
        },
        .outline_fill_path => |o| {
            if (!opts.disable_fill) {
                try fillPathTvg(allocator, mesh, o.path, o.fill_style, color_table, xf, opts);
            }
            try strokePathTvg(allocator, mesh, o.path, opts.stroke_width_override orelse o.line_width, resolveStyleSource(o.line_style, color_table, opts, xf, true), xf);
        },
    }
}

// ---------------------------------------------------------------------------
// Color helpers
// ---------------------------------------------------------------------------

fn tvgColorToDvui(c: tvg.Color) Color {
    return .{
        .r = @intFromFloat(math.clamp(c.r * 255.0, 0.0, 255.0)),
        .g = @intFromFloat(math.clamp(c.g * 255.0, 0.0, 255.0)),
        .b = @intFromFloat(math.clamp(c.b * 255.0, 0.0, 255.0)),
        .a = @intFromFloat(math.clamp(c.a * 255.0, 0.0, 255.0)),
    };
}

const ColorSource = union(enum) {
    flat: Color.PMA,
    linear: struct {
        c0: Color,
        c1: Color,
        p0: Point,
        p1: Point,
    },
    radial: struct {
        c0: Color,
        c1: Color,
        center: Point,
        edge: Point,
    },
    /// A caller-supplied `dvui.Gradient` override (from
    /// `IconRenderOptions.fill_color`/`stroke_color`), already anchored to
    /// the icon's bounding box by `colorSourceFromOverride`.
    dvui_gradient: Gradient,

    /// Builds the equivalent `dvui.Gradient` for any non-`.flat` source.
    /// `storage` backs the synthesized 2-stop slice for `.linear`/`.radial`
    /// and must outlive the returned `Gradient`'s use (`.dvui_gradient`
    /// already owns caller-provided stops and ignores it).
    fn toGradient(self: ColorSource, storage: *[2]Gradient.Stop) Gradient {
        return switch (self) {
            .flat => unreachable,
            .linear => |g| linearGradientBetween(storage, g.c0, g.c1, g.p0, g.p1),
            .radial => |g| radialGradientBetween(storage, g.c0, g.c1, g.center, g.edge),
            .dvui_gradient => |g| g,
        };
    }

    fn sampleColor(self: ColorSource, p: Point) Color {
        return switch (self) {
            .flat => |pma| pma.toColor(),
            else => blk: {
                var storage: [2]Gradient.Stop = undefined;
                break :blk self.toGradient(&storage).sample(.{}, p);
            },
        };
    }

    fn sample(self: ColorSource, p: Point) Color.PMA {
        return switch (self) {
            .flat => |pma| pma,
            else => .fromColor(self.sampleColor(p)),
        };
    }
};

/// Builds a `dvui.Gradient.linear` whose `t=0`/`t=1` points are exactly
/// `p0`/`p1` - not derived from any shape's bounding box - by picking a
/// synthetic `anchor` sized so `Gradient.linearT`'s box-projection formula
/// reduces to a plain projection onto the `p0->p1` segment (all the
/// projected half-extent is put on whichever axis the segment is more
/// aligned with; the other axis gets a zero half-extent, which
/// `Gradient.sampleRaw`'s degenerate check tolerates as long as the other
/// axis is nonzero). Lets TVG's native 2-point linear gradient style go
/// through `Path.fillTriangles`'s gradient support (ramp texture + UV)
/// instead of a bespoke per-vertex Gouraud shader.
fn linearGradientBetween(storage: *[2]Gradient.Stop, c0: Color, c1: Color, p0: Point, p1: Point) Gradient {
    storage.* = .{ .{ .color = c0, .offset = 0 }, .{ .color = c1, .offset = 1 } };
    const dx = p1.x - p0.x;
    const dy = p1.y - p0.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1e-6) {
        return .{ .linear = .{ .stops = storage, .anchor = .{ .x = p0.x, .y = p0.y, .w = 0, .h = 0 } } };
    }
    const adx = @abs(dx) / len;
    const ady = @abs(dy) / len;
    const half = len / 2;
    var hx: f32 = 0;
    var hy: f32 = 0;
    if (adx >= ady) hx = half / adx else hy = half / ady;
    return .{ .linear = .{
        .stops = storage,
        .angle_degrees = math.radiansToDegrees(math.atan2(dy, dx)),
        .anchor = .{
            .x = (p0.x + p1.x) / 2 - hx,
            .y = (p0.y + p1.y) / 2 - hy,
            .w = 2 * hx,
            .h = 2 * hy,
        },
    } };
}

/// Builds a `dvui.Gradient.radial` whose ending circle is exactly
/// `center`/`|edge - center|` - not derived from any shape's bounding box -
/// via an explicit `.circle{.radius=}` and an `anchor` centered on `center`.
/// See `linearGradientBetween`.
fn radialGradientBetween(storage: *[2]Gradient.Stop, c0: Color, c1: Color, center: Point, edge: Point) Gradient {
    storage.* = .{ .{ .color = c0, .offset = 0 }, .{ .color = c1, .offset = 1 } };
    const dx = edge.x - center.x;
    const dy = edge.y - center.y;
    const radius = @sqrt(dx * dx + dy * dy);
    if (radius < 1e-6) {
        return .{ .radial = .{ .stops = storage, .anchor = .{ .x = center.x, .y = center.y, .w = 0, .h = 0 } } };
    }
    return .{ .radial = .{
        .stops = storage,
        .shape = .{ .circle = .{ .radius = radius } },
        .anchor = .{ .x = center.x - radius, .y = center.y - radius, .w = 2 * radius, .h = 2 * radius },
    } };
}

/// Build a `ColorSource` from a TVG style.  Override forces flat.  Gradient
/// endpoints are transformed into physical pixel space so per-vertex
/// sampling is a single dot product / distance.
fn colorSourceFromOverride(c: ColorOrGradient, bounds: Rect) ColorSource {
    return switch (c) {
        .color => |col| .{ .flat = .fromColor(col) },
        .gradient => |g| .{ .dvui_gradient = withDefaultAnchor(g, bounds) },
    };
}

fn resolveStyleSource(style: tvg.Style, color_table: []const tvg.Color, opts: RenderOptions, xf: Transform, is_stroke: bool) ColorSource {
    if (opts.color_override) |c| return colorSourceFromOverride(c, opts.bounds);
    if (is_stroke) {
        if (opts.stroke_color_override) |c| return colorSourceFromOverride(c, opts.bounds);
    } else {
        if (opts.fill_color_override) |c| return colorSourceFromOverride(c, opts.bounds);
    }
    return switch (style) {
        .flat => |idx| .{ .flat = .fromColor(tvgColorToDvui(color_table[idx])) },
        .linear => |g| .{ .linear = .{
            .c0 = tvgColorToDvui(color_table[g.color_0]),
            .c1 = tvgColorToDvui(color_table[g.color_1]),
            .p0 = xf.apply(g.point_0),
            .p1 = xf.apply(g.point_1),
        } },
        .radial => |g| .{ .radial = .{
            .c0 = tvgColorToDvui(color_table[g.color_0]),
            .c1 = tvgColorToDvui(color_table[g.color_1]),
            .center = xf.apply(g.point_0),
            .edge = xf.apply(g.point_1),
        } },
    };
}

// ---------------------------------------------------------------------------
// Fill / stroke primitives in physical-pixel space
// ---------------------------------------------------------------------------

fn fillTvgRect(allocator: std.mem.Allocator, mesh: *MeshBuilder, r: tvg.Rectangle, source: ColorSource, xf: Transform, fade: f32) !void {
    const pts = [_]Point{
        xf.applyXY(r.x, r.y),
        xf.applyXY(r.x + r.width, r.y),
        xf.applyXY(r.x + r.width, r.y + r.height),
        xf.applyXY(r.x, r.y + r.height),
    };
    try fillContoursPhysical(allocator, mesh, &.{&pts}, source, fade);
}

fn strokeTvgRect(allocator: std.mem.Allocator, mesh: *MeshBuilder, r: tvg.Rectangle, source: ColorSource, thickness: f32, xf: Transform) !void {
    const pts = [_]Point{
        xf.applyXY(r.x, r.y),
        xf.applyXY(r.x + r.width, r.y),
        xf.applyXY(r.x + r.width, r.y + r.height),
        xf.applyXY(r.x, r.y + r.height),
    };
    try strokePolylineRoundJoined(allocator, mesh, &pts, true, thickness, source);
}

fn strokeLine(allocator: std.mem.Allocator, mesh: *MeshBuilder, p0: Point, p1: Point, source: ColorSource, thickness: f32) !void {
    const pts = [_]Point{ p0, p1 };
    try strokePolylineRoundJoined(allocator, mesh, &pts, false, thickness, source);
}

fn withDefaultAnchor(g: Gradient, bounds: Rect) Gradient {
    var out = g;
    switch (out) {
        .linear => |*l| if (l.anchor == null) {
            l.anchor = bounds;
        },
        .radial => |*r| if (r.anchor == null) {
            r.anchor = bounds;
        },
        .scattered => |*s| if (s.anchor == null) {
            s.anchor = bounds;
        },
    }
    return out;
}

/// Fill one or more closed contours (outers AND holes, any winding) via
/// `dvui.Path.fillTriangles`'s nonzero-winding trapezoidal decomposition -
/// concave shapes, holes, and small self-intersections (left over from
/// bezier/arc flattening) are all handled without a bespoke triangulator.
fn fillContoursPhysical(
    allocator: std.mem.Allocator,
    mesh: *MeshBuilder,
    contours: []const []const Point,
    source: ColorSource,
    fade: f32,
) !void {
    if (contours.len == 0) return;

    const paths = try allocator.alloc(Path, contours.len);
    defer allocator.free(paths);
    for (contours, 0..) |c, i| paths[i] = .{ .points = c };

    var storage: [2]Gradient.Stop = undefined;
    const color: ColorOrGradient = switch (source) {
        .flat => |pma| .{ .color = pma.toColor() },
        else => .{ .gradient = source.toGradient(&storage) },
    };
    const tex_key: ?dvui.Texture.Cache.Key = if (color == .gradient) color.gradient.textureCacheKey(.{}) else null;
    var tri = try Path.fillTriangles(allocator, paths, .{
        .color = color,
        .fade = fade,
        .fill_rule = .nonzero,
    });
    defer tri.deinit(allocator);
    try mesh.appendMesh(tri, tex_key);
}

/// Spec-compliant-ish stroke with round joins AND round caps - the style
/// SVG-origin icons (feather, lucide, entypo, ...) are authored for.
///
/// `dvui.Path.strokeTriangles` only does miter joins and square/none caps,
/// so each edge is stroked separately with butt caps (no overlap, no miter
/// spikes at sharp corners), and a filled disc is placed at every vertex to
/// act as the round join (filling the wedge between adjacent edges) and,
/// for open paths, the round cap at each endpoint.  Both primitives get
/// `dvui`'s normal 1px AA fade.
fn strokePolylineRoundJoined(
    allocator: std.mem.Allocator,
    mesh: *MeshBuilder,
    pts: []const Point,
    closed: bool,
    thickness: f32,
    source: ColorSource,
) !void {
    if (pts.len < 2) return;
    const radius = thickness * 0.5;
    if (radius <= 0) return;
    const n = pts.len;
    const edge_count: usize = if (closed) n else n - 1;

    var ei: usize = 0;
    while (ei < edge_count) : (ei += 1) {
        const a = pts[ei];
        const b = pts[(ei + 1) % n];
        if (a.diff(b).length() < 1e-6) continue;

        const edge_path: Path = .{ .points = &.{ a, b } };
        const col = switch (source) {
            .flat => |pma| pma.toColor(),
            else => source.sampleColor(mid(a, b)),
        };
        var tri = try edge_path.strokeTriangles(allocator, .{
            .thickness = thickness,
            .color = .{ .color = col },
            .closed = false,
            .endcap_style = .none,
        });
        defer tri.deinit(allocator);
        try mesh.appendMesh(tri, null);
    }

    for (pts) |p| {
        var builder: Path.Builder = .init(allocator);
        defer builder.deinit();
        builder.addArc(p, radius, math.pi * 2.0, 0, true);
        const disc = builder.build();
        const col = switch (source) {
            .flat => |pma| pma.toColor(),
            else => source.sampleColor(p),
        };
        var tri = try disc.fillConvexTriangles(allocator, .{ .color = .{ .color = col }, .fade = 1.0 });
        defer tri.deinit(allocator);
        try mesh.appendMesh(tri, null);
    }
}

fn fillPolygonTvg(
    allocator: std.mem.Allocator,
    mesh: *MeshBuilder,
    vertices: []const tvg.Point,
    style: tvg.Style,
    color_table: []const tvg.Color,
    xf: Transform,
    opts: RenderOptions,
) !void {
    if (vertices.len < 3) return;
    const source = resolveStyleSource(style, color_table, opts, xf, false);

    const pts = try allocator.alloc(Point, vertices.len);
    defer allocator.free(pts);
    for (vertices, 0..) |v, i| pts[i] = xf.apply(v);

    try fillContoursPhysical(allocator, mesh, &.{pts}, source, opts.fade);
}

fn strokePolylineTvg(
    allocator: std.mem.Allocator,
    mesh: *MeshBuilder,
    vertices: []const tvg.Point,
    closed: bool,
    line_width: f32,
    source: ColorSource,
    xf: Transform,
) !void {
    if (vertices.len < 2) return;
    const thickness = line_width * xf.meanScale();
    const pts = try allocator.alloc(Point, vertices.len);
    defer allocator.free(pts);
    for (vertices, 0..) |v, i| pts[i] = xf.apply(v);
    try strokePolylineRoundJoined(allocator, mesh, pts, closed, thickness, source);
}

// ---------------------------------------------------------------------------
// Path flattening (TVG path -> polyline in physical pixels)
// ---------------------------------------------------------------------------

/// Flatten one TVG path segment into a polyline of physical points.
/// Per-node `line_width` is ignored - fills don't use it, and strokes use
/// the command-level line_width (per-node widths would need segment-wise
/// stroking, which isn't supported).
fn flattenSegment(
    segment: tvg.Path.Segment,
    xf: Transform,
    out: *std.ArrayList(Point),
    alloc: std.mem.Allocator,
) !void {
    var cur = segment.start;
    try out.append(alloc, xf.apply(cur));

    for (segment.commands) |node| {
        switch (node) {
            .line => |n| {
                cur = n.data;
                try out.append(alloc, xf.apply(cur));
            },
            .horiz => |n| {
                cur.x = n.data;
                try out.append(alloc, xf.apply(cur));
            },
            .vert => |n| {
                cur.y = n.data;
                try out.append(alloc, xf.apply(cur));
            },
            .bezier => |n| {
                try flattenCubic(out, alloc, xf, cur, n.data.c0, n.data.c1, n.data.p1);
                cur = n.data.p1;
            },
            .quadratic_bezier => |n| {
                try flattenQuadratic(out, alloc, xf, cur, n.data.c, n.data.p1);
                cur = n.data.p1;
            },
            .arc_circle => |n| {
                // NOTE: svg2tvg encodes the sweep bit INVERTED relative to
                // the SVG convention, so the flip here is required for
                // rounded corners to come out convex instead of concave.
                try flattenArc(out, alloc, xf, cur, n.data.radius, n.data.radius, 0, n.data.large_arc, !n.data.sweep, n.data.target);
                cur = n.data.target;
            },
            .arc_ellipse => |n| {
                try flattenArc(out, alloc, xf, cur, n.data.radius_x, n.data.radius_y, n.data.rotation, n.data.large_arc, !n.data.sweep, n.data.target);
                cur = n.data.target;
            },
            .close => {
                cur = segment.start;
                // For fill use, the caller adds the closing edge implicitly
                // (the polygon's last -> first vertex).  For stroke use,
                // append the start so the stroke draws the closing segment.
                try out.append(alloc, xf.apply(cur));
            },
        }
    }
}

/// Adaptive subdivision of a cubic Bezier, delegating to
/// `Path.Builder.addCubicBezier` (same 0.5px chord-deviation tolerance
/// already used everywhere else in dvui) instead of reimplementing de
/// Casteljau subdivision here. Endpoint p0 is assumed already in `out`;
/// only p1, intermediate, and final points are appended.
fn flattenCubic(
    out: *std.ArrayList(Point),
    alloc: std.mem.Allocator,
    xf: Transform,
    p0: tvg.Point,
    p1: tvg.Point,
    p2: tvg.Point,
    p3: tvg.Point,
) !void {
    var builder: Path.Builder = .init(alloc);
    defer builder.deinit();
    builder.addCubicBezier(xf.apply(p0), xf.apply(p1), xf.apply(p2), xf.apply(p3));
    // `addCubicBezier` includes p0, which is already in `out`.
    try out.appendSlice(alloc, builder.build().points[1..]);
}

fn flattenQuadratic(
    out: *std.ArrayList(Point),
    alloc: std.mem.Allocator,
    xf: Transform,
    p0: tvg.Point,
    p1: tvg.Point,
    p2: tvg.Point,
) !void {
    var builder: Path.Builder = .init(alloc);
    defer builder.deinit();
    builder.addQuadBezier(xf.apply(p0), xf.apply(p1), xf.apply(p2));
    try out.appendSlice(alloc, builder.build().points[1..]);
}

/// SVG arc -> center-parameterization -> sampled chord.  Reference:
/// https://www.w3.org/TR/SVG/implnote.html#ArcImplementationNotes
fn flattenArc(
    out: *std.ArrayList(Point),
    alloc: std.mem.Allocator,
    xf: Transform,
    p0: tvg.Point,
    rx_in: f32,
    ry_in: f32,
    rotation_deg: f32,
    large_arc: bool,
    sweep: bool,
    p1: tvg.Point,
) !void {
    var rx = @abs(rx_in);
    var ry = @abs(ry_in);
    if (rx == 0 or ry == 0) {
        try out.append(alloc, xf.apply(p1));
        return;
    }

    const phi = rotation_deg * math.pi / 180.0;
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);

    // Step 1: transform to origin-centered, axis-aligned ellipse.
    const dx = (p0.x - p1.x) * 0.5;
    const dy = (p0.y - p1.y) * 0.5;
    const x1p = cos_phi * dx + sin_phi * dy;
    const y1p = -sin_phi * dx + cos_phi * dy;

    // Ensure radii are large enough.
    const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) {
        const s = @sqrt(lambda);
        rx *= s;
        ry *= s;
    }

    // Step 2: compute center in transformed coords.
    const sign: f32 = if (large_arc == sweep) -1.0 else 1.0;
    var num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    if (num < 0) num = 0;
    const factor = sign * @sqrt(num / den);
    const cxp = factor * (rx * y1p) / ry;
    const cyp = factor * -(ry * x1p) / rx;

    // Step 3: untransform.
    const cx = cos_phi * cxp - sin_phi * cyp + (p0.x + p1.x) * 0.5;
    const cy = sin_phi * cxp + cos_phi * cyp + (p0.y + p1.y) * 0.5;

    // Step 4: start angle + sweep delta.
    const ux = (x1p - cxp) / rx;
    const uy = (y1p - cyp) / ry;
    const vx = (-x1p - cxp) / rx;
    const vy = (-y1p - cyp) / ry;

    const theta1 = math.atan2(uy, ux);
    var delta = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    if (!sweep and delta > 0) delta -= 2 * math.pi;
    if (sweep and delta < 0) delta += 2 * math.pi;

    // Chord-deviation budget of 0.5 px.
    const r_max = @max(rx, ry) * xf.meanScale();
    const err: f32 = 0.5;
    const theta_step = math.acos(math.clamp(r_max / (r_max + err), -1.0, 1.0));
    var n: usize = @intFromFloat(@ceil(@abs(delta) / @max(theta_step, 1e-4)));
    n = math.clamp(n, 4, 512);

    var i: usize = 1;
    while (i < n) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const theta = theta1 + delta * t;
        const ct = @cos(theta);
        const st = @sin(theta);
        const x = cos_phi * rx * ct - sin_phi * ry * st + cx;
        const y = sin_phi * rx * ct + cos_phi * ry * st + cy;
        try out.append(alloc, xf.applyXY(x, y));
    }
    // ALWAYS land the final vertex on `target` exactly - floating-point
    // accumulation could otherwise leave a sub-pixel gap.
    try out.append(alloc, xf.apply(p1));
}

fn fillPathTvg(
    allocator: std.mem.Allocator,
    mesh: *MeshBuilder,
    path: tvg.Path,
    style: tvg.Style,
    color_table: []const tvg.Color,
    xf: Transform,
    opts: RenderOptions,
) !void {
    const source = resolveStyleSource(style, color_table, opts, xf, false);

    // Flatten every segment into its own polyline.  Each becomes a
    // separate contour passed to `fillContoursPhysical` - outers and holes
    // alike, in whatever winding order they were authored.  Winding
    // resolution (nonzero rule) happens inside `Path.fillTriangles`.
    var subpaths = std.ArrayList([]Point).empty;
    defer {
        for (subpaths.items) |sp| allocator.free(sp);
        subpaths.deinit(allocator);
    }

    for (path.segments) |seg| {
        var pts = std.ArrayList(Point).empty;
        errdefer pts.deinit(allocator);
        try flattenSegment(seg, xf, &pts, allocator);
        stripTrailingDuplicatesOfFirst(&pts);
        // Degenerate Beziers (control points coincident with endpoints)
        // and encoders chaining straight segments through curves can
        // produce runs of identical points; collapse them.
        collapseRunDuplicates(&pts);
        if (pts.items.len < 3) {
            pts.deinit(allocator);
            continue;
        }
        try subpaths.append(allocator, try pts.toOwnedSlice(allocator));
    }

    if (subpaths.items.len == 0) return;
    try fillContoursPhysical(allocator, mesh, subpaths.items, source, opts.fade);
}

fn strokePathTvg(
    allocator: std.mem.Allocator,
    mesh: *MeshBuilder,
    path: tvg.Path,
    line_width: f32,
    source: ColorSource,
    xf: Transform,
) !void {
    const thickness = line_width * xf.meanScale();
    var pts = std.ArrayList(Point).empty;
    defer pts.deinit(allocator);
    for (path.segments) |seg| {
        pts.clearRetainingCapacity();
        try flattenSegment(seg, xf, &pts, allocator);
        if (pts.items.len < 2) continue;
        const closed = pts.items.len > 1 and approxEqPoint(pts.items[0], pts.items[pts.items.len - 1]);
        if (closed) stripTrailingDuplicatesOfFirst(&pts);
        collapseRunDuplicates(&pts);
        if (pts.items.len < 2) continue;
        try strokePolylineRoundJoined(allocator, mesh, pts.items, closed, thickness, source);
    }
}

// ---------------------------------------------------------------------------
// Small geometry helpers
// ---------------------------------------------------------------------------

fn mid(a: Point, b: Point) Point {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}

fn approxEqPoint(a: Point, b: Point) bool {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return (dx * dx + dy * dy) < 1e-6;
}

/// Pop every trailing point that coincides with `pts[0]`.  Common after
/// closing a sub-path: the last drawing command lands on `start` AND the
/// explicit `.close` node appends `start` again, producing two duplicates.
fn stripTrailingDuplicatesOfFirst(pts: *std.ArrayList(Point)) void {
    while (pts.items.len > 1 and approxEqPoint(pts.items[0], pts.items[pts.items.len - 1])) {
        _ = pts.pop();
    }
}

/// Compact consecutive duplicate points.  A near-zero-length edge produces
/// a degenerate join normal downstream.
fn collapseRunDuplicates(pts: *std.ArrayList(Point)) void {
    if (pts.items.len < 2) return;
    var w: usize = 1;
    for (pts.items[1..]) |p| {
        if (!approxEqPoint(pts.items[w - 1], p)) {
            pts.items[w] = p;
            w += 1;
        }
    }
    pts.shrinkRetainingCapacity(w);
}

const std = @import("std");
const math = std.math;
const dvui = @import("dvui.zig");

const svg2tvg = @import("svg2tvg");
const coverage_raster = @import("coverage.zig");
const tvg = svg2tvg.tvg;
const parsing = tvg.parsing;

const Backend = dvui.Backend;
const Point = dvui.Point.Physical;
const Rect = dvui.Rect.Physical;
const Color = dvui.Color;
const Vertex = dvui.Vertex;
const Triangles = dvui.Triangles;
const Path = dvui.Path;
const Gradient = dvui.Gradient;
const ColorOrGradient = dvui.ColorOrGradient;

test {
    std.testing.refAllDecls(@This());
}

/// A 24 x 24 TVG (the grid Lucide draws on) holding one stroked circle of
/// radius 10 around (12, 12), 2 wide, drawn as two arcs: `circle` as an
/// SVG-to-TVG conversion writes it. Written into `buffer`.
fn testCircleTvg(buffer: []u8) ![]const u8 {
    const Node = tvg.Path.Node;
    var builder = tvg.builder.create(std.Io.Writer.fixed(buffer));
    try builder.writeHeader(24, 24, .@"1/256", .u8888, .default);
    try builder.writeColorTable(&.{try tvg.Color.fromString("ffffff")});
    try builder.writeDrawPath(.{ .flat = 0 }, 2, &.{.{
        .start = tvg.point(22, 12),
        .commands = &.{
            Node{ .arc_circle = .{ .data = .{ .radius = 10, .large_arc = false, .sweep = false, .target = tvg.point(2, 12) } } },
            Node{ .arc_circle = .{ .data = .{ .radius = 10, .large_arc = false, .sweep = false, .target = tvg.point(22, 12) } } },
            Node{ .close = .{ .data = {} } },
        },
    }});
    try builder.writeEndOfFile();
    return buffer[0..builder.writer.end];
}

/// Draw `tvg_bytes` with `renderIcon` into `rect` (physical pixels) inside a
/// picture `size` physical pixels big, and answer each pixel's coverage
/// (alpha, 0..1), row by row.
fn testIconCoverage(gpa: std.mem.Allocator, tvg_bytes: []const u8, rect: Rect, size: dvui.Size.Physical) ![]f32 {
    const area: Rect = .{ .x = 0, .y = 0, .w = size.w, .h = size.h };
    var picture = dvui.Picture.start(area) orelse return error.SkipZigTest;
    try dvui.renderIcon("test", tvg_bytes, .{ .r = rect, .s = 1.75 }, .{}, .{});
    picture.stop();
    const cw = dvui.currentWindow();
    const pixels = try dvui.textureReadTarget(cw.lifo(), picture.texture);
    defer cw.lifo().free(pixels);
    const coverage = try gpa.alloc(f32, pixels.len);
    for (pixels, coverage) |pixel, *out| out.* = @as(f32, @floatFromInt(pixel.a)) / 255.0;
    picture.deinit();
    return coverage;
}

/// The share of pixel (`column`, `row`) inside the ring of radius `radius`
/// and half width `half` around `centre`, from 16 x 16 samples.
fn testRingCoverage(centre: Point, radius: f32, half: f32, column: usize, row: usize) f32 {
    var inside: f32 = 0;
    for (0..16) |sample_y| {
        for (0..16) |sample_x| {
            const x = @as(f32, @floatFromInt(column)) + (@as(f32, @floatFromInt(sample_x)) + 0.5) / 16 - centre.x;
            const y = @as(f32, @floatFromInt(row)) + (@as(f32, @floatFromInt(sample_y)) + 0.5) / 16 - centre.y;
            if (@abs(@sqrt(x * x + y * y) - radius) <= half) inside += 1;
        }
    }
    return inside / 256;
}

test "a stroked circle is one even ring: no beads where its pieces join" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 100, .h = 100 } });
    defer t.deinit();

    var buffer: [256]u8 = undefined;
    const bytes = try testCircleTvg(&buffer);

    // 16 logical pixels at 1.75: a 28 px icon, its ring 11.67 px round and
    // 2.33 px wide, as Lucide's circle is in the editor.
    const size: dvui.Size.Physical = .{ .w = 48, .h = 48 };
    const width: usize = @intFromFloat(size.w);
    const coverage = try testIconCoverage(std.testing.allocator, bytes, .{ .x = 10, .y = 10, .w = 28, .h = 28 }, size);
    defer std.testing.allocator.free(coverage);

    const centre: Point = .{ .x = 24, .y = 24 };
    const radius: f32 = 10.0 * 28.0 / 24.0;
    const half: f32 = 28.0 / 24.0;

    // The ink in each of 72 sectors against the true ring's: beads (two
    // anti-aliased edges laid over each other at every joint) or facets
    // make some sectors heavier than others.
    const sectors = 72;
    var drawn: [sectors]f32 = @splat(0);
    var ideal: [sectors]f32 = @splat(0);
    var worst_pixel: f32 = 0;
    for (coverage, 0..) |value, index| {
        const column = index % width;
        const row = index / width;
        const expected = testRingCoverage(centre, radius, half, column, row);
        worst_pixel = @max(worst_pixel, @abs(value - expected));
        const angle = math.atan2(@as(f32, @floatFromInt(row)) + 0.5 - centre.y, @as(f32, @floatFromInt(column)) + 0.5 - centre.x);
        const sector: usize = @min(sectors - 1, @as(usize, @intFromFloat((angle + math.pi) / (2 * math.pi) * sectors)));
        drawn[sector] += value;
        ideal[sector] += expected;
    }
    var lightest: f32 = math.floatMax(f32);
    var heaviest: f32 = 0;
    for (drawn, ideal) |ink, truth| {
        lightest = @min(lightest, ink / truth);
        heaviest = @max(heaviest, ink / truth);
    }
    errdefer std.debug.print("the ring's sectors carry {d} to {d} of their true ink; the worst pixel is {d} off\n", .{ lightest, heaviest, worst_pixel });
    try std.testing.expect(heaviest - lightest <= 0.04);
    try std.testing.expect(worst_pixel <= 0.06);
}

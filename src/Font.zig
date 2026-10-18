const std = @import("std");
const dvui = @import("dvui.zig");
const c = dvui.c;

const Rect = dvui.Rect;
const Size = dvui.Size;
const Texture = dvui.Texture;
const Backend = dvui.Backend;
const gpos_kern = @import("gpos_kern.zig");

/// Font represents the parameters that dvui will try to satisfy when rendering
/// text.  If a matching font is not found, dvui will log an error and use the
/// internal fallback font.
///
/// Usually specified with `find`:
/// const f: Font = .find(.{ .family = "Vera", .size = 12 });
///
/// To source a Font from the theme, use `theme`:
/// const f: Font = .theme(.mono);
/// const f = Font.theme(mono).larger(2);
const Font = @This();

pub const DefaultSize = 10;

const impl: enum { FreeType, STB } = if (dvui.useFreeType) .FreeType else .STB;
pub const Error = error{FontError};
pub const NAME_MAX_LEN = 50;

pub fn array(s: []const u8) [NAME_MAX_LEN:0]u8 {
    var v: [NAME_MAX_LEN:0]u8 = @splat(0);
    @memcpy(v[0..s.len], s);
    return v;
}

pub fn string(s: *const [NAME_MAX_LEN:0]u8) [:0]const u8 {
    return std.mem.sliceTo(s, 0);
}

pub const Weight = enum {
    normal,
    light,
    medium,
    semi_bold,
    bold,
};

pub const Style = enum {
    normal,
    italic,
};

pub const Underline = struct {
    /// Percent of font size, will always be at least 1 logical pixel
    thick: f32 = 0.1,
};

pub const Strike = struct {
    /// Percent of font size, will always be at least 1 logical pixel
    thick: f32 = 0.1,
};

/// Changing any of these might query for a font.
family: [NAME_MAX_LEN:0]u8 = @splat(0),

/// Font size in logical pixels. Interpretation depends on `size_mode`:
/// - `.cap_height` (default): Height of a capital M. After converting to physical
///   pixels, the font will have an integer M height <= size.
/// - `.pixel`: CSS-style em-square size. The FreeType pixel_size is set directly
///   to this value without cap-height searching.
size: f32 = DefaultSize,
weight: Weight = .normal,
style: Style = .normal,
size_mode: SizeMode = .cap_height,

/// Can be changed for any font, no query.
line_height_factor: f32 = 1.2,
underline: ?Underline = null,
strike: ?Strike = null,

pub const SizeMode = enum {
    /// Default: size = cap height (M glyph must fit within `size` px).
    cap_height,
    /// CSS/iced-compatible: size = em-square pixels (FreeType pixel_size set directly).
    pixel,
};

pub const FindOptions = struct {
    family: []const u8,

    /// Font size in logical pixels. See `SizeMode` for interpretation.
    size: f32 = DefaultSize,
    weight: Weight = .normal,
    style: Style = .normal,
    line_height_factor: f32 = 1.2,
    size_mode: SizeMode = .cap_height,
};

pub fn find(opts: FindOptions) Font {
    return (Font{}).withFamily(opts.family).withSize(opts.size).withWeight(opts.weight).withStyle(opts.style).withLineHeight(opts.line_height_factor).withSizeMode(opts.size_mode);
}

pub const ThemeFontName = enum {
    body,
    heading,
    title,
    mono,
};

pub fn theme(which: ThemeFontName) Font {
    switch (which) {
        .body => return dvui.themeGet().font_body,
        .heading => return dvui.themeGet().font_heading,
        .title => return dvui.themeGet().font_title,
        .mono => return dvui.themeGet().font_mono,
    }
}

pub fn withFamily(self: Font, n: []const u8) Font {
    var r: Font = self;
    r.family = array(n);
    return r;
}

pub fn withSize(self: Font, s: f32) Font {
    var r = self;
    r.size = s;
    return r;
}

pub fn larger(self: Font, ds: f32) Font {
    var r = self;
    r.size += ds;
    return r;
}

pub fn withWeight(self: Font, w: Weight) Font {
    var r = self;
    r.weight = w;
    return r;
}

pub fn withStyle(self: Font, s: Style) Font {
    var r = self;
    r.style = s;
    return r;
}

pub fn withLineHeight(self: Font, factor: f32) Font {
    var r = self;
    r.line_height_factor = factor;
    return r;
}

pub fn withSizeMode(self: Font, mode: SizeMode) Font {
    var r = self;
    r.size_mode = mode;
    return r;
}

pub fn withUnderline(self: Font, underline: ?Underline) Font {
    var r = self;
    r.underline = underline;
    return r;
}

pub fn withStrike(self: Font, strike: ?Strike) Font {
    var r = self;
    r.strike = strike;
    return r;
}

pub fn familyName(self: *const Font) []const u8 {
    return string(&self.family);
}

pub fn name(self: *const Font, allocator: std.mem.Allocator) []const u8 {
    const weight = switch (self.weight) {
        .normal => "",
        .light => " Light",
        .medium => " Medium",
        .semi_bold => " SemiBold",
        .bold => " Bold",
    };
    const style = switch (self.style) {
        .normal => "",
        .italic => " Italic",
    };
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ self.familyName(), weight, style }) catch "";
}

pub fn format(self: *const Font, writer: *std.Io.Writer) !void {
    const weight = switch (self.weight) {
        .normal => "",
        .light => " Light",
        .medium => " Medium",
        .semi_bold => " SemiBold",
        .bold => " Bold",
    };
    const style = switch (self.style) {
        .normal => "",
        .italic => " Italic",
    };
    try writer.print("{s}{s}{s} {d}", .{ self.familyName(), weight, style, self.size });
}

/// Fonts that hash the same value use the same glyphs (same Font.Entry).
pub fn hash(self: *const Font) u64 {
    var h = dvui.fnv.init();
    h.update(&self.family);
    h.update(std.mem.asBytes(&self.size));
    h.update(std.mem.asBytes(&self.weight));
    h.update(std.mem.asBytes(&self.style));
    h.update(std.mem.asBytes(&self.size_mode));
    return h.final();
}

/// Only valid between Window.begin/end
pub fn findSource(self: *const Font) ?Source {
    const cw = dvui.currentWindow();
    return cw.fonts.findSource(self.*).@"0";
}

pub const Source = struct {
    family: [NAME_MAX_LEN:0]u8 = @splat(0),
    size: f32 = 0, // zero means this source can be any size
    weight: Weight = .normal,
    style: Style = .normal,

    // currently we assume that a single ttf only produces one
    bytes: []const u8, // points to ttf bytes
    /// If not null, this will be used to free ttf_bytes.
    allocator: ?std.mem.Allocator = null,

    pub fn familyName(self: *const Source) []const u8 {
        return string(&self.family);
    }

    pub fn name(self: *const Source, allocator: std.mem.Allocator) []const u8 {
        const weight = switch (self.weight) {
            .normal => "",
            .light => " Light",
            .medium => " Medium",
            .semi_bold => " SemiBold",
            .bold => " Bold",
        };
        const style = switch (self.style) {
            .normal => "",
            .italic => " Italic",
        };
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ self.familyName(), weight, style }) catch "";
    }

    /// Return a Font that will render from this source.
    pub fn font(self: *const Source) Font {
        return .{
            .family = self.family,
            .weight = self.weight,
            .style = self.style,
        };
    }

    pub fn deinit(self: *Source) void {
        defer self.* = undefined;
        if (self.allocator) |alloc| {
            alloc.free(self.bytes);
        }
    }

    pub const fallback = Source{
        .family = array("Vera"),
        .bytes = @embedFile("fonts/bitstream-vera/Vera.ttf"),
    };
};

pub fn textHeight(self: Font) f32 {
    return self.sizeM(1, 1).h;
}

pub fn lineHeight(self: Font) f32 {
    return self.textHeight() * self.line_height_factor;
}

pub fn sizeM(self: Font, wide: f32, tall: f32) Size {
    const msize: Size = self.textSize("M");
    return .{ .w = msize.w * wide, .h = msize.h * tall };
}

/// handles multiple lines
///
/// Only valid between `Window.begin`and `Window.end`.
pub fn textSize(self: Font, text: []const u8) Size {
    if (text.len == 0) {
        // just want the normal text height
        return .{ .w = 0, .h = self.textHeight() };
    }

    var ret = Size{};

    var line_height_adj: f32 = 0.0;
    var end: usize = 0;
    while (end < text.len) {
        if (end > 0) {
            ret.h += line_height_adj;
        }

        var end_idx: usize = undefined;
        var s = self.textSizeEx(text[end..], .{ .end_idx = &end_idx, .end_metric = .before });
        if (self.line_height_factor >= 1.0) {
            line_height_adj = s.h * (self.line_height_factor - 1.0);
        } else {
            s.h *= self.line_height_factor;
        }
        ret.h += s.h;
        ret.w = @max(ret.w, s.w);

        end += end_idx;
    }

    return ret;
}

pub const EndMetric = enum {
    before, // end_idx stops before text goes past max_width
    nearest, // end_idx stops at start of character closest to max_width
};

pub const TextSizeOptions = struct {
    max_width: ?f32 = null,
    end_idx: ?*usize = null,
    end_metric: EndMetric = .before,
    kerning: ?bool = null,
    kern_in: ?[]u32 = null,
    kern_out: ?[]u32 = null,
    ascent_out: ?*f32 = null,
};

/// textSizeEx always stops at a newline, use textSize to get multiline sizes
///
/// Only valid between `Window.begin`and `Window.end`.
pub fn textSizeEx(self: Font, text: []const u8, opts: TextSizeOptions) Size {
    // ask for a font that matches the natural display pixels so we get a more
    // accurate size
    const ss = dvui.parentGet().screenRectScale(Rect{}).s;
    const ask_size = self.size * ss;

    // set some reasonable defaults in case things go bad
    if (opts.ascent_out) |ao| ao.* = 10;
    if (opts.end_idx) |endout| endout.* = text.len;
    if (ask_size == 0.0) {
        // early out here so we don't try to divide by zero later
        if (opts.ascent_out) |ao| ao.* = 0;
        return Size{};
    }

    const sized_font = self.withSize(ask_size);

    const cw = dvui.currentWindow();

    // might give us a slightly smaller font
    const fce = dvui.fontCacheGet(sized_font) catch return .{ .w = 10, .h = 10 };

    // this must be synced with dvui.renderText()
    const target_fraction = if (cw.snap_to_pixels) 1.0 / ss else self.size / fce.em_height;

    var options = opts;
    if (opts.max_width) |mwidth| {
        // convert max_width into font units
        options.max_width = mwidth / target_fraction;
    }
    options.kerning = opts.kerning orelse cw.kerning;

    var s = fce.textSizeRaw(cw.gpa, text, options) catch return .{ .w = 10, .h = 10 };

    if (opts.ascent_out) |ao| {
        ao.* = fce.ascent;
        if (self.line_height_factor < 1.0) {
            ao.* = @round(ao.* * self.line_height_factor);
        }
        ao.* *= target_fraction;
    }

    // convert size back from font units
    return s.scale(target_fraction, Size);
}

pub const Cache = struct {
    database: std.ArrayList(Source) = .empty,
    cache: dvui.TrackingAutoHashMap(u64, Entry, .get_and_put, void) = .empty,

    pub fn deinit(self: *Cache, gpa: std.mem.Allocator, backend: Backend) void {
        defer self.* = undefined;
        var it = self.cache.iterator();
        while (it.next()) |item| {
            item.value_ptr.deinit(gpa, backend);
        }
        self.cache.deinit(gpa);

        for (self.database.items) |*source| {
            if (source.allocator) |a| {
                a.free(source.bytes);
            }
        }
        self.database.deinit(gpa);
    }

    pub fn reset(self: *Cache, gpa: std.mem.Allocator, backend: Backend) void {
        var it = self.cache.iterator();
        while (it.next_resetting()) |kv| {
            var fce = kv.value;
            fce.deinit(gpa, backend);
        }
    }

    pub fn findSource(self: *Cache, font: Font) struct { ?Source, ?Source } {
        var second_best: ?usize = null;
        for (self.database.items, 0..) |*source, i| {
            if (std.mem.eql(u8, font.familyName(), source.familyName())) {
                if (font.weight == source.weight and font.style == source.style) {
                    return .{ source.*, null }; // exact match
                }

                if (font.weight == source.weight) {
                    // second best is same family name and same weight
                    second_best = i;
                } else if (second_best == null) {
                    // at least the family name is the same
                    second_best = i;
                }
            }
        }

        if (second_best) |sb| {
            return .{ null, self.database.items[sb] };
        }

        return .{ null, null };
    }

    pub fn getOrCreate(self: *Cache, gpa: std.mem.Allocator, font: Font) std.mem.Allocator.Error!*Entry {
        const entry = try self.cache.getOrPut(gpa, font.hash());
        if (entry.found_existing) return entry.value_ptr;

        const fname = font.name(gpa);
        defer gpa.free(fname);

        const exact, const second = self.findSource(font);

        const source = exact orelse blk: {
            if (second) |s| {
                const sname = s.name(gpa);
                defer gpa.free(sname);
                dvui.log.warn("Font {s} not loaded in dvui, using second best {s}", .{ fname, sname });
                break :blk s;
            } else {
                dvui.log.warn("Font {s} not loaded in dvui, using fallback", .{fname});
                break :blk Source.fallback;
            }
        };

        //log.debug("FontCacheGet creating font hash {x} ptr {*} size {d} name \"{s}\"", .{ fontHash, bytes.ptr, font.size, font.name });

        entry.value_ptr.* = Entry.init(gpa, source.bytes, font) catch |err| {
            dvui.log.err("Font {s} init got {any}, using fallback", .{ fname, err });
            // Remove the invalid font cache entry, something went wrong reading the ttf_bytes
            self.cache.map.removeByPtr(entry.key_ptr);
            // Substitute the known good fallback font
            return self.getOrCreate(gpa, Source.fallback.font());
        };
        //log.debug("- size {d} ascent {d} height {d}", .{ font.size, entry.ascent, entry.height });
        return entry.value_ptr;
    }

    pub const Entry = struct {
        face: if (impl == .FreeType) c.FT_Face else c.stbtt_fontinfo,
        name: []const u8, // gpa
        scaleFactor: f32,
        height: f32, // ascender - descender
        ascent: f32, // ascender (integer)
        em_height: f32, // height of M
        glyph_info: std.AutoHashMapUnmanaged(u32, GlyphInfo) = .empty,
        glyph_info_ascii: [ascii_size - ascii_start]GlyphInfo,
        texture_atlas_cache: ?Texture = null,
        /// The pair kerning in the face's `GPOS` table (FreeType only; a face
        /// with one kerns from it, never from its legacy `kern` table, as a
        /// browser does). Borrows `gpos_table`.
        gpos: if (impl == .FreeType) ?gpos_kern.Kern else void = if (impl == .FreeType) null else {},
        /// The face's `GPOS` table, copied out of FreeType (gpa).
        gpos_table: []u8 = &.{},
        /// Font units to pixels at this entry's size (FreeType's x_scale).
        unit_scale: f32 = 0,

        const ascii_size = 127;
        const ascii_start = 32;

        /// Each glyph is rasterised at this many horizontal offsets (0, 1/4,
        /// 1/2 and 3/4 of a pixel), so a pen that lands between pixels draws
        /// the glyph where it is instead of rounding it to the nearest pixel:
        /// the advances stay the outline's, and the spacing stays even.
        pub const subpixel_phases = 4;

        const GlyphInfo = struct {
            advance: f32, // horizontal distance to move the pen (exact, not rounded)
            leftBearing: f32, // horizontal distance from pen to glyph pixels left edge (integer)
            topBearing: f32, // vertical distance from pen to glyph pixels top edge (integer)
            w: f32, // width of the ink's bounding box with the pen on a pixel edge (integer)
            h: f32, // height of bounding box (integer)
            /// Width of the glyph's atlas cell (integer): `w` plus the column
            /// the ink can move into at a 3/4 pixel offset.
            cell_w: f32,
            /// The glyph's index in the face (FreeType), for GPOS kerning.
            index: u32 = 0,
            /// Atlas coordinates of the cell for each subpixel phase.
            uvs: [subpixel_phases]@Vector(2, f32),
        };

        /// The FreeType load flags every glyph is measured and drawn with:
        /// FT_LOAD_TARGET_LIGHT, the hinting FreeType recommends for gray
        /// antialiasing with fractional advances. It fits a glyph to the
        /// pixel grid vertically only (crisp baselines and x-heights) and
        /// leaves its horizontal shape the outline's, as browsers draw text;
        /// full hinting moved and widened stems to whole pixels, which read
        /// as uneven spacing once advances stopped being rounded.
        const load_flags: i32 = 1 << 16;
        /// FT_LOAD_RENDER
        const load_render: i32 = 1 << 2;

        /// Where a glyph is drawn from: the whole pixel its cell starts on,
        /// and which subpixel phase of the glyph's atlas cells to use.
        pub const PenCell = struct { whole: f32, phase: usize };

        /// Where pen position `x` (physical pixels) draws a glyph.
        pub fn penCell(x: f32) PenCell {
            const whole = @floor(x);
            const phases: f32 = @floatFromInt(subpixel_phases);
            const step = @round((x - whole) * phases);
            if (step >= phases) return .{ .whole = whole + 1, .phase = 0 };
            return .{ .whole = whole, .phase = @intFromFloat(@max(0, step)) };
        }

        /// Load the underlying font at an integer size <= font.size (guaranteed to have a minimum pixel size of 1)
        pub fn init(gpa: std.mem.Allocator, ttf_bytes: []const u8, font: Font) Error!Entry {
            const min_pixel_size = 1;

            const fname = font.name(gpa);
            errdefer gpa.free(fname);

            var self: Entry = if (impl == .FreeType) blk: {
                var face: c.FT_Face = undefined;
                var args: c.FT_Open_Args = undefined;
                args.flags = @as(u32, @bitCast(FreeType.OpenFlags{ .memory = true }));
                args.memory_base = ttf_bytes.ptr;
                args.memory_size = @as(u31, @intCast(ttf_bytes.len));
                FreeType.intToError(c.FT_Open_Face(dvui.ft2lib, &args, 0, &face)) catch |err| {
                    dvui.log.warn("Font.Cache.Entry.init() freetype error {any} trying to FT_Open_Face font {s}\n", .{ err, fname });
                    return Error.FontError;
                };

                if (font.size_mode == .pixel) {
                    // CSS/iced-compatible mode: the size is the em in pixels,
                    // fractions kept (26.6 at 72 dpi, where a point is a
                    // pixel): 13 logical pixels at 175 % is a 22.75 px em, as
                    // a browser draws it, never 23.
                    const char_size: c.FT_F26Dot6 = @intFromFloat(@round(@max(min_pixel_size, font.size) * 64));
                    FreeType.intToError(c.FT_Set_Char_Size(face, 0, char_size, 72, 72)) catch |err| {
                        dvui.log.warn("Font.Cache.Entry.init() freetype error {any} trying to FT_Set_Char_Size font {s}\n", .{ err, fname });
                        return Error.FontError;
                    };

                    const ascender = @as(f32, @floatFromInt(face.*.ascender)) / 64.0;
                    const ss = @as(f32, @floatFromInt(face.*.size.*.metrics.y_scale)) / 0x10000;
                    const ascent = ascender * ss;
                    const descender = @as(f32, @floatFromInt(face.*.descender)) / 64.0;
                    const descent = descender * ss;

                    var entry: Entry = .{
                        .face = face,
                        .name = fname,
                        .scaleFactor = 1.0,
                        .height = ascent - descent,
                        .ascent = @trunc(ascent),
                        .em_height = undefined,
                        .glyph_info_ascii = undefined,
                    };

                    const M = try entry.glyphInfoGenerate('M');
                    if (M.h <= 0) {
                        dvui.log.warn("Font.Cache.Entry.init() freetype error getting M font {s} size {d}\n", .{ fname, font.size });
                        return error.FontError;
                    }
                    entry.em_height = M.h;
                    break :blk entry;
                }

                // "pixel size" for freetype doesn't actually mean you'll get that height, it's more like using pts
                // so we search for a font that has a height <= font.size (default cap_height mode)
                var pixel_size = @as(u32, @trunc(@max(min_pixel_size, @floor(font.size))));
                pixel_size += 20;

                while (true) : (pixel_size -= 1) {
                    FreeType.intToError(c.FT_Set_Pixel_Sizes(face, pixel_size, pixel_size)) catch |err| {
                        dvui.log.warn("Font.Cache.Entry.init() freetype error {any} trying to FT_Set_Pixel_Sizes font {s}\n", .{ err, fname });
                        return Error.FontError;
                    };

                    const ascender = @as(f32, @floatFromInt(face.*.ascender)) / 64.0;
                    const ss = @as(f32, @floatFromInt(face.*.size.*.metrics.y_scale)) / 0x10000;
                    const fascent = ascender * ss;
                    const descender = @as(f32, @floatFromInt(face.*.descender)) / 64.0;
                    const descent = descender * ss;

                    var entry: Entry = .{
                        .face = face,
                        .name = fname,
                        .scaleFactor = 1.0, // not used with freetype
                        .height = fascent - descent,
                        .ascent = @trunc(fascent), // cheat ascent a bit, must be an integer
                        .em_height = undefined, // below
                        .glyph_info_ascii = undefined,
                    };

                    const M = try entry.glyphInfoGenerate('M');
                    if (M.h <= 0) {
                        dvui.log.warn("Font.Cache.Entry.init() freetype error getting M font {s} size {d}\n", .{ fname, font.size });
                        return error.FontError;
                    }

                    if (M.h <= font.size or pixel_size == min_pixel_size) {
                        //std.debug.print("{s} pixel_size {d} ascent {d} descent {d} height {d}\n", .{fname, pixel_size, ascent, descent, ascent - descent});
                        entry.em_height = M.h;
                        break :blk entry;
                    }
                }
            } else blk: {
                const offset = c.stbtt_GetFontOffsetForIndex(ttf_bytes.ptr, 0);
                if (offset < 0) {
                    dvui.log.warn("Font.Cache.Entry.init() stbtt error when calling stbtt_GetFontOffsetForIndex font {s}\n", .{fname});
                    return Error.FontError;
                }
                var face: c.stbtt_fontinfo = undefined;
                if (c.stbtt_InitFont(&face, ttf_bytes.ptr, offset) != 1) {
                    dvui.log.warn("Font.Cache.Entry.init() stbtt error when calling stbtt_InitFont font {s}\n", .{fname});
                    return Error.FontError;
                }

                var face_ascent: c_int = undefined;
                var face_descent: c_int = undefined;
                c.stbtt_GetFontVMetrics(&face, &face_ascent, &face_descent, null);

                var entry: Entry = .{
                    .face = face,
                    .name = fname,
                    .scaleFactor = 1.0, // adjusted below
                    .height = 1.0, // adjusted below
                    .ascent = 1.0, // adjusted below
                    .em_height = undefined, // below
                    .glyph_info_ascii = undefined,
                };

                const M = try entry.glyphInfoGenerate('M');
                if (M.h <= 0) {
                    dvui.log.warn("Font.Cache.Entry.init() stbtt error getting M font {s} size {d}\n", .{ fname, font.size });
                    return error.FontError;
                }

                if (font.size_mode == .pixel) {
                    // CSS mode: scale so that em-square = font.size pixels.
                    // stbtt: scaleFactor = desired_px / unscaled_height.
                    // Unscaled height = face_ascent - face_descent (in font units).
                    const unscaled_height = @as(f32, @floatFromInt(face_ascent - face_descent));
                    entry.scaleFactor = font.size / unscaled_height;
                } else {
                    entry.scaleFactor = @max(min_pixel_size, @floor(font.size)) / M.h;
                }
                const ascender = entry.scaleFactor * @as(f32, @floatFromInt(face_ascent));
                const descender = entry.scaleFactor * @as(f32, @floatFromInt(face_descent));
                entry.ascent = @trunc(ascender); // cheat the ascent a bit, must be integer
                entry.height = ascender - descender;
                entry.em_height = entry.scaleFactor * M.h;

                //std.debug.print("{s} ascent {d} descent {d} computed ascent {d} height {d}\n", .{fname, ascender, descender, entry.ascent, entry.height});
                break :blk entry;
            };

            if (impl == .FreeType) {
                self.unit_scale = @as(f32, @floatFromInt(self.face.*.size.*.metrics.x_scale)) / 65536.0 / 64.0;
                self.loadGpos(gpa) catch |err| {
                    dvui.log.warn("Font.Cache.Entry.init() {any} reading the GPOS kerning of font {s}; it draws unkerned\n", .{ err, fname });
                };
            }
            errdefer self.freeGpos(gpa);

            // Pre-generate the ascii glyphs
            //std.debug.print("char,codepoint,hx,w,hy,h,adv\n", .{});
            for (0..self.glyph_info_ascii.len) |i| {
                self.glyph_info_ascii[i] = try self.glyphInfoGenerate(@intCast(i + ascii_start));
            }

            //const gi = self.glyph_info_ascii['M' - ascii_start];
            //std.debug.print("{s} size {d} height {d} M left {d} top {d} wxh {d}x{d}\n", .{ fname, font.size, self.height, gi.leftBearing, gi.topBearing, gi.w, gi.h});

            return self;
        }

        /// Read the face's `GPOS` pair kerning, if it has any.
        fn loadGpos(self: *Entry, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
            if (impl != .FreeType) return;
            const tag: c.FT_ULong = 0x47504F53; // 'GPOS'
            var length: c.FT_ULong = 0;
            if (c.FT_Load_Sfnt_Table(self.face, tag, 0, null, &length) != 0 or length == 0) return;
            const table = try gpa.alloc(u8, length);
            if (c.FT_Load_Sfnt_Table(self.face, tag, 0, table.ptr, &length) != 0) {
                gpa.free(table);
                return;
            }
            const pairs = gpos_kern.Kern.init(gpa, table) catch |err| {
                gpa.free(table);
                return err;
            };
            if (pairs == null) {
                gpa.free(table);
                return;
            }
            self.gpos = pairs;
            self.gpos_table = table;
        }

        fn freeGpos(self: *Entry, gpa: std.mem.Allocator) void {
            if (impl != .FreeType) return;
            if (self.gpos) |*pairs| pairs.deinit(gpa);
            self.gpos = null;
            gpa.free(self.gpos_table);
            self.gpos_table = &.{};
        }

        pub fn deinit(self: *Entry, gpa: std.mem.Allocator, backend: Backend) void {
            defer self.* = undefined;
            gpa.free(self.name);
            self.glyph_info.deinit(gpa);
            self.freeGpos(gpa);
            if (impl == .FreeType) {
                _ = c.FT_Done_Face(self.face);
            }
            if (self.texture_atlas_cache) |tex| backend.textureDestroy(tex);
        }

        pub fn invalidateTextureAtlas(self: *Entry) void {
            if (self.texture_atlas_cache) |tex| {
                dvui.textureDestroyLater(tex);
            }
            self.texture_atlas_cache = null;
        }

        /// This needs to be called before rendering of glyphs as the uv coordinates
        /// of the glyphs will not be correct if the atlas needs to be generated.
        ///
        /// Every glyph is a strip of `subpixel_phases` cells side by side, the
        /// glyph rasterised at each subpixel offset; strips are packed in
        /// shelves about as wide as the atlas is tall.
        pub fn getTextureAtlas(self: *Entry, gpa: std.mem.Allocator, backend: Backend) Backend.TextureError!Texture {
            if (self.texture_atlas_cache) |tex| return tex;

            // number of extra pixels to add on each side of each cell
            const pad = 1;
            const phases: f32 = @floatFromInt(subpixel_phases);

            const total = self.glyph_info_ascii.len + self.glyph_info.count();

            var area: f32 = 0;
            var widest: f32 = 0;
            {
                var it = self.glyph_info.iterator();
                for (0..total) |i| {
                    const gi = if (i < self.glyph_info_ascii.len) &self.glyph_info_ascii[i] else it.next().?.value_ptr;
                    const strip_w = phases * (gi.cell_w + 2 * pad);
                    area += strip_w * (gi.h + 2 * pad);
                    widest = @max(widest, strip_w);
                }
            }
            const shelf_w = @max(widest, @ceil(@sqrt(area)));

            // where each strip goes (top left of its first cell's padding)
            const places = try gpa.alloc(dvui.Point, total);
            defer gpa.free(places);
            var s = Size{};
            {
                var x: f32 = 0;
                var y: f32 = 0;
                var shelf_h: f32 = 0;
                var it = self.glyph_info.iterator();
                for (0..total) |i| {
                    const gi = if (i < self.glyph_info_ascii.len) &self.glyph_info_ascii[i] else it.next().?.value_ptr;
                    const strip_w = phases * (gi.cell_w + 2 * pad);
                    if (x > 0 and x + strip_w > shelf_w) {
                        y += shelf_h;
                        x = 0;
                        shelf_h = 0;
                    }
                    // also an extra padding around the whole texture
                    places[i] = .{ .x = x + pad, .y = y + pad };
                    x += strip_w;
                    shelf_h = @max(shelf_h, gi.h + 2 * pad);
                    s.w = @max(s.w, x);
                }
                s.h = y + shelf_h;
            }
            s.w += 2 * pad;
            s.h += 2 * pad;
            s = s.ceil();

            const stride: usize = @intFromFloat(s.w);
            const pixels = try gpa.alloc(dvui.Color.PMA, stride * @as(usize, @intFromFloat(s.h)));
            defer gpa.free(pixels);
            // set all pixels to zero alpha
            @memset(pixels, .transparent);

            var it = self.glyph_info.iterator();
            for (0..total) |i| {
                const gi, const codepoint = if (i < self.glyph_info_ascii.len) .{ &self.glyph_info_ascii[i], @as(u32, @intCast(i + ascii_start)) } else blk: {
                    const e = it.next().?;
                    break :blk .{ e.value_ptr, e.key_ptr.* };
                };
                for (0..subpixel_phases) |phase| {
                    const cell: dvui.Point = .{
                        .x = places[i].x + @as(f32, @floatFromInt(phase)) * (gi.cell_w + 2 * pad) + pad,
                        .y = places[i].y + pad,
                    };
                    gi.uvs[phase] = .{ cell.x / s.w, cell.y / s.h };
                    try self.rasterizeCell(gpa, codepoint, gi.*, phase, pixels, stride, @intFromFloat(cell.x), @intFromFloat(cell.y));
                }
            }

            self.texture_atlas_cache = try backend.textureCreate(@ptrCast(pixels.ptr), .{ .width = @intCast(stride), .height = @intFromFloat(s.h) });
            return self.texture_atlas_cache.?;
        }

        /// Rasterise one glyph at subpixel `phase` into its atlas cell, whose
        /// top left pixel is (`cell_x`, `cell_y`) in `pixels` (rows of
        /// `stride`). The cell is `gi.cell_w` x `gi.h`; anything the
        /// rasteriser draws outside it is clipped. A glyph that fails is left
        /// empty, never an error.
        fn rasterizeCell(self: *Entry, gpa: std.mem.Allocator, codepoint: u32, gi: GlyphInfo, phase: usize, pixels: []dvui.Color.PMA, stride: usize, cell_x: usize, cell_y: usize) std.mem.Allocator.Error!void {
            if (gi.w <= 0 or gi.h <= 0) return;
            const cell_w: i32 = @intFromFloat(gi.cell_w);
            const cell_h: i32 = @intFromFloat(gi.h);
            // where the rasterised bitmap's top left lands in the cell
            var dx: i32 = 0;
            var dy: i32 = 0;
            var width: i32 = 0;
            var rows: i32 = 0;

            if (impl == .FreeType) {
                FreeType.intToError(c.FT_Load_Glyph(self.face, gi.index, load_flags)) catch |err| {
                    dvui.log.warn("renderText: freetype error {any} trying to FT_Load_Glyph codepoint {d}", .{ err, codepoint });
                    return;
                };
                const slot = self.face.*.glyph;
                // https://freetype.org/freetype2/docs/tutorial/step1.html#section-6
                if (slot.*.format == c.FT_GLYPH_FORMAT_OUTLINE) {
                    // 26.6: a quarter pixel is 16
                    c.FT_Outline_Translate(&slot.*.outline, @intCast(phase * 64 / subpixel_phases), 0);
                }
                if (slot.*.format != c.FT_GLYPH_FORMAT_BITMAP) {
                    FreeType.intToError(c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL)) catch |err| {
                        dvui.log.warn("renderText freetype error {any} trying to FT_Render_Glyph codepoint {d}", .{ err, codepoint });
                        return;
                    };
                }
                const bitmap = slot.*.bitmap;
                dx = slot.*.bitmap_left - @as(i32, @intFromFloat(gi.leftBearing));
                dy = @as(i32, @intFromFloat(gi.topBearing)) - slot.*.bitmap_top;
                width = @intCast(bitmap.width);
                rows = @intCast(bitmap.rows);
                const pitch: usize = @abs(bitmap.pitch);
                const mono = bitmap.pixel_mode == c.FT_PIXEL_MODE_MONO;
                if (!mono and bitmap.pixel_mode != c.FT_PIXEL_MODE_GRAY) return;
                var row: i32 = 0;
                while (row < rows) : (row += 1) {
                    const y = dy + row;
                    if (y < 0 or y >= cell_h) continue;
                    var col: i32 = 0;
                    while (col < width) : (col += 1) {
                        const x = dx + col;
                        if (x < 0 or x >= cell_w) continue;
                        const line = bitmap.buffer + @as(usize, @intCast(row)) * pitch;
                        const value: u8 = if (mono) mono: {
                            const byte = line[@as(usize, @intCast(col)) >> 3];
                            const bit: u3 = @intCast(7 - @mod(col, 8));
                            break :mono if ((byte >> bit) & 1 != 0) 255 else 0;
                        } else line[@intCast(col)];
                        const di = (cell_y + @as(usize, @intCast(y))) * stride + cell_x + @as(usize, @intCast(x));
                        // premultiplied white
                        pixels[di] = .{ .r = value, .g = value, .b = value, .a = value };
                    }
                }
            } else {
                const shift: f32 = @as(f32, @floatFromInt(phase)) / @as(f32, @floatFromInt(subpixel_phases));
                var ix0: c_int = 0;
                var iy0: c_int = 0;
                var ix1: c_int = 0;
                var iy1: c_int = 0;
                c.stbtt_GetCodepointBitmapBoxSubpixel(&self.face, @intCast(codepoint), self.scaleFactor, self.scaleFactor, shift, 0, &ix0, &iy0, &ix1, &iy1);
                width = ix1 - ix0;
                rows = iy1 - iy0;
                if (width <= 0 or rows <= 0) return;
                dx = ix0 - @as(i32, @intFromFloat(gi.leftBearing));
                dy = iy0 + @as(i32, @intFromFloat(gi.topBearing));

                // single channel
                const bitmap = try gpa.alloc(u8, @as(usize, @intCast(width * rows)));
                defer gpa.free(bitmap);
                c.stbtt_MakeCodepointBitmapSubpixel(&self.face, bitmap.ptr, width, rows, width, self.scaleFactor, self.scaleFactor, shift, 0, @intCast(codepoint));

                var row: i32 = 0;
                while (row < rows) : (row += 1) {
                    const y = dy + row;
                    if (y < 0 or y >= cell_h) continue;
                    var col: i32 = 0;
                    while (col < width) : (col += 1) {
                        const x = dx + col;
                        if (x < 0 or x >= cell_w) continue;
                        const value = bitmap[@intCast(row * width + col)];
                        const di = (cell_y + @as(usize, @intCast(y))) * stride + cell_x + @as(usize, @intCast(x));
                        // premultiplied white
                        pixels[di] = .{ .r = value, .g = value, .b = value, .a = value };
                    }
                }
            }
        }

        /// If a codepoint is missing in the font it gets the glyph for
        /// `std.unicode.replacement_character`
        pub fn glyphInfoGetOrReplacement(self: *Entry, gpa: std.mem.Allocator, codepoint: u32) std.mem.Allocator.Error!GlyphInfo {
            return self.glyphInfoGet(gpa, codepoint) catch |err| switch (err) {
                Error.FontError => self.glyphInfoGet(gpa, std.unicode.replacement_character) catch unreachable,
                else => |e| e,
            };
        }

        pub fn glyphInfoGet(self: *Entry, gpa: std.mem.Allocator, codepoint: u32) (std.mem.Allocator.Error || Error)!GlyphInfo {
            if (ascii_start <= codepoint and codepoint < ascii_size)
                return self.glyph_info_ascii[codepoint - ascii_start];

            if (self.glyph_info.get(codepoint)) |gi| return gi;

            const gi = try self.glyphInfoGenerate(codepoint);

            // new glyph, need to regen texture atlas on next render
            //std.debug.print("new glyph {}\n", .{codepoint});
            self.invalidateTextureAtlas();

            try self.glyph_info.put(gpa, codepoint, gi);
            return gi;
        }

        pub fn glyphInfoGenerate(self: *Entry, codepoint: u32) Error!GlyphInfo {
            const no_uvs: [subpixel_phases]@Vector(2, f32) = @splat(.{ 0, 0 });
            const gi: GlyphInfo = if (impl == .FreeType) blk: {
                const index = c.FT_Get_Char_Index(self.face, codepoint);
                FreeType.intToError(c.FT_Load_Glyph(self.face, index, load_flags)) catch |err| {
                    dvui.log.warn("glyphInfoGet freetype error {any} font {s} codepoint {d}\n", .{ err, self.name, codepoint });
                    return Error.FontError;
                };
                const slot = self.face.*.glyph;

                // The outline's own advance, scaled but never hinted or
                // rounded: what the pen moves by, as in a browser.
                const advance = @as(f32, @floatFromInt(slot.*.linearHoriAdvance)) / 65536.0;

                if (slot.*.format == c.FT_GLYPH_FORMAT_OUTLINE) {
                    // The box the rasteriser fills (26.6), widened by the
                    // most a subpixel phase moves the ink.
                    var box: c.FT_BBox = undefined;
                    c.FT_Outline_Get_CBox(&slot.*.outline, &box);
                    const left = @divFloor(box.xMin, 64);
                    const right = -@divFloor(-box.xMax, 64);
                    const shift_most = 64 * (subpixel_phases - 1) / subpixel_phases;
                    const right_shifted = -@divFloor(-(box.xMax + shift_most), 64);
                    const top = -@divFloor(-box.yMax, 64);
                    const bottom = @divFloor(box.yMin, 64);
                    const empty = box.xMax <= box.xMin or box.yMax <= box.yMin;
                    break :blk .{
                        .advance = advance,
                        .leftBearing = @floatFromInt(left),
                        .topBearing = @floatFromInt(top),
                        .w = if (empty) 0 else @floatFromInt(right - left),
                        .h = if (empty) 0 else @floatFromInt(top - bottom),
                        .cell_w = if (empty) 0 else @floatFromInt(right_shifted - left),
                        .index = index,
                        .uvs = no_uvs,
                    };
                }

                // An embedded bitmap: drawn as it is at every phase.
                const m = slot.*.metrics;
                const minx = @as(f32, @floatFromInt(m.horiBearingX)) / 64.0;
                const miny = @as(f32, @floatFromInt(m.horiBearingY)) / 64.0;
                const w = @ceil(minx + @as(f32, @floatFromInt(m.width)) / 64.0) - @floor(minx);
                break :blk .{
                    .advance = advance,
                    .leftBearing = @floor(minx),
                    .topBearing = @floor(miny),
                    .w = w,
                    .h = @ceil(miny + @as(f32, @floatFromInt(m.height)) / 64.0) - @floor(miny),
                    .cell_w = w,
                    .index = index,
                    .uvs = no_uvs,
                };
            } else blk: {
                var advanceWidth: c_int = undefined;
                c.stbtt_GetCodepointHMetrics(&self.face, @as(c_int, @intCast(codepoint)), &advanceWidth, null);
                var ix0: c_int = undefined;
                var iy0: c_int = undefined;
                var ix1: c_int = undefined;
                var iy1: c_int = undefined;
                const ret = c.stbtt_GetCodepointBox(&self.face, @as(c_int, @intCast(codepoint)), &ix0, &iy0, &ix1, &iy1);
                const x0: f32 = if (ret == 0) 0 else self.scaleFactor * @as(f32, @floatFromInt(ix0));
                const y0: f32 = if (ret == 0) 0 else self.scaleFactor * @as(f32, @floatFromInt(iy0));
                const x1: f32 = if (ret == 0) 0 else self.scaleFactor * @as(f32, @floatFromInt(ix1));
                const y1: f32 = if (ret == 0) 0 else self.scaleFactor * @as(f32, @floatFromInt(iy1));
                const adv: f32 = self.scaleFactor * @as(f32, @floatFromInt(advanceWidth));

                // bitmap assumes pen position is at a pixel boundary, so we
                // extend the box in each direction to a full pixel (so floor
                // x0/y0, and ceil x1/y1); the cell also holds the ink moved
                // by the largest subpixel phase.
                const shift_most = @as(f32, @floatFromInt(subpixel_phases - 1)) / @as(f32, @floatFromInt(subpixel_phases));
                const w = @ceil(x1) - @floor(x0);
                break :blk .{
                    .advance = adv,
                    .leftBearing = @floor(x0),
                    .topBearing = @ceil(y1),
                    .w = w,
                    .h = @ceil(y1) - @floor(y0),
                    .cell_w = if (w <= 0) 0 else @ceil(x1 + shift_most) - @floor(x0),
                    .uvs = no_uvs,
                };
            };
            //std.debug.print("codepoint {d} advance {d} leftBearing {d} topBearing {d} w {d} h {d}\n", .{ codepoint, gi.advance, gi.leftBearing, gi.topBearing, gi.w, gi.h });
            return gi;
        }

        /// The glyph index of `codepoint` in the face (FreeType), from the
        /// glyph cache when it is there.
        fn glyphIndex(self: *Entry, codepoint: u32) u32 {
            if (impl != .FreeType) return 0;
            if (ascii_start <= codepoint and codepoint < ascii_size) return self.glyph_info_ascii[codepoint - ascii_start].index;
            if (self.glyph_info.get(codepoint)) |gi| return gi.index;
            return c.FT_Get_Char_Index(self.face, codepoint);
        }

        /// The pen adjustment between two glyphs, in pixels at this size (not
        /// rounded). FreeType: from the face's `GPOS` pair kerning when it has
        /// one, else from its legacy `kern` table.
        pub fn kern(fce: *Entry, codepoint1: u32, codepoint2: u32) f32 {
            if (impl == .FreeType) {
                if (fce.gpos) |*gpos| {
                    const units = gpos.pair(fce.glyphIndex(codepoint1), fce.glyphIndex(codepoint2));
                    return @as(f32, @floatFromInt(units)) * fce.unit_scale;
                }
                // A face without a legacy `kern` table has nothing for
                // `FT_Get_Kerning` to read: it answers zero for every pair.
                // Asking anyway cost two cmap lookups and the call itself for
                // EVERY glyph of every line measured or drawn — a sixteenth of
                // an idle editor frame, on fonts that can never answer
                // anything but zero.
                if (!hasKerning(fce.face)) return 0;
                var k: c.FT_Vector = undefined;
                FreeType.intToError(c.FT_Get_Kerning(fce.face, fce.glyphIndex(codepoint1), fce.glyphIndex(codepoint2), c.FT_KERNING_UNFITTED, &k)) catch |err| {
                    dvui.log.warn("renderText freetype error {any} trying to FT_Get_Kerning font {s} codepoints {d} {d}\n", .{ err, fce.name, codepoint1, codepoint2 });
                    k.x = 0;
                    k.y = 0;
                };

                return @as(f32, @floatFromInt(k.x)) / 64.0;
            } else {
                const kern_adv: c_int = c.stbtt_GetCodepointKernAdvance(&fce.face, @as(c_int, @intCast(codepoint1)), @as(c_int, @intCast(codepoint2)));
                return fce.scaleFactor * @as(f32, @floatFromInt(kern_adv));
            }
        }

        /// Doesn't scale the font or max_width, always stops at newlines
        ///
        /// Assumes the text is valid utf8. Will exit early with non-full
        /// size on invalid utf8
        pub fn textSizeRaw(
            self: *Entry,
            gpa: std.mem.Allocator,
            text: []const u8,
            opts: Font.TextSizeOptions,
        ) std.mem.Allocator.Error!Size {
            const mwidth = opts.max_width orelse dvui.max_float_safe;

            var x: f32 = 0;
            var minx: f32 = 0;
            var maxx: f32 = 0;
            var miny: f32 = 0;
            var maxy: f32 = self.height;
            var tw: f32 = 0;
            var th: f32 = self.height;

            var ei: usize = 0;
            var nearest_break: bool = false;

            const kerning: bool = opts.kerning orelse true;
            var last_codepoint: u32 = 0;
            var next_kern_idx: u32 = 0;
            var next_kern_byte: u32 = 0;
            if (opts.kern_in) |ki| {
                next_kern_byte = ki[next_kern_idx];
                next_kern_idx += 1;
            }

            var i: usize = 0;
            while (i < text.len) {
                const cplen = std.unicode.utf8ByteSequenceLength(text[i]) catch unreachable;
                const codepoint = std.unicode.utf8Decode(text[i..][0..cplen]) catch unreachable;

                if (codepoint == '\n') {
                    // newlines always terminate, and don't use any space
                    ei += 1;
                    break;
                }

                const gi = try self.glyphInfoGetOrReplacement(gpa, codepoint);

                if (kerning and last_codepoint != 0 and i >= next_kern_byte) {
                    // never rounded: renderText draws each glyph at its
                    // pen's subpixel phase, so the run is as wide as the
                    // outline's advances and kerning say
                    const kk = self.kern(last_codepoint, codepoint);
                    x += kk;

                    if (opts.kern_in) |ki| {
                        if (next_kern_idx < ki.len) {
                            next_kern_byte = ki[next_kern_idx];
                            next_kern_idx += 1;
                        }
                    }

                    if (kk != 0) {
                        if (opts.kern_out) |ko| {
                            // fill in first 0
                            for (ko) |*k| {
                                if (k.* == 0) {
                                    k.* = @intCast(i);
                                    break;
                                }
                            }
                        }
                    }
                }

                i += cplen;
                last_codepoint = codepoint;

                const adv = gi.advance;

                minx = @min(minx, x + gi.leftBearing);
                maxx = @max(maxx, x + gi.leftBearing + gi.w);
                maxx = @max(maxx, x + adv);

                miny = @min(miny, self.ascent - gi.topBearing);
                maxy = @max(maxy, self.ascent - gi.topBearing + gi.h);

                if ((maxx - minx) > mwidth) {
                    switch (opts.end_metric) {
                        .before => break, // went too far
                        .nearest => {
                            if ((maxx - minx) - mwidth >= mwidth - tw) {
                                break; // current one is closest
                            } else {
                                // get the next glyph and then break
                                nearest_break = true;
                            }
                        },
                    }
                }

                // record that we processed this codepoint
                ei += cplen;

                // update space taken by glyph
                tw = maxx - minx;
                th = maxy - miny;
                x += adv;

                if (nearest_break) break;
            }

            // TODO: xstart and ystart

            if (opts.end_idx) |endout| {
                endout.* = ei;
            }

            if (opts.kern_out) |ko| {
                // fill in first 0
                for (ko) |*k| {
                    if (k.* == 0) {
                        k.* = @intCast(i);
                        break;
                    }
                }
            }

            //std.debug.print("textSizeRaw size {d} for \"{s}\" {d}x{d} {d}\n", .{ self.size, text, tw, th, ei });
            return Size{ .w = tw, .h = th };
        }
    };
};

pub const FreeType = struct {
    pub const OpenFlags = packed struct(c_int) {
        memory: bool = false,
        stream: bool = false,
        path: bool = false,
        driver: bool = false,
        params: bool = false,
        _padding: u27 = 0,
    };

    pub const LoadFlags = packed struct(c_int) {
        no_scale: bool = false,
        no_hinting: bool = false,
        render: bool = false,
        no_bitmap: bool = false,
        vertical_layout: bool = false,
        force_autohint: bool = false,
        crop_bitmap: bool = false,
        pedantic: bool = false,
        ignore_global_advance_with: bool = false,
        no_recurse: bool = false,
        ignore_transform: bool = false,
        monochrome: bool = false,
        linear_design: bool = false,
        no_autohint: bool = false,
        _padding: u1 = 0,
        target_normal: bool = false,
        target_light: bool = false,
        target_mono: bool = false,
        target_lcd: bool = false,
        target_lcd_v: bool = false,
        color: bool = false,
        compute_metrics: bool = false,
        bitmap_metrics_only: bool = false,
        _padding0: u9 = 0,
    };

    pub fn intToError(err: c_int) !void {
        return switch (err) {
            c.FT_Err_Ok => {},
            c.FT_Err_Cannot_Open_Resource => error.CannotOpenResource,
            c.FT_Err_Unknown_File_Format => error.UnknownFileFormat,
            c.FT_Err_Invalid_File_Format => error.InvalidFileFormat,
            c.FT_Err_Invalid_Version => error.InvalidVersion,
            c.FT_Err_Lower_Module_Version => error.LowerModuleVersion,
            c.FT_Err_Invalid_Argument => error.InvalidArgument,
            c.FT_Err_Unimplemented_Feature => error.UnimplementedFeature,
            c.FT_Err_Invalid_Table => error.InvalidTable,
            c.FT_Err_Invalid_Offset => error.InvalidOffset,
            c.FT_Err_Array_Too_Large => error.ArrayTooLarge,
            c.FT_Err_Missing_Module => error.MissingModule,
            c.FT_Err_Missing_Property => error.MissingProperty,
            c.FT_Err_Invalid_Glyph_Index => error.InvalidGlyphIndex,
            c.FT_Err_Invalid_Character_Code => error.InvalidCharacterCode,
            c.FT_Err_Invalid_Glyph_Format => error.InvalidGlyphFormat,
            c.FT_Err_Cannot_Render_Glyph => error.CannotRenderGlyph,
            c.FT_Err_Invalid_Outline => error.InvalidOutline,
            c.FT_Err_Invalid_Composite => error.InvalidComposite,
            c.FT_Err_Too_Many_Hints => error.TooManyHints,
            c.FT_Err_Invalid_Pixel_Size => error.InvalidPixelSize,
            c.FT_Err_Invalid_Handle => error.InvalidHandle,
            c.FT_Err_Invalid_Library_Handle => error.InvalidLibraryHandle,
            c.FT_Err_Invalid_Driver_Handle => error.InvalidDriverHandle,
            c.FT_Err_Invalid_Face_Handle => error.InvalidFaceHandle,
            c.FT_Err_Invalid_Size_Handle => error.InvalidSizeHandle,
            c.FT_Err_Invalid_Slot_Handle => error.InvalidSlotHandle,
            c.FT_Err_Invalid_CharMap_Handle => error.InvalidCharMapHandle,
            c.FT_Err_Invalid_Cache_Handle => error.InvalidCacheHandle,
            c.FT_Err_Invalid_Stream_Handle => error.InvalidStreamHandle,
            c.FT_Err_Too_Many_Drivers => error.TooManyDrivers,
            c.FT_Err_Too_Many_Extensions => error.TooManyExtensions,
            c.FT_Err_Out_Of_Memory => error.OutOfMemory,
            c.FT_Err_Unlisted_Object => error.UnlistedObject,
            c.FT_Err_Cannot_Open_Stream => error.CannotOpenStream,
            c.FT_Err_Invalid_Stream_Seek => error.InvalidStreamSeek,
            c.FT_Err_Invalid_Stream_Skip => error.InvalidStreamSkip,
            c.FT_Err_Invalid_Stream_Read => error.InvalidStreamRead,
            c.FT_Err_Invalid_Stream_Operation => error.InvalidStreamOperation,
            c.FT_Err_Invalid_Frame_Operation => error.InvalidFrameOperation,
            c.FT_Err_Nested_Frame_Access => error.NestedFrameAccess,
            c.FT_Err_Invalid_Frame_Read => error.InvalidFrameRead,
            c.FT_Err_Raster_Uninitialized => error.RasterUninitialized,
            c.FT_Err_Raster_Corrupted => error.RasterCorrupted,
            c.FT_Err_Raster_Overflow => error.RasterOverflow,
            c.FT_Err_Raster_Negative_Height => error.RasterNegativeHeight,
            c.FT_Err_Too_Many_Caches => error.TooManyCaches,
            c.FT_Err_Invalid_Opcode => error.InvalidOpcode,
            c.FT_Err_Too_Few_Arguments => error.TooFewArguments,
            c.FT_Err_Stack_Overflow => error.StackOverflow,
            c.FT_Err_Code_Overflow => error.CodeOverflow,
            c.FT_Err_Bad_Argument => error.BadArgument,
            c.FT_Err_Divide_By_Zero => error.DivideByZero,
            c.FT_Err_Invalid_Reference => error.InvalidReference,
            c.FT_Err_Debug_OpCode => error.DebugOpCode,
            c.FT_Err_ENDF_In_Exec_Stream => error.ENDFInExecStream,
            c.FT_Err_Nested_DEFS => error.NestedDEFS,
            c.FT_Err_Invalid_CodeRange => error.InvalidCodeRange,
            c.FT_Err_Execution_Too_Long => error.ExecutionTooLong,
            c.FT_Err_Too_Many_Function_Defs => error.TooManyFunctionDefs,
            c.FT_Err_Too_Many_Instruction_Defs => error.TooManyInstructionDefs,
            c.FT_Err_Table_Missing => error.TableMissing,
            c.FT_Err_Horiz_Header_Missing => error.HorizHeaderMissing,
            c.FT_Err_Locations_Missing => error.LocationsMissing,
            c.FT_Err_Name_Table_Missing => error.NameTableMissing,
            c.FT_Err_CMap_Table_Missing => error.CMapTableMissing,
            c.FT_Err_Hmtx_Table_Missing => error.HmtxTableMissing,
            c.FT_Err_Post_Table_Missing => error.PostTableMissing,
            c.FT_Err_Invalid_Horiz_Metrics => error.InvalidHorizMetrics,
            c.FT_Err_Invalid_CharMap_Format => error.InvalidCharMapFormat,
            c.FT_Err_Invalid_PPem => error.InvalidPPem,
            c.FT_Err_Invalid_Vert_Metrics => error.InvalidVertMetrics,
            c.FT_Err_Could_Not_Find_Context => error.CouldNotFindContext,
            c.FT_Err_Invalid_Post_Table_Format => error.InvalidPostTableFormat,
            c.FT_Err_Invalid_Post_Table => error.InvalidPostTable,
            c.FT_Err_Syntax_Error => error.Syntax,
            c.FT_Err_Stack_Underflow => error.StackUnderflow,
            c.FT_Err_Ignore => error.Ignore,
            c.FT_Err_No_Unicode_Glyph_Name => error.NoUnicodeGlyphName,
            c.FT_Err_Missing_Startfont_Field => error.MissingStartfontField,
            c.FT_Err_Missing_Font_Field => error.MissingFontField,
            c.FT_Err_Missing_Size_Field => error.MissingSizeField,
            c.FT_Err_Missing_Fontboundingbox_Field => error.MissingFontboundingboxField,
            c.FT_Err_Missing_Chars_Field => error.MissingCharsField,
            c.FT_Err_Missing_Startchar_Field => error.MissingStartcharField,
            c.FT_Err_Missing_Encoding_Field => error.MissingEncodingField,
            c.FT_Err_Missing_Bbx_Field => error.MissingBbxField,
            c.FT_Err_Bbx_Too_Big => error.BbxTooBig,
            c.FT_Err_Corrupted_Font_Header => error.CorruptedFontHeader,
            c.FT_Err_Corrupted_Font_Glyphs => error.CorruptedFontGlyphs,
            else => unreachable,
        };
    }
};

/// Whether FreeType holds kerning data for `face` (`FT_HAS_KERNING`): the one
/// thing `FT_Get_Kerning` can read. A face without it answers zero for every
/// pair, so `Entry.kern` does not ask.
fn hasKerning(face: anytype) bool {
    return (face.*.face_flags & c.FT_FACE_FLAG_KERNING) != 0;
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "a face with no kern table is never asked for a pair, and one with it still kerns" {
    if (impl != .FreeType) return error.SkipZigTest;
    var library: c.FT_Library = undefined;
    try FreeType.intToError(c.FT_Init_FreeType(&library));
    defer _ = c.FT_Done_FreeType(library);

    // Bitstream Vera carries a legacy `kern` table: "AV" pulls together.
    const vera = @embedFile("fonts/bitstream-vera/Vera.ttf");
    var kerned: c.FT_Face = undefined;
    try FreeType.intToError(c.FT_New_Memory_Face(library, vera.ptr, vera.len, 0, &kerned));
    defer _ = c.FT_Done_Face(kerned);
    try FreeType.intToError(c.FT_Set_Pixel_Sizes(kerned, 0, 32));
    try std.testing.expect(hasKerning(kerned));
    var pair: c.FT_Vector = undefined;
    try FreeType.intToError(c.FT_Get_Kerning(kerned, c.FT_Get_Char_Index(kerned, 'A'), c.FT_Get_Char_Index(kerned, 'V'), c.FT_KERNING_DEFAULT, &pair));
    try std.testing.expect(pair.x < 0);

    // Hack has none (like Geist, whose kerning is GPOS only, which
    // `FT_Get_Kerning` never reads): every pair is zero, so the check skips
    // two cmap lookups and the call for each glyph drawn.
    const hack = @embedFile("fonts/hack/Hack-Regular.ttf");
    var plain: c.FT_Face = undefined;
    try FreeType.intToError(c.FT_New_Memory_Face(library, hack.ptr, hack.len, 0, &plain));
    defer _ = c.FT_Done_Face(plain);
    try FreeType.intToError(c.FT_Set_Pixel_Sizes(plain, 0, 32));
    try std.testing.expect(!hasKerning(plain));
    try FreeType.intToError(c.FT_Get_Kerning(plain, c.FT_Get_Char_Index(plain, 'A'), c.FT_Get_Char_Index(plain, 'V'), c.FT_KERNING_DEFAULT, &pair));
    try std.testing.expectEqual(@as(c.FT_Pos, 0), pair.x);
}

const test_vera = @embedFile("fonts/bitstream-vera/Vera.ttf");
const test_aleo = @embedFile("fonts/Aleo/static/Aleo-Regular.ttf");

/// A test's view of one font file through FreeType directly: what the font
/// itself says, to hold dvui's measuring and drawing to.
const TestFace = struct {
    library: c.FT_Library,
    face: c.FT_Face,

    fn open(bytes: []const u8) !TestFace {
        var library: c.FT_Library = undefined;
        try FreeType.intToError(c.FT_Init_FreeType(&library));
        errdefer _ = c.FT_Done_FreeType(library);
        var face: c.FT_Face = undefined;
        try FreeType.intToError(c.FT_New_Memory_Face(library, bytes.ptr, @intCast(bytes.len), 0, &face));
        return .{ .library = library, .face = face };
    }

    fn close(self: *TestFace) void {
        _ = c.FT_Done_Face(self.face);
        _ = c.FT_Done_FreeType(self.library);
    }

    /// The glyph's advance in physical pixels at `pixels` per em, exactly as
    /// the outline says (no hinting, no rounding).
    fn advance(self: *TestFace, codepoint: u32, pixels: f32) !f32 {
        var units: c.FT_Fixed = 0;
        // 1 is FT_LOAD_NO_SCALE: the advance in font units
        try FreeType.intToError(c.FT_Get_Advance(self.face, c.FT_Get_Char_Index(self.face, codepoint), 1, &units));
        return @as(f32, @floatFromInt(units)) * pixels / @as(f32, @floatFromInt(self.face.*.units_per_EM));
    }

    const Profile = struct { left: i32, shares: []f32 };

    /// The share of the glyph's ink in each pixel column, rendered with no
    /// hinting at `pixels` per em with its origin on a pixel edge, from
    /// column `left` on.
    fn columnProfile(self: *TestFace, gpa: std.mem.Allocator, codepoint: u32, pixels: f32) !Profile {
        try FreeType.intToError(c.FT_Set_Char_Size(self.face, 0, @intFromFloat(@round(pixels * 64)), 72, 72));
        // FT_LOAD_NO_HINTING | FT_LOAD_RENDER
        try FreeType.intToError(c.FT_Load_Char(self.face, codepoint, (1 << 1) | (1 << 2)));
        const glyph = self.face.*.glyph.*;
        const bitmap = glyph.bitmap;
        const shares = try gpa.alloc(f32, bitmap.width);
        @memset(shares, 0);
        var total: f32 = 0;
        for (0..bitmap.rows) |row| {
            for (0..bitmap.width) |col| {
                const value: f32 = @floatFromInt(bitmap.buffer[row * @as(usize, @intCast(bitmap.pitch)) + col]);
                shares[col] += value;
                total += value;
            }
        }
        for (shares) |*share| share.* /= total;
        return .{ .left = glyph.bitmap_left, .shares = shares };
    }
};

/// Draw `text` once with `renderText` into a picture `size` physical pixels
/// big, its top left at `origin` and `font.size * scale` pixels per em, and
/// answer each pixel's coverage (0..1), row by row.
fn testDraw(gpa: std.mem.Allocator, text: []const u8, font: Font, scale: f32, origin: dvui.Point.Physical, size: dvui.Size.Physical) ![]f32 {
    const rect: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = size.w, .h = size.h };
    var picture = dvui.Picture.start(rect) orelse return error.SkipZigTest;
    try dvui.renderText(.{ .font = font, .text = text, .rs = .{ .r = rect, .s = scale }, .color = .white, .p = origin });
    picture.stop();
    const cw = dvui.currentWindow();
    const pixels = try dvui.textureReadTarget(cw.lifo(), picture.texture);
    defer cw.lifo().free(pixels);
    const coverage = try gpa.alloc(f32, pixels.len);
    for (pixels, coverage) |pixel, *out| out.* = @as(f32, @floatFromInt(pixel.a)) / 255.0;
    picture.deinit();
    return coverage;
}

/// The ink in each column of `coverage` (rows of `width`).
fn testColumns(gpa: std.mem.Allocator, coverage: []const f32, width: usize) ![]f32 {
    const columns = try gpa.alloc(f32, width);
    @memset(columns, 0);
    for (coverage, 0..) |value, index| columns[index % width] += value;
    return columns;
}

test "a run of glyphs measures the sum of their exact advances, never rounded ones" {
    if (impl != .FreeType) return error.SkipZigTest;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 100 } });
    defer t.deinit();
    try dvui.addFont("VeraAdvance", test_vera, null);

    var face = try TestFace.open(test_vera);
    defer face.close();

    // 8.75 logical pixels at the testing window's scale of 2: 17.5 physical,
    // a size whose advances are nowhere near whole pixels.
    const font: Font = .find(.{ .family = "VeraAdvance", .size = 8.75, .size_mode = .pixel });
    const scale = dvui.windowNaturalScale();
    try std.testing.expectEqual(@as(f32, 2), scale);
    const expected = 10 * try face.advance('m', font.size * scale) / scale;
    const measured = font.textSize("mmmmmmmmmm").w;
    errdefer std.debug.print("ten m measure {d} logical, the outline says {d}\n", .{ measured, expected });
    try std.testing.expectApproxEqAbs(expected, measured, 0.01);
}

test "a glyph is drawn at the pen's fractional position, a quarter pixel at most off" {
    if (impl != .FreeType) return error.SkipZigTest;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 100 } });
    defer t.deinit();
    try dvui.addFont("VeraPen", test_vera, null);

    var face = try TestFace.open(test_vera);
    defer face.close();

    const font: Font = .find(.{ .family = "VeraPen", .size = 8.75, .size_mode = .pixel });
    const scale: f32 = 2;
    const advance = try face.advance('l', font.size * scale);

    const size: dvui.Size.Physical = .{ .w = 160, .h = 40 };
    const width: usize = @intFromFloat(size.w);
    const coverage = try testDraw(std.testing.allocator, "llllllllll", font, scale, .{ .x = 10, .y = 10 }, size);
    defer std.testing.allocator.free(coverage);
    const columns = try testColumns(std.testing.allocator, coverage, width);
    defer std.testing.allocator.free(columns);

    // Each 'l' is one stem; its ink's centre must move by exactly one
    // advance per glyph (4.86 px here). Rounded advances or pens drift.
    var first: f32 = 0;
    var worst: f32 = 0;
    for (0..10) |index| {
        const from: f32 = 10 + @as(f32, @floatFromInt(index)) * advance - 0.5;
        var ink: f32 = 0;
        var moment: f32 = 0;
        var column: usize = @intFromFloat(@max(0, @floor(from)));
        while (@as(f32, @floatFromInt(column)) < from + advance) : (column += 1) {
            ink += columns[column];
            moment += columns[column] * (@as(f32, @floatFromInt(column)) + 0.5);
        }
        const centre = moment / ink;
        if (index == 0) first = centre;
        const off = @abs(centre - first - @as(f32, @floatFromInt(index)) * advance);
        worst = @max(worst, off);
    }
    errdefer std.debug.print("an 'l' strays {d} px from where its pen put it\n", .{worst});
    try std.testing.expect(worst <= 0.25);
}

test "glyphs are hinted lightly: a stem keeps the outline's horizontal shape" {
    if (impl != .FreeType) return error.SkipZigTest;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 100 } });
    defer t.deinit();
    try dvui.addFont("VeraHint", test_vera, null);

    var face = try TestFace.open(test_vera);
    defer face.close();

    const font: Font = .find(.{ .family = "VeraHint", .size = 8.75, .size_mode = .pixel });
    const scale: f32 = 2;
    const reference = try face.columnProfile(std.testing.allocator, 'm', font.size * scale);
    defer std.testing.allocator.free(reference.shares);

    const size: dvui.Size.Physical = .{ .w = 60, .h = 40 };
    const width: usize = @intFromFloat(size.w);
    const coverage = try testDraw(std.testing.allocator, "m", font, scale, .{ .x = 10, .y = 10 }, size);
    defer std.testing.allocator.free(coverage);
    const columns = try testColumns(std.testing.allocator, coverage, width);
    defer std.testing.allocator.free(columns);
    var total: f32 = 0;
    for (columns) |ink| total += ink;

    // Full hinting moves and widens the stems to whole pixels; light hinting
    // only fits the glyph vertically, so its columns carry the outline's ink.
    var distance: f32 = 0;
    for (columns, 0..) |ink, column| {
        const ref_column = @as(i32, @intCast(column)) - 10 - reference.left;
        const expected = if (ref_column >= 0 and ref_column < reference.shares.len) reference.shares[@intCast(ref_column)] else 0;
        distance += @abs(ink / total - expected);
    }
    errdefer std.debug.print("the drawn m's columns differ from the outline's by {d} (of 2)\n", .{distance});
    try std.testing.expect(distance < 0.1);
}

test "kerning comes from the font's GPOS table when it has no kern table" {
    if (impl != .FreeType) return error.SkipZigTest;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 100 } });
    defer t.deinit();
    try dvui.addFont("AleoKern", test_aleo, null);

    // Aleo (like Geist, Inter and most fonts made since) kerns in GPOS only:
    // "AV" is -170 units of 1000, "To" -30 (fontTools reads the same).
    const font: Font = .find(.{ .family = "AleoKern", .size = 8.75, .size_mode = .pixel });
    for ([_]struct { text: []const u8, units: f32 }{
        .{ .text = "AV", .units = -170 },
        .{ .text = "To", .units = -30 },
        .{ .text = "xx", .units = 0 },
    }) |case| {
        const kerned = font.textSizeEx(case.text, .{ .kerning = true }).w;
        const plain = font.textSizeEx(case.text, .{ .kerning = false }).w;
        const expected = case.units * font.size / 1000;
        errdefer std.debug.print("\"{s}\" kerns by {d} logical, the font says {d}\n", .{ case.text, kerned - plain, expected });
        try std.testing.expectApproxEqAbs(expected, kerned - plain, 0.01);
    }
}

const std = @import("std");
const dvui = @import("dvui.zig");

const Ninepatch = dvui.Ninepatch;
const Options = dvui.Options;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const CornerRect = dvui.CornerRect;
const Size = dvui.Size;
const Widget = dvui.Widget;
const Id = dvui.Id;
const WidgetData = @This();

pub const InitOptions = struct {
    // if true, don't send our rect through our parent because we aren't located inside our parent
    subwindow: bool = false,
    scroll_when_focused: bool = true,
};

id: Id,
parent: Widget,
init_options: InitOptions,
rect: Rect,
min_size: Size,
options: Options,
src: std.builtin.SourceLocation,
rect_scale: ?RectScale = null,
ak_node: if (dvui.accesskit_enabled) ?*dvui.AccessKit.Node else void = if (dvui.accesskit_enabled) null else {},

pub fn init(src: std.builtin.SourceLocation, init_options: InitOptions, opts: Options) WidgetData {
    const parent = dvui.parentGet();
    const id = parent.extendId(src, opts.idExtra());

    var options = if (dvui.debug.options_override.get(id)) |val| val.@"0" else opts;
    if (options.corners) |*corners| corners.* = corners.finalize(options.theme);
    if (options.box_shadow) |*box_shadow| {
        if (box_shadow.corners) |*corners| corners.* = corners.finalize(options.theme);
    }

    const min_size = options.min_sizeGet();
    var ms = min_size;
    if (dvui.minSizeGet(id)) |min_last_frame| {
        // Need to take the max of both given and previous.  ScrollArea could be
        // passed a min size Size{.w = 0, .h = 200} meaning to get the width from the
        // previous min size.
        ms = Size.max(ms, min_last_frame);
    }

    const rect = if (options.rect) |r|
        r.toSize(.{
            .w = if (options.expandGet().isHorizontal())
                parent.data().contentRect().w
            else if (r.w == 0) ms.w else r.w,
            .h = if (options.expandGet().isVertical())
                parent.data().contentRect().h
            else if (r.h == 0) ms.h else r.h,
        })
    else blk: {
        if (options.expandGet() == .ratio and (ms.w == 0 or ms.h == 0)) {
            dvui.log.debug("rectFor {x} expand is .ratio but min size is zero\n", .{id});
        }
        break :blk parent.rectFor(id, ms, options.expandGet(), options.gravityGet());
    };

    return .{
        .id = id,
        .parent = parent,
        .init_options = init_options,
        .min_size = min_size,
        .rect = rect,
        .options = options,
        .src = src,
    };
}

pub fn rectSet(self: *WidgetData, r: Rect) void {
    self.rect = r;
    self.rect_scale = self.rectScaleFromParent();
}

pub fn register(self: *WidgetData) void {
    if (dvui.snapToPixels() and !self.init_options.subwindow and !self.isRoot()) {
        self.rect = self.snappedRect();
    }
    self.rectSet(self.rect);

    if (self.options.theme) |t| {
        dvui.currentWindow().addEmbeddedFontsFromTheme(t);
    }

    if (self.options.role) |role| {
        _ = dvui.currentWindow().accesskit.nodeCreate(self, role);
    }

    if (self.options.data_out) |do| {
        do.* = self.*;
    }

    // for normal widgets this is fine, but subwindows have to take care to
    // call captureMouseMaintain after subwindowCurrentSet and subwindowAdd
    if (!self.init_options.subwindow) {
        dvui.captureMouseMaintain(.{ .id = self.id, .rect = self.borderRectScale().r, .subwindow_id = dvui.subwindowCurrentId() });
    }

    var cw = dvui.currentWindow();

    if (self.options.tag) |t| {
        dvui.tag(t, .{ .id = self.id, .rect = self.rectScale().r, .visible = self.visible() });
    }

    cw.last_registered_id_this_frame = self.id;

    // First widget to register this frame marks the end of the event phase and
    // the start of the build phase for frame timing (see `Window.frameTiming`).
    if (cw.ft_awaiting_build) {
        cw.ft_awaiting_build = false;
        cw.ft_build_start = cw.backend.nanoTime();
    }

    // Record this widget if a machine-readable frame dump is being captured (see
    // `Debug.captureFrame`/`dumpFrame`). Off by default, so this is one branch.
    if (dvui.debug.capturing) {
        dvui.debug.captureWidget(cw.gpa, self);
    }

    const focused_widget_id = dvui.focusedWidgetId();
    if (self.id == focused_widget_id) {
        cw.last_focused_id_this_frame = self.id;

        if (cw.scroll_to_focused) {
            cw.scroll_to_focused = false;
            if (self.init_options.scroll_when_focused) {
                dvui.scrollTo(.{
                    .screen_rect = self.rectScale().r,
                });
            }
        }
    }

    if (self.id == dvui.focusedWidgetIdInCurrentSubwindow()) {
        cw.last_focused_id_in_subwindow = self.id;
    }

    if (dvui.testing.widget_hasher) |*hasher| {
        hasher.update(std.mem.asBytes(&self.init_options));
        hasher.update(std.mem.asBytes(&self.options.hash()));
        hasher.update(std.mem.asBytes(&self.rectScale()));
        hasher.update(std.mem.asBytes(&(self.id == focused_widget_id)));
    }

    if (dvui.debug.target == .focused and self.id == focused_widget_id) {
        dvui.debug.widget_id = self.id;
    }

    if (cw.min_sizes.containsUsed(self.id)) |used| {
        if (used) {
            const name: []const u8 = self.options.name orelse "???";
            dvui.log.err("{s}:{d} duplicate widget id {x} (widget \"{s}\" highlighted in red); you may need to pass .{{.id_extra=<loop index>}} as widget options (see https://github.com/david-vanderson/dvui/blob/master/readme-implementation.md#widget-ids )\n", .{ self.src.file, self.src.line, self.id, name });
            dvui.Debug.errorOutline(self.rectScale().r);
        }
    }

    if (dvui.debug.target.mouse() or self.id == dvui.debug.widget_id) {
        var rs = self.rectScale();

        if (dvui.debug.target.mouse() and
            rs.r.contains(cw.mouse_pt) and
            // prevents stuff in scroll area outside viewport being caught
            dvui.clipGet().contains(cw.mouse_pt) and
            // prevents stuff in lower subwindows being caught
            cw.subwindows.windowFor(cw.mouse_pt) == dvui.subwindowCurrentId())
        {
            dvui.debug.under_mouse_stack.append(cw.gpa, .{
                .id = self.id,
                // Fallback must be empty so that freeing the name will be valid
                .name = cw.gpa.dupe(u8, self.options.name orelse "") catch "",
            }) catch |err| {
                dvui.logError(@src(), err, "Could not add debug info for widgets under mouse position. Widget {x} {s}", .{ self.id, self.options.name orelse "???" });
            };
            dvui.debug.widget_id = self.id;
        }

        if (self.id == dvui.debug.widget_id) {
            if (dvui.debug.widget_panic) {
                @panic("Debug Window Panic");
            }

            dvui.debug.target_wd = self.*;
            dvui.debug.target_wd.?.parent = undefined;

            dvui.Debug.errorOutline(rs.r);
        }
    }
}

/// `rect`, moved and resized by less than a physical pixel so that the BORDER
/// rect — the part that draws — has all four edges on whole physical pixels.
///
/// Under `snap_to_pixels` the layout promises what the text renderer already
/// does: crisp output. A widget cannot keep that promise for itself, because
/// its origin is inherited — a line box measured from a font, a gravity that
/// centres it in leftover room, or a parent's 5 px inset (8.75 physical at
/// 175 %) each hand a fraction to everything laid out after them. So the
/// rounding happens here, once, where every laid-out widget passes.
///
/// Each edge rounds half UP (`floor(x + 0.5)`) rather than half away from
/// zero, so a whole-pixel width stays exactly that width wherever it lands —
/// on a negative coordinate (scrolled above the viewport) as well — and two
/// siblings that share an edge still share it. Only a fractional width (an
/// expanded widget's share of leftover room) can change, by under a pixel.
/// Sizes that come from content are already whole: `minSizeSetAndRefresh`
/// rounds them up.
///
/// A subwindow is placed in window coordinates by its own code
/// (`FloatingWindowWidget` snaps itself) and the window root is the window.
fn snappedRect(self: *const WidgetData) Rect {
    const rs = self.parent.screenRectScale(self.rect);
    const scale = rs.s;
    if (!(scale > 0)) return self.rect;
    const margin = self.options.marginGet();
    const left = rs.r.x + margin.x * scale;
    const top = rs.r.y + margin.y * scale;
    const right = rs.r.x + rs.r.w - margin.w * scale;
    const bottom = rs.r.y + rs.r.h - margin.h * scale;
    if (!(right >= left and bottom >= top)) return self.rect;
    const move_left = (roundHalfUp(left) - left) / scale;
    const move_top = (roundHalfUp(top) - top) / scale;
    const move_right = (roundHalfUp(right) - right) / scale;
    const move_bottom = (roundHalfUp(bottom) - bottom) / scale;
    return .{
        .x = self.rect.x + move_left,
        .y = self.rect.y + move_top,
        .w = @max(0, self.rect.w + move_right - move_left),
        .h = @max(0, self.rect.h + move_bottom - move_top),
    };
}

fn roundHalfUp(value: f32) f32 {
    return @floor(value + 0.5);
}

/// `size` (logical, at `scale` physical per logical) grown to the next whole
/// number of physical pixels. A hair over a whole pixel — float noise from a
/// sum of logical lengths — does not grow it.
fn ceilToPixels(size: Size, scale: f32) Size {
    if (!(scale > 0)) return size;
    return .{
        .w = ceilToPixelsAxis(size.w, scale),
        .h = ceilToPixelsAxis(size.h, scale),
    };
}

/// `length` rounded UP to whole physical pixels — except by what f32 itself
/// adds. A box asks for the sum of its children in f32 logical pixels, and
/// past a few thousand pixels a sum of whole-pixel sizes lands thousandths
/// over the whole number it stands for: 25.142857, the f32 nearest 44 / 1.75,
/// is a hair over it, and three hundred such rows came to 17,386.045 physical
/// for 17,386. So the slack grows with the size: a thousandth of a pixel, or
/// one part in 65,536 of the length (0.27 px at 17,386, six times that drift);
/// what it can ever cut is that much of the far end.
fn ceilToPixelsAxis(length: f32, scale: f32) f32 {
    if (length <= 0 or length >= dvui.max_float_safe) return length;
    const physical = length * scale;
    const slack = @max(0.001, physical / 65536.0);
    return @ceil(physical - slack) / scale;
}

pub fn visible(self: *const WidgetData) bool {
    return self.borderRectScale().r.visible();
}

pub fn borderAndBackground(self: *const WidgetData, opts: struct {
    fill_color: ?dvui.ColorOrGradient = null,
    ninepatch: ?*const Ninepatch = null,
    /// If null, 1.0 (0.0 when drawing a ninepatch, which already has its
    /// own baked edges).
    fade: ?f32 = null,
}) void {
    if (!self.visible()) {
        return;
    }

    if (self.options.box_shadow) |bs| {
        const rs = self.borderRectScale();
        const corners = bs.corners orelse self.options.cornersGet();

        const prect = rs.r.insetAll(rs.s * bs.shrink).offsetPoint(bs.offset.scale(rs.s, dvui.Point.Physical));

        prect.fill(corners.scale(rs.s, CornerRect.Physical), .{ .color = .{ .color = bs.color.opacity(bs.alpha) }, .fade = rs.s * bs.fade });
    }

    var bg = self.options.backgroundGet();
    const b = self.options.borderGet();

    if (b.nonZero()) {
        const uniform: bool = (b.x == b.y and b.x == b.w and b.x == b.h);
        if (uniform) {
            // draw border as stroked path
            const r = self.borderRect().inset(b.scale(0.5, Rect));
            const rs = self.rectScale().rectToRectScale(r.offsetNeg(self.rect));
            rs.r.stroke(self.options.cornersGet().scale(rs.s, CornerRect.Physical), .{
                .thickness = b.x * rs.s,
                .color = self.options.color(.border).scale(rs.s),
            });
        } else {
            // non-uniform border, draw it first as large rect with background/ninepatch on top
            if (!bg) {
                dvui.log.debug("borderAndBackground {x} forcing background on to support non-uniform border\n", .{self.id});
                bg = true;
            }

            var rs = self.borderRectScale();
            if (!rs.r.empty()) {
                const fade: f32 = opts.fade orelse 1.0;
                if (fade > 0) {
                    // if any border is zero, inset by half the fade so it doesn't bleed out
                    var inset: Rect.Physical = .{};
                    if (b.x == 0) inset.x = fade * 0.5;
                    if (b.y == 0) inset.y = fade * 0.5;
                    if (b.w == 0) inset.w = fade * 0.5;
                    if (b.h == 0) inset.h = fade * 0.5;
                    rs.r = rs.r.inset(inset);
                }
                rs.r.fill(self.options.cornersGet().scale(rs.s, CornerRect.Physical), .{
                    .color = self.options.color(.border).scale(rs.s),
                    .fade = fade,
                });
            }
        }
    }

    const ninepatch = opts.ninepatch orelse self.options.ninepatch(.fill);

    if (bg) {
        const rs = self.backgroundRectScale();
        if (!rs.r.empty()) {
            rs.r.fill(self.options.cornersGet().scale(rs.s, CornerRect.Physical), .{
                .color = (opts.fill_color orelse self.options.color(.fill)).scale(rs.s),
                .fade = opts.fade orelse (if (ninepatch != null) 0.0 else 1.0),
            });
        }
    }

    // can draw a ninepatch without a background, some of it could be transparent
    if (ninepatch) |np| {
        const rs = self.backgroundRectScale();
        dvui.renderNinepatch(np.*, rs, .{}) catch |err| {
            dvui.log.err("while drawing ninepatch: {}, {}", .{ err, rs });
        };
    }
}

pub fn focusBorder(self: *const WidgetData) void {
    if (self.visible()) {
        const rs = self.borderRectScale();
        const thick = 2 * rs.s;

        rs.r.stroke(self.options.cornersGet().scale(rs.s, CornerRect.Physical), .{ .thickness = thick, .color = .{ .color = self.options.themeGet().focus }, .after = true });
    }
}

pub fn rectScaleFromParent(self: *const WidgetData) RectScale {
    return if (self.init_options.subwindow)
        dvui.windowRectScale().rectToRectScale(self.rect)
    else
        self.parent.screenRectScale(self.rect);
}

pub fn rectScale(self: *const WidgetData) RectScale {
    if (self.rect_scale) |rs| {
        return rs;
    }

    // This can happen if a widget calls rectScale before calling register.
    // Reorderable does that to check if one is being dragged over another.
    return self.rectScaleFromParent();
}

pub fn borderRect(self: *const WidgetData) Rect {
    return self.rect.inset(self.options.marginGet());
}

pub fn borderRectScale(self: *const WidgetData) RectScale {
    const r = self.borderRect().offsetNeg(self.rect);
    return self.rectScale().rectToRectScale(r);
}

pub fn backgroundRect(self: *const WidgetData) Rect {
    return self.rect.inset(self.options.marginGet()).inset(self.options.borderGet());
}

pub fn backgroundRectScale(self: *const WidgetData) RectScale {
    const r = self.backgroundRect().offsetNeg(self.rect);
    return self.rectScale().rectToRectScale(r);
}

pub fn contentRect(self: *const WidgetData) Rect {
    return self.rect.inset(self.options.marginGet()).inset(self.options.borderGet()).inset(self.options.paddingGet());
}

pub fn contentRectScale(self: *const WidgetData) RectScale {
    const r = self.contentRect().offsetNeg(self.rect);
    return self.rectScale().rectToRectScale(r);
}

pub fn minSizeMax(self: *WidgetData, s: Size) void {
    self.min_size = Size.max(self.min_size, s);
}

pub fn minSizeSetAndRefresh(self: *WidgetData) void {
    self.min_size = self.min_size.min(self.options.max_sizeGet());
    // Under `snap_to_pixels` what a widget asks for is a whole number of
    // physical pixels, rounded UP so nothing it measured is cut: a label's
    // line box of 23.4 physical px asks for 24. Then a stack of such widgets
    // is whole at every step, and `snappedRect` never has to shrink a widget
    // that is exactly as big as its text to put it on a pixel (which would
    // ellipsize the text).
    if (dvui.snapToPixels() and !self.isRoot()) {
        self.min_size = ceilToPixels(self.min_size, self.rectScale().s);
    }

    if (dvui.minSizeGet(self.id)) |ms| {
        // If the size we got was exactly our previous min size then our min size
        // was a binding constraint.  So if our min size changed it might cause
        // layout changes.

        // If this was like a Label where we knew the min size before getting our
        // rect, then either our min size is the same as previous, or our rect is
        // a different size than our previous min size.
        if ((self.rect.w == ms.w and ms.w != self.min_size.w) or
            (self.rect.h == ms.h and ms.h != self.min_size.h))
        {
            //std.debug.print("{x} minSizeSetAndRefresh {} {} {}\n", .{ self.id, self.rect, ms, self.min_size });

            dvui.refresh(null, @src(), self.id);
        }
    } else {
        // This is the first frame for this widget.  Almost always need a
        // second frame to appear correctly since nobody knew our min size the
        // first frame.
        dvui.refresh(null, @src(), self.id);
    }

    var cw = dvui.currentWindow();

    cw.min_sizes.put(cw.gpa, self.id, self.min_size) catch |err| {
        // returning an error here means that all widgets deinit can return
        // it, which is very annoying because you can't "defer try
        // widget.deinit()".  Also if we are having memory issues then we
        // have larger problems than here.
        dvui.log.err("minSizeSetAndRefresh got {any} when trying to set min size of widget {x}\n", .{ err, self.id });
    };
}

pub fn minSizeReportToParent(self: *const WidgetData) void {
    if (self.options.rect == null) {
        self.parent.minSizeForChild(self.min_size);
    }
}

pub fn validate(self: *const WidgetData) *WidgetData {
    std.debug.assert(self.id != Id.undef); // Indicates a use after deinit() error.
    return @constCast(self);
}

pub fn isRoot(self: *const WidgetData) bool {
    // Window is its own parent
    return (self.id == self.parent.data().id);
}

pub const ParentIterator = struct {
    wd: ?*const WidgetData,

    pub fn next(it: *ParentIterator) ?*const WidgetData {
        const ret = it.wd;

        if (it.wd) |wd| {
            if (wd.isRoot()) {
                it.wd = null;
            } else {
                it.wd = wd.parent.data();
            }
        }

        return ret;
    }
};

pub fn iterator(self: *const WidgetData) ParentIterator {
    return .{ .wd = self };
}

// NOTE: `inline` is required so that null will be returned at comptime. Otherwise other
//       accesskit functions, which are not linked, might be referenced and fail to compile
pub inline fn accesskit_node(self: *const WidgetData) ?*dvui.AccessKit.Node {
    if (!dvui.accesskit_enabled) return null;
    return self.ak_node;
}

test {
    @import("std").testing.refAllDecls(@This());
}

/// Every captured widget's border rect, as the four physical edges, with the
/// widgets that cannot be judged (the window root, empty or hidden rects)
/// left out. The caller owns nothing; the slice is the capture's.
fn testFractionalEdges(scale_note: f32) !usize {
    const capture = dvui.debug.lastCapture() orelse return error.NoCapture;
    var fractional: usize = 0;
    for (capture.widgets.items) |widget| {
        if (widget.parent_id == widget.id) continue;
        if (!widget.visible) continue;
        const rect = widget.rect_border;
        if (rect.w <= 0 or rect.h <= 0) continue;
        const edges = [_]f32{ rect.x, rect.y, rect.x + rect.w, rect.y + rect.h };
        for (edges) |edge| {
            if (@abs(edge - @round(edge)) > 0.01) {
                fractional += 1;
                std.debug.print("  {d}: {s}:{d} {s} edge {d:.3}\n", .{ scale_note, widget.src_file, widget.src_line, widget.name orelse "?", edge });
                break;
            }
        }
    }
    return fractional;
}

test "under snap_to_pixels a laid-out widget's border lands on whole physical pixels" {
    // At 175 % a logical pixel is 1.75 physical ones, and three things put a
    // widget on a fraction: a size MEASURED from a font (a label's line box is
    // 13.37 logical px, 23.4 physical), a gravity that centres something in
    // leftover room, and an inset that is not a whole number of physical pixels
    // (5 logical is 8.75). Each hands its fraction to everything laid out
    // after it, so no widget can fix it for itself: the editor's lint kept
    // finding a dropdown and a button a fraction off in the property grid
    // however their own sizes were snapped. `snap_to_pixels` is dvui's
    // promise of crisp output, so the layout keeps it too.
    const Local = struct {
        var choice: usize = 0;

        fn frame() !dvui.App.Result {
            var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer page.deinit();
            // A size measured from a font…
            dvui.labelNoFmt(@src(), "Transform", .{}, .{});
            // …and a filled box stacked under it, which inherits the fraction.
            var strip = dvui.box(@src(), .{}, .{ .background = true, .min_size_content = .{ .w = 100, .h = 20 } });
            strip.deinit();
            // A cell of one control height with a dropdown centred in it: the
            // editor's property grid.
            {
                var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .min_size_content = .{ .w = 0, .h = 28 },
                    .max_size_content = .{ .w = dvui.max_float_safe, .h = 28 },
                });
                defer cell.deinit();
                _ = dvui.dropdown(@src(), &.{ "Box", "Sphere" }, .{ .choice = &choice }, .{}, .{ .gravity_y = 0.5 });
            }
            // An inset of 5 logical px around a button.
            {
                var host = dvui.box(@src(), .{}, .{ .padding = .all(5), .background = true });
                defer host.deinit();
                _ = dvui.button(@src(), "Send", .{}, .{});
            }
            return .ok;
        }
    };

    for ([_]f32{ 1.0, 1.75, 2.0 }) |scale| {
        var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 240 } });
        defer t.deinit();
        // The testing backend's natural scale is 2 (pixels are twice the
        // window size), so this is the physical-per-logical scale asked for.
        t.window.content_scale = scale / 2;
        try dvui.testing.settle(Local.frame);
        dvui.debug.captureFrame();
        _ = try dvui.testing.step(Local.frame);
        _ = try dvui.testing.step(Local.frame);
        defer dvui.debug.clearCaptures(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), try testFractionalEdges(scale));
    }
}

test "without snap_to_pixels the layout keeps its fractions" {
    // The other half: the rounding is `snap_to_pixels`, not a change to every
    // layout. A caller that turns it off — a zoomed canvas that wants smooth
    // sub-pixel motion — keeps the exact positions, and this frame at 175 % is
    // the proof that the previous test can fail at all.
    const Local = struct {
        fn frame() !dvui.App.Result {
            var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer page.deinit();
            dvui.labelNoFmt(@src(), "Transform", .{}, .{});
            var strip = dvui.box(@src(), .{}, .{ .background = true, .min_size_content = .{ .w = 100, .h = 20 } });
            strip.deinit();
            return .ok;
        }
    };
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 240 } });
    defer t.deinit();
    t.window.content_scale = 1.75 / 2.0;
    const previous = dvui.snapToPixelsSet(false);
    defer _ = dvui.snapToPixelsSet(previous);
    try dvui.testing.settle(Local.frame);
    dvui.debug.captureFrame();
    _ = try dvui.testing.step(Local.frame);
    _ = try dvui.testing.step(Local.frame);
    defer dvui.debug.clearCaptures(std.testing.allocator);
    try std.testing.expect(try testFractionalEdges(1.75) > 0);
}

test "a long column of whole-pixel rows asks for exactly their sum, never a pixel more" {
    // Under `snap_to_pixels` each row asks for a whole number of physical
    // pixels, so the column holding them should too: N rows of 44 physical
    // px with 14 between them is 58 N - 14. But the column adds the rows up
    // in f32 LOGICAL pixels (25.142857 each at 175 %), and past a few
    // thousand pixels the sum lands a few thousandths over the whole number
    // it stands for — more than `ceilToPixels`' 0.001 — and is rounded up a
    // whole pixel. A chat transcript drawn whole and the same transcript
    // with its off-screen rows folded into one spacer then disagreed by a
    // pixel at the bottom of the scroll (zigame's transcript_window_tests).
    const Local = struct {
        var rows: usize = 0;
        /// The column's height as it asked for it on the frame before.
        var asked: f32 = 0;

        fn frame() !dvui.App.Result {
            var column = dvui.box(@src(), .{ .dir = .vertical, .gap = 8 }, .{});
            for (0..rows) |index| {
                var row = dvui.box(@src(), .{}, .{ .id_extra = index, .min_size_content = .{ .w = 10, .h = 44.0 / 1.75 } });
                row.deinit();
            }
            const id = column.data().id;
            column.deinit();
            if (dvui.minSizeGet(id)) |size| asked = size.h;
            return .ok;
        }
    };
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 240 } });
    defer t.deinit();
    t.window.content_scale = 1.75 / 2.0;
    var worst: f32 = 0;
    var count: usize = 300;
    while (count < 420) : (count += 7) {
        Local.rows = count;
        try dvui.testing.settle(Local.frame);
        _ = try dvui.testing.step(Local.frame);
        const wanted: f32 = @floatFromInt(58 * count - 14);
        const off = Local.asked * 1.75 - wanted;
        if (@abs(off) > @abs(worst)) worst = off;
    }
    errdefer std.debug.print("a column of whole-pixel rows asked for {d} physical px more than their sum\n", .{worst});
    try std.testing.expect(@abs(worst) < 0.01);
}

//! A polygon scan converter: closed contours in, the share of every pixel
//! they cover out (0..1), by the nonzero or the even-odd rule.
//!
//! Each pixel row is sampled on 16 sub-rows; along a sub-row the span a
//! shape covers is exact, so a pixel gets the true share of each sub-row
//! (horizontal anti-aliasing is exact, vertical is to 1/16). Overlapping
//! contours are resolved by their winding before anything is counted, so
//! a union of overlapping pieces (a stroke built from a band per segment
//! and a disc per joint) is covered once, edges included: what a browser's
//! rasteriser does, and what a mesh of separately anti-aliased pieces
//! cannot do.

/// Which points a set of contours covers.
pub const FillRule = enum {
    /// Covered where the contours wind around the point at all: overlaps
    /// join.
    nonzero,
    /// Covered where an odd number of contours surround the point: a
    /// contour inside another is a hole whichever way it runs.
    evenodd,
};

/// Sub-rows sampled per pixel row.
pub const sub_rows = 16;

/// One contour edge where a sub-row crosses it.
const Crossing = struct {
    /// Global sub-row index (pixel row * `sub_rows` + sub-row).
    sub_row: u32,
    x: f32,
    winding: i8,

    fn lessThan(_: void, a: Crossing, b: Crossing) bool {
        if (a.sub_row != b.sub_row) return a.sub_row < b.sub_row;
        return a.x < b.x;
    }
};

/// Collects the contours of one shape, then fills them into a coverage
/// buffer. Reuse it for the next shape with `reset`.
pub const Rasterizer = struct {
    width: usize,
    height: usize,
    /// Every point added is multiplied by this first.
    scale: f32 = 1,
    crossings: std.ArrayList(Crossing) = .empty,

    pub fn init(width: usize, height: usize) Rasterizer {
        return .{ .width = width, .height = height };
    }

    pub fn deinit(self: *Rasterizer, gpa: std.mem.Allocator) void {
        self.crossings.deinit(gpa);
    }

    /// Forget every contour added, keeping the memory.
    pub fn reset(self: *Rasterizer) void {
        self.crossings.clearRetainingCapacity();
    }

    /// Add one closed contour (its last point joins its first).
    pub fn addContour(self: *Rasterizer, gpa: std.mem.Allocator, points: []const Point) std.mem.Allocator.Error!void {
        if (points.len < 3) return;
        for (points, 0..) |from, index| {
            const to = points[(index + 1) % points.len];
            try self.addEdge(gpa, from.scale(self.scale, Point), to.scale(self.scale, Point));
        }
    }

    fn addEdge(self: *Rasterizer, gpa: std.mem.Allocator, from: Point, to: Point) std.mem.Allocator.Error!void {
        if (!(from.y != to.y)) return; // horizontal (or NaN): crosses no sub-row
        const winding: i8 = if (to.y > from.y) 1 else -1;
        const top = @min(from.y, to.y);
        const bottom = @max(from.y, to.y);
        const rows: f32 = @floatFromInt(self.height * sub_rows);
        // sub-row s samples y = (s + 0.5) / sub_rows; an edge holds the
        // samples with top <= y < bottom, so a vertex shared by two edges
        // is counted once
        const first = @max(0, @ceil(top * sub_rows - 0.5));
        const last = @min(rows, @ceil(bottom * sub_rows - 0.5));
        if (!(first < last)) return;
        const slope = (to.x - from.x) / (to.y - from.y);
        var sub_row = first;
        while (sub_row < last) : (sub_row += 1) {
            const y = (sub_row + 0.5) / sub_rows;
            try self.crossings.append(gpa, .{
                .sub_row = @intFromFloat(sub_row),
                .x = from.x + (y - from.y) * slope,
                .winding = winding,
            });
        }
    }

    /// Fill the contours added into `coverage` (`width` x `height`, row by
    /// row), overwriting it: each pixel's covered share, 0..1.
    pub fn fill(self: *Rasterizer, rule: FillRule, coverage: []f32) void {
        std.debug.assert(coverage.len == self.width * self.height);
        @memset(coverage, 0);
        const crossings = self.crossings.items;
        std.sort.pdq(Crossing, crossings, {}, Crossing.lessThan);
        const weight: f32 = 1.0 / @as(f32, @floatFromInt(sub_rows));

        var index: usize = 0;
        while (index < crossings.len) {
            const sub_row = crossings[index].sub_row;
            const row = sub_row / sub_rows;
            const line = coverage[row * self.width ..][0..self.width];
            var winding: i32 = 0;
            var span_start: f32 = 0;
            while (index < crossings.len and crossings[index].sub_row == sub_row) : (index += 1) {
                const crossing = crossings[index];
                const was_inside = inside(winding, rule);
                winding += crossing.winding;
                const now_inside = inside(winding, rule);
                if (!was_inside and now_inside) span_start = crossing.x;
                if (was_inside and !now_inside) addSpan(line, span_start, crossing.x, weight);
            }
        }
        for (coverage) |*value| value.* = @min(1, value.*);
    }

    fn inside(winding: i32, rule: FillRule) bool {
        return switch (rule) {
            .nonzero => winding != 0,
            .evenodd => @mod(winding, 2) != 0,
        };
    }
};

/// Add `weight` times the share of each pixel of `line` that [from, to)
/// covers.
fn addSpan(line: []f32, from: f32, to: f32, weight: f32) void {
    const right: f32 = @floatFromInt(line.len);
    const start = math.clamp(from, 0, right);
    const end = math.clamp(to, 0, right);
    if (!(start < end)) return;
    const first: usize = @intFromFloat(@floor(start));
    const last: usize = @intFromFloat(@floor(end));
    if (first == last) {
        line[first] += (end - start) * weight;
        return;
    }
    line[first] += (@as(f32, @floatFromInt(first + 1)) - start) * weight;
    for (line[first + 1 .. last]) |*value| value.* += weight;
    if (last < line.len) line[last] += (end - @as(f32, @floatFromInt(last))) * weight;
}

const std = @import("std");
const math = std.math;
const dvui = @import("dvui.zig");
const Point = dvui.Point.Physical;

fn testFill(points: []const []const Point, rule: FillRule, coverage: []f32, width: usize) !void {
    var raster: Rasterizer = .init(width, coverage.len / width);
    defer raster.deinit(std.testing.allocator);
    for (points) |contour| try raster.addContour(std.testing.allocator, contour);
    raster.fill(rule, coverage);
}

test "a square on pixel edges covers its pixels wholly and nothing else" {
    var coverage: [6 * 6]f32 = undefined;
    try testFill(&.{&.{ .{ .x = 1, .y = 1 }, .{ .x = 4, .y = 1 }, .{ .x = 4, .y = 3 }, .{ .x = 1, .y = 3 } }}, .nonzero, &coverage, 6);
    for (coverage, 0..) |value, index| {
        const column = index % 6;
        const row = index / 6;
        const expected: f32 = if (column >= 1 and column < 4 and row >= 1 and row < 3) 1 else 0;
        try std.testing.expectApproxEqAbs(expected, value, 1e-5);
    }
}

test "an edge at a fractional position gives each pixel its exact share" {
    // a slanted left edge from x 1.25 (top) to x 2.75 (bottom), over 4 rows
    var coverage: [4 * 4]f32 = undefined;
    try testFill(&.{&.{ .{ .x = 1.25, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 2.75, .y = 4 } }}, .nonzero, &coverage, 4);
    for (0..4) |row| {
        for (0..4) |column| {
            // the true share: the area right of the edge inside the pixel
            var share: f32 = 0;
            for (0..64) |sample| {
                const y = @as(f32, @floatFromInt(row)) + (@as(f32, @floatFromInt(sample)) + 0.5) / 64;
                const edge = 1.25 + 1.5 * y / 4;
                const left: f32 = @floatFromInt(column);
                share += math.clamp(left + 1 - @max(left, edge), 0, 1) / 64;
            }
            try std.testing.expectApproxEqAbs(share, coverage[row * 4 + column], 0.02);
        }
    }
}

test "overlapping contours join under nonzero and cut a hole under even-odd" {
    const outer = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 6, .y = 0 }, .{ .x = 6, .y = 6 }, .{ .x = 0, .y = 6 } };
    const inner = [_]Point{ .{ .x = 2, .y = 2 }, .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 4 }, .{ .x = 2, .y = 4 } };
    var coverage: [6 * 6]f32 = undefined;

    try testFill(&.{ &outer, &inner }, .nonzero, &coverage, 6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), coverage[3 * 6 + 3], 1e-5);
    try testFill(&.{ &outer, &inner }, .evenodd, &coverage, 6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), coverage[3 * 6 + 3], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), coverage[0 * 6 + 0], 1e-5);

    // two half-overlapping squares, same direction: the overlap is covered
    // once, not twice, edges included
    const left = [_]Point{ .{ .x = 0.5, .y = 0.5 }, .{ .x = 3.5, .y = 0.5 }, .{ .x = 3.5, .y = 3.5 }, .{ .x = 0.5, .y = 3.5 } };
    const right = [_]Point{ .{ .x = 2.5, .y = 0.5 }, .{ .x = 5.5, .y = 0.5 }, .{ .x = 5.5, .y = 3.5 }, .{ .x = 2.5, .y = 3.5 } };
    try testFill(&.{ &left, &right }, .nonzero, &coverage, 6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), coverage[0 * 6 + 3], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), coverage[1 * 6 + 3], 1e-5);
}

test "a shape partly outside the raster is clipped to it" {
    var coverage: [4 * 4]f32 = undefined;
    try testFill(&.{&.{ .{ .x = -3, .y = -2 }, .{ .x = 2.5, .y = -2 }, .{ .x = 2.5, .y = 9 }, .{ .x = -3, .y = 9 } }}, .nonzero, &coverage, 4);
    for (0..4) |row| {
        try std.testing.expectApproxEqAbs(@as(f32, 1), coverage[row * 4 + 1], 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), coverage[row * 4 + 2], 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 0), coverage[row * 4 + 3], 1e-5);
    }
}

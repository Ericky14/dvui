//! Pair kerning from an OpenType font's `GPOS` table.
//!
//! FreeType's `FT_Get_Kerning` reads only the legacy `kern` table, and most
//! fonts made in the last decade (Geist, Inter, Noto, Aleo, ...) carry their
//! kerning in `GPOS` instead, so "To", "AV" and "P," were drawn with the gap a
//! browser closes. This reads exactly the part of `GPOS` a browser applies to a
//! plain run of left-to-right text: the lookups the `kern` feature names, and in
//! them the pair-adjustment subtables (lookup type 2, also when wrapped in a
//! type 9 extension), formats 1 (glyph pairs) and 2 (class pairs). The answer is
//! the first glyph's `XAdvance` adjustment, in font units.
//!
//! A font is a stranger's file (a game project brings its own), so every offset
//! and count is checked against the table's length before it is read; a table
//! that does not hold together answers 0 for the pair, never a crash.
const std = @import("std");

/// The kerning a face's `GPOS` table describes, borrowed from the table's bytes
/// (which must outlive it).
pub const Kern = struct {
    table: []const u8,
    /// Offsets (from the start of `table`) of every pair-adjustment subtable of
    /// every `kern` lookup, lookup by lookup in lookup-list order. A lookup's
    /// subtables are consecutive; `lookup_ends[i]` is one past lookup i's last.
    subtables: []const u32,
    lookup_ends: []const u32,

    /// Read the `kern` lookups out of a `GPOS` table, or null when it has none
    /// (or is not a `GPOS` table). `allocator` owns the two index slices; free
    /// them with `deinit`.
    pub fn init(allocator: std.mem.Allocator, table: []const u8) std.mem.Allocator.Error!?Kern {
        const major = readU16(table, 0) orelse return null;
        if (major != 1) return null;
        // Offsets are summed in u64: a damaged table's u16 fields can then never
        // wrap, and every read is bounds-checked against `table.len`.
        const feature_list: u64 = readU16(table, 6) orelse return null;
        const lookup_list: u64 = readU16(table, 8) orelse return null;

        // Every lookup any `kern` feature names, once each, in index order.
        var lookups: std.ArrayList(u16) = .empty;
        defer lookups.deinit(allocator);
        const feature_count = readU16(table, feature_list) orelse return null;
        var feature: u64 = 0;
        while (feature < feature_count) : (feature += 1) {
            const record = feature_list + 2 + feature * 6;
            const tag = readBytes(table, record, 4) orelse return null;
            if (!std.mem.eql(u8, tag, "kern")) continue;
            const feature_offset = feature_list + (readU16(table, record + 4) orelse return null);
            const index_count = readU16(table, feature_offset + 2) orelse continue;
            var index: u64 = 0;
            while (index < index_count) : (index += 1) {
                const lookup_index = readU16(table, feature_offset + 4 + index * 2) orelse break;
                if (std.mem.indexOfScalar(u16, lookups.items, lookup_index) == null) {
                    try lookups.append(allocator, lookup_index);
                }
            }
        }
        if (lookups.items.len == 0) return null;
        std.mem.sort(u16, lookups.items, {}, std.sort.asc(u16));

        var subtables: std.ArrayList(u32) = .empty;
        errdefer subtables.deinit(allocator);
        var lookup_ends: std.ArrayList(u32) = .empty;
        errdefer lookup_ends.deinit(allocator);

        const lookup_count = readU16(table, lookup_list) orelse return null;
        for (lookups.items) |lookup_index| {
            if (lookup_index >= lookup_count) continue;
            const lookup = lookup_list + (readU16(table, lookup_list + 2 + @as(u64, lookup_index) * 2) orelse continue);
            const lookup_type = readU16(table, lookup) orelse continue;
            const subtable_count = readU16(table, lookup + 4) orelse continue;
            var sub: u64 = 0;
            while (sub < subtable_count) : (sub += 1) {
                var offset = lookup + (readU16(table, lookup + 6 + sub * 2) orelse break);
                var subtable_type = lookup_type;
                if (lookup_type == 9) {
                    // Extension: format 1, the real type, a 32-bit offset.
                    if ((readU16(table, offset) orelse break) != 1) continue;
                    subtable_type = readU16(table, offset + 2) orelse break;
                    const far = readU32(table, offset + 4) orelse break;
                    offset += far;
                }
                if (subtable_type != 2) continue;
                const format = readU16(table, offset) orelse continue;
                if (format != 1 and format != 2) continue;
                try subtables.append(allocator, std.math.cast(u32, offset) orelse continue);
            }
            if (lookup_ends.items.len == 0 or lookup_ends.items[lookup_ends.items.len - 1] != subtables.items.len) {
                try lookup_ends.append(allocator, @intCast(subtables.items.len));
            }
        }
        if (subtables.items.len == 0) {
            subtables.deinit(allocator);
            lookup_ends.deinit(allocator);
            return null;
        }
        return .{
            .table = table,
            .subtables = try subtables.toOwnedSlice(allocator),
            .lookup_ends = try lookup_ends.toOwnedSlice(allocator),
        };
    }

    /// Free what `init` allocated.
    pub fn deinit(self: *Kern, allocator: std.mem.Allocator) void {
        allocator.free(self.subtables);
        allocator.free(self.lookup_ends);
        self.* = undefined;
    }

    /// The advance adjustment, in font units, between glyph `left` and the
    /// glyph `right` that follows it (negative pulls them together): the sum
    /// over the `kern` lookups of the first subtable in each that applies.
    pub fn pair(self: *const Kern, left: u32, right: u32) i32 {
        if (left > 0xFFFF or right > 0xFFFF) return 0;
        var total: i32 = 0;
        var start: usize = 0;
        for (self.lookup_ends) |end| {
            for (self.subtables[start..end]) |offset| {
                if (pairIn(self.table, offset, @intCast(left), @intCast(right))) |value| {
                    total += value;
                    break;
                }
            }
            start = end;
        }
        return total;
    }
};

/// The first glyph's XAdvance in one pair-adjustment subtable, or null when the
/// subtable does not apply to the pair (the next subtable is then asked).
fn pairIn(table: []const u8, subtable: u64, left: u16, right: u16) ?i32 {
    const format = readU16(table, subtable) orelse return null;
    const coverage = subtable + (readU16(table, subtable + 2) orelse return null);
    const coverage_index = coverageIndex(table, coverage, left) orelse return null;
    const value_format1 = readU16(table, subtable + 4) orelse return null;
    const value_format2 = readU16(table, subtable + 6) orelse return null;
    const size1 = valueRecordSize(value_format1);
    const size2 = valueRecordSize(value_format2);
    switch (format) {
        1 => {
            const pair_set_count = readU16(table, subtable + 8) orelse return null;
            if (coverage_index >= pair_set_count) return null;
            const pair_set = subtable + (readU16(table, subtable + 10 + coverage_index * 2) orelse return null);
            const count = readU16(table, pair_set) orelse return null;
            const record_size = 2 + size1 + size2;
            // The records are sorted by the second glyph: binary search.
            var low: u64 = 0;
            var high: u64 = count;
            while (low < high) {
                const middle = low + (high - low) / 2;
                const record = pair_set + 2 + middle * record_size;
                const second = readU16(table, record) orelse return null;
                if (second == right) return xAdvance(table, record + 2, value_format1);
                if (second < right) low = middle + 1 else high = middle;
            }
            return null;
        },
        2 => {
            const class_def1 = subtable + (readU16(table, subtable + 8) orelse return null);
            const class_def2 = subtable + (readU16(table, subtable + 10) orelse return null);
            const class1_count = readU16(table, subtable + 12) orelse return null;
            const class2_count = readU16(table, subtable + 14) orelse return null;
            const class1 = classOf(table, class_def1, left);
            const class2 = classOf(table, class_def2, right);
            if (class1 >= class1_count or class2 >= class2_count) return null;
            const record_size = size1 + size2;
            const record = subtable + 16 + (@as(u64, class1) * class2_count + class2) * record_size;
            return xAdvance(table, record, value_format1);
        },
        else => return null,
    }
}

/// Where `glyph` sits in a coverage table, or null when it is not covered.
fn coverageIndex(table: []const u8, coverage: u64, glyph: u16) ?u32 {
    const format = readU16(table, coverage) orelse return null;
    const count = readU16(table, coverage + 2) orelse return null;
    var low: u64 = 0;
    var high: u64 = count;
    switch (format) {
        1 => while (low < high) {
            const middle = low + (high - low) / 2;
            const id = readU16(table, coverage + 4 + middle * 2) orelse return null;
            if (id == glyph) return @intCast(middle);
            if (id < glyph) low = middle + 1 else high = middle;
        },
        2 => while (low < high) {
            const middle = low + (high - low) / 2;
            const range = coverage + 4 + middle * 6;
            const first = readU16(table, range) orelse return null;
            const last = readU16(table, range + 2) orelse return null;
            if (glyph < first) {
                high = middle;
            } else if (glyph > last) {
                low = middle + 1;
            } else {
                const start_index = readU16(table, range + 4) orelse return null;
                return @as(u32, start_index) + (glyph - first);
            }
        },
        else => {},
    }
    return null;
}

/// The class a class-definition table gives `glyph` (0 when it names none).
fn classOf(table: []const u8, class_def: u64, glyph: u16) u32 {
    const format = readU16(table, class_def) orelse return 0;
    switch (format) {
        1 => {
            const start = readU16(table, class_def + 2) orelse return 0;
            const count = readU16(table, class_def + 4) orelse return 0;
            if (glyph < start or glyph - start >= count) return 0;
            return readU16(table, class_def + 6 + @as(u64, glyph - start) * 2) orelse 0;
        },
        2 => {
            const count = readU16(table, class_def + 2) orelse return 0;
            var low: u64 = 0;
            var high: u64 = count;
            while (low < high) {
                const middle = low + (high - low) / 2;
                const range = class_def + 4 + middle * 6;
                const first = readU16(table, range) orelse return 0;
                const last = readU16(table, range + 2) orelse return 0;
                if (glyph < first) {
                    high = middle;
                } else if (glyph > last) {
                    low = middle + 1;
                } else {
                    return readU16(table, range + 4) orelse 0;
                }
            }
            return 0;
        },
        else => return 0,
    }
}

/// Bytes a value record of `format` takes: two per field it carries.
fn valueRecordSize(format: u16) u64 {
    return 2 * @as(u64, @popCount(format & 0x00FF));
}

/// The XAdvance field of a value record (0 when the format has none).
fn xAdvance(table: []const u8, record: u64, format: u16) ?i32 {
    if (format & 0x0004 == 0) return 0;
    // XPlacement and YPlacement come first when present.
    const before: u64 = 2 * @as(u64, @popCount(format & 0x0003));
    const raw = readU16(table, record + before) orelse return null;
    return @as(i16, @bitCast(raw));
}

fn readBytes(table: []const u8, offset: u64, length: u64) ?[]const u8 {
    if (offset > table.len or length > table.len - offset) return null;
    return table[@intCast(offset)..][0..@intCast(length)];
}

fn readU16(table: []const u8, offset: u64) ?u16 {
    const bytes = readBytes(table, offset, 2) orelse return null;
    return std.mem.readInt(u16, bytes[0..2], .big);
}

fn readU32(table: []const u8, offset: u64) ?u32 {
    const bytes = readBytes(table, offset, 4) orelse return null;
    return std.mem.readInt(u32, bytes[0..4], .big);
}

/// A `GPOS` table built by hand (206 bytes) that holds every shape `Kern`
/// reads: a `liga` feature naming a pair lookup that must NOT apply, a `kern`
/// feature naming its lookups out of order, a format 1 subtable that does not
/// have the pair (so the next subtable is asked), a format 2 subtable whose
/// value records carry an XPlacement before the XAdvance, coverage and class
/// definitions in both formats, and a second lookup behind a type 9 extension.
fn testTable() [206]u8 {
    // one row a section, each a comment then its 16-bit words
    const words =
        // header: version 1.0, script list, feature list, lookup list
        [_]i32{ 1, 0, 10, 12, 40 } ++
        // @10 script list: no scripts
        [_]i32{0} ++
        // @12 feature list: liga -> @26, kern -> @32
        [_]i32{ 2, 0x6C69, 0x6761, 14, 0x6B65, 0x726E, 20 } ++
        // @26 liga: lookup 2
        [_]i32{ 0, 1, 2 } ++
        // @32 kern: lookups 1, 0 (out of order)
        [_]i32{ 0, 2, 1, 0 } ++
        // @40 lookup list: @48, @58, @66
        [_]i32{ 3, 8, 18, 26 } ++
        // @48 lookup 0: pair, subtables @74 (format 1) and @112 (format 2)
        [_]i32{ 2, 0, 2, 26, 64 } ++
        // @58 lookup 1: extension, subtable @174
        [_]i32{ 9, 0, 1, 116 } ++
        // @66 lookup 2 (liga only): pair, subtable @74
        [_]i32{ 2, 0, 1, 8 } ++
        // @74 format 1: coverage @88, XAdvance only, pair sets @96 and @106
        [_]i32{ 1, 14, 4, 0, 2, 22, 32 } ++
        // @88 coverage format 1: glyphs 10, 20
        [_]i32{ 1, 2, 10, 20 } ++
        // @96 pair set for 10: 30 -> -50, 40 -> -25
        [_]i32{ 2, 30, -50, 40, -25 } ++
        // @106 pair set for 20: 30 -> 15
        [_]i32{ 1, 30, 15 } ++
        // @112 format 2: coverage @144, XPlacement + XAdvance, class defs @154 and @164, 2 x 2 classes
        [_]i32{ 2, 32, 5, 0, 42, 52, 2, 2 } ++
        // @128 class records [0][0], [0][1], [1][0], [1][1]
        [_]i32{ 0, 0, 0, 0, 0, 0, 7, -40 } ++
        // @144 coverage format 2: glyphs 10..12 from index 0
        [_]i32{ 2, 1, 10, 12, 0 } ++
        // @154 class def format 1: glyphs 11, 12 are class 1
        [_]i32{ 1, 11, 2, 1, 1 } ++
        // @164 class def format 2: glyphs 60..61 are class 1
        [_]i32{ 2, 1, 60, 61, 1 } ++
        // @174 extension format 1: type 2, 32-bit offset 8 -> @182
        [_]i32{ 1, 2, 0, 8 } ++
        // @182 format 1: coverage @194, XAdvance only, one pair set @200
        [_]i32{ 1, 12, 4, 0, 1, 18 } ++
        // @194 coverage format 1: glyph 10
        [_]i32{ 1, 1, 10 } ++
        // @200 pair set for 10: 30 -> -5
        [_]i32{ 1, 30, -5 };
    var bytes: [words.len * 2]u8 = undefined;
    for (words, 0..) |word, index| {
        const value: u16 = @truncate(@as(u32, @bitCast(word)));
        std.mem.writeInt(u16, bytes[index * 2 ..][0..2], value, .big);
    }
    return bytes;
}

const test_pairs = [_]struct { left: u32, right: u32, expected: i32 }{
    // format 1 in lookup 0 plus format 1 behind the extension in lookup 1
    .{ .left = 10, .right = 30, .expected = -55 },
    // format 1 in lookup 0 only; lookup 1 covers 10 but has no 40
    .{ .left = 10, .right = 40, .expected = -25 },
    .{ .left = 20, .right = 30, .expected = 15 },
    // format 2: class 1 by class 1, the XPlacement skipped
    .{ .left = 11, .right = 60, .expected = -40 },
    .{ .left = 12, .right = 61, .expected = -40 },
    // format 1 has no pair (10, 50), so format 2 is asked: class 0 by 0 is 0
    .{ .left = 10, .right = 50, .expected = 0 },
    // format 2, class 1 by class 0
    .{ .left = 11, .right = 30, .expected = 0 },
    // not covered anywhere
    .{ .left = 99, .right = 30, .expected = 0 },
    // past a glyph id GPOS can name
    .{ .left = 0x10000, .right = 30, .expected = 0 },
};

test "kern pairs from the kern feature's pair lookups, formats 1 and 2, through an extension" {
    const table = testTable();
    var kern = (try Kern.init(std.testing.allocator, &table)).?;
    defer kern.deinit(std.testing.allocator);
    for (test_pairs) |case| {
        errdefer std.debug.print("pair ({d}, {d})\n", .{ case.left, case.right });
        try std.testing.expectEqual(case.expected, kern.pair(case.left, case.right));
    }
}

test "a GPOS table without a kern feature has no kerning" {
    var table = testTable();
    // rename `kern` to `kerx`
    table[23] = 'x';
    try std.testing.expectEqual(null, try Kern.init(std.testing.allocator, &table));
    // and a table that is not GPOS 1.x
    var other = testTable();
    other[1] = 2;
    try std.testing.expectEqual(null, try Kern.init(std.testing.allocator, &other));
}

test "a damaged GPOS table answers, never reads past its end" {
    const whole = testTable();
    // every truncation
    for (0..whole.len + 1) |length| {
        const cut = try std.testing.allocator.dupe(u8, whole[0..length]);
        defer std.testing.allocator.free(cut);
        if (try Kern.init(std.testing.allocator, cut)) |found| {
            var kern = found;
            defer kern.deinit(std.testing.allocator);
            for (test_pairs) |case| _ = kern.pair(case.left, case.right);
        }
    }
    // every byte turned to 0xFF, then to 0x00
    for ([_]u8{ 0xFF, 0x00 }) |poison| {
        for (0..whole.len) |index| {
            var damaged = whole;
            damaged[index] = poison;
            if (try Kern.init(std.testing.allocator, &damaged)) |found| {
                var kern = found;
                defer kern.deinit(std.testing.allocator);
                for (test_pairs) |case| _ = kern.pair(case.left, case.right);
            }
        }
    }
}

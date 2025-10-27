const std = @import("std");

fn Alternative(comptime patterns: []const [:0]const u8) type {
    const P = @TypeOf(patterns[0]);
    comptime var sorted_patterns: [patterns.len]P = undefined;
    @memcpy(&sorted_patterns, patterns);
    std.mem.sort(P, &sorted_patterns, .{}, struct {
        pub fn lessThan(_: anytype, lhs: P, rhs: P) bool {
            const len = @min(lhs.len, rhs.len);
            for (lhs[0..len], rhs[0..len]) |l, r| if (l != r)
                return l < r;
            return lhs.len < rhs.len;
        }
    }.lessThan);
    const pats = sorted_patterns;

    comptime var init_enum_fields: [pats.len]std.builtin.Type.EnumField = undefined;
    for (&init_enum_fields, pats, 0..) |*ef, p, i|
        ef.* = .{ .name = p, .value = i };
    const enum_fields = init_enum_fields;

    const max_len, const min_len = init: {
        var _longest = pats[0].len;
        var _shortest = _longest;
        for (pats[1..]) |p| {
            _longest = @max(_longest, p.len);
            _shortest = @min(_shortest, p.len);
        }
        break :init .{_longest, _shortest};
    };

    const Flags = @Type(.{ .int = .{ .bits = pats.len, .signedness = .unsigned } });

    const CharInfo = struct {
        valid_start: bool = false,
        skip: u8 = pats[0].len,
    };
    const table_size = std.math.maxInt(u8) + 1;
    comptime var init_char_info = [table_size]CharInfo{.{}};

    comptime var init_offsets: [max_len]u8 = @splat(std.math.maxInt(u8));
    comptime var max_span: usize = 0;
    for (&init_offsets, 0..) |*offset, i| {
        for (pats) |p| if (i < p.len) {
            offset.* = @min(offset.*, p[i]);
        };
        for (pats) |p| max_span = @max(max_span, p[i] - offset.*);
    }

    const Masks = struct {
        offset: u8,
        masks: [max_span]Flags = .{0} ** max_span,
    };
    comptime var init_masks: Masks[max_len] = undefined;
    for (&init_masks, init_offsets) |*mask, offset| {
        mask.offset = offset;
    }
    for (pats, 0..) |p, p_idx| {
        for ((&init_masks)[0..p.len], p) |*mask, c| {
            const flag = 1 << p_idx;
            mask.masks[c - mask.offset] |= flag;
        }
    }

    const mask_table = init_masks;

    return struct {
        const Self = @This();

        const Pattern = @Type(.{
            .@"enum" = .{
                .fields = &enum_fields,
                .is_exhaustive = true,
                .decls = &.{},
                .tag_type = u8,
            },
        });

        flags: Flags = std.math.boolMask(Flags, true),
        col: usize = 0,

        fn reset(self: *Self) void {
            self.flags = std.math.boolMask(Flags, true);
            self.col = 0;
        }

        fn same(self: *Self, text: []const u8) usize {
            const l = @min(text.len, max_len - self.col);
            const s = self.col;
            const pos = for (text[0..l], mask_table[s..l], 0..) |c, masks, i| {
                const mask: Flags = masks.masks[c - masks.offset];
                if (self.flags & mask == 0) break i;
                self.flags &= mask;
            } else l;
            self.col += pos;
            return pos;
        }


    };
}

fn streamReplaceDelimiter(
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    delimiter: u8,
) !usize {
    return r.streamDelimiter(w, delimiter);
}


test "streaming replacement" {
    const test_text =
    \\<request name="sync">
    \\  &lt;description summary=&quote;asynchronous roundtrip&quote;&gt;
    \\    The sync request asks the server to emit the 'done' event...
    \\
    \\    The callback_data passed in the callback is undefined and should be
    \\    ignored.
    \\  &lt;/description&gt;
    \\  &lt;arg name=&quote;callback&quote; type=&quote;new_id&quote; interface=&quote;wl_callback&quote;
    \\       summary=&quote;callback object for the sync request&quote;/&gt;
    \\</request>
    ;
    var fixed_reader = std.Io.Reader.fixed(test_text);

    const expected =
    \\<request name="sync">
    \\  <description summary="asynchronous roundtrip">
    \\    The sync request asks the server to emit the 'done' event...
    \\
    \\    The callback_data passed in the callback is undefined and should be
    \\    ignored.
    \\  </description>
    \\  <arg name="callback" type="new_id" interface="wl_callback"
    \\       summary="callback object for the sync request"/>
    \\</request>
    ;

    const gpa = std.testing.allocator;
    var allocating_writer = std.Io.Writer.Allocating.init(gpa);
    defer allocating_writer.deinit();
    const writer = &allocating_writer.writer;

    var small_buffer: [10]u8 = undefined;
    var indirect = std.testing.ReaderIndirect.init(&fixed_reader, &small_buffer);
    const reader = &indirect.interface;
    _ = try reader.streamDelimiter(writer, '>');
    _ = try streamReplaceDelimiter(reader, writer, '<');
    _ = try reader.streamRemaining(writer);

    const actual = try allocating_writer.toOwnedSliceSentinel(0);
    try std.testing.expectEqualStrings(expected, actual);
}

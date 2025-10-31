const std = @import("std");

const Allocator = std.mem.Allocator;

const root = @import("root.zig");

fn MatchCursor(comptime patterns: []const [:0]const u8) type {
    const P = @TypeOf(patterns[0]);
    const Flags = @Type(.{ .int = .{ .bits = patterns.len, .signedness = .unsigned } });
    const by_length = (comptime init: {
        var res = root.copy(P, patterns);
        _ = root.sortDesc(.{ .field = "len" }, P, &res);
        break :init res;
    });

    const lengths = (comptime init: {
        var data = root.select(.{ .field = "len" }, usize, by_length.len, by_length);
        const deduped = root.dedupOn(.value, usize, &data);
        _ = root.sortDesc(.value, usize, deduped);
        var result: [deduped.len]struct { len: usize, flags: Flags } = undefined;
        var r_idx: usize = 0;
        result[r_idx] = .{.len = by_length[0].len, .flags = 1};
        for (by_length[1..], 1..) |pat, p_idx| {
            if (pat.len != result[r_idx].len) {
                r_idx += 1;
                result[r_idx] = .{.len = pat.len, .flags = 1 << p_idx};
            } else
                result[r_idx].flags |= 1 << p_idx;
        }
        break :init result;
    });

    comptime var init_table = [_]Flags{0} ** (std.math.maxInt(u8) + 1);
    for (by_length, 0..) |pat, p_idx| for (pat) |c| {
        init_table[c] |= 1 << p_idx;
    };
    const table = init_table;

    comptime var init_enum_fields: [by_length.len]std.builtin.Type.EnumField = undefined;
    for (&init_enum_fields, by_length, 0..) |*ef, p, i|
        ef.* = .{ .name = p, .value = i };
    const enum_fields = init_enum_fields;

    return struct {
        const Self = @This();
        pub const Pattern = @Type(.{
            .@"enum" = .{
                .fields = &enum_fields,
                .is_exhaustive = true,
                .decls = &.{},
                .tag_type = u8,
            },
        });

        len_confirmed: Flags = 0,
        char_confirmed: Flags = std.math.boolMask(Flags, true),
        cur: usize = 0,

        fn check(self: *Self, text: []const u8) void {
            inline for (1..lengths.len + 1) |offset| {
                const l = lengths[lengths.len - offset];
                const stop: usize = @min(l.len, text.len);
                const start: usize = @min(self.cur, stop);
                for (text[start..stop]) |c| {
                    self.char_confirmed &= table[c];
                    self.cur += 1;
                }
                if (self.cur < l.len) {
                    @branchHint(.unlikely);
                    return;
                }
                self.len_confirmed |= self.char_confirmed & l.flags;
                self.char_confirmed &= ~l.flags;
            }
        }

        pub const Result = union(enum) {
            // No pattern matched
            no_match,
            // All characters in the tested text match the beginning of a pattern
            possible_matches,
            // The pattern that matches the beginning of the tested text
            match: Pattern,
        };

        fn longest(self: *Self, text: []const u8) Result {
            self.check(text);
            // Look for long potentially unfinished matches first
            while (self.char_confirmed != 0) {
                const p_idx: u16 = @ctz(self.char_confirmed);
                const p_string = by_length[p_idx][0..self.cur];
                if (std.mem.eql(u8, p_string, text[0..p_string.len]))
                    return .possible_matches;
                self.char_confirmed &= switch (p_idx) {
                    inline 0 ... by_length.len - 1 => |idx| ~(@as(Flags, 1) << idx),
                    else => unreachable,
                };
            }

            // If there were no potentially longer matches pending
            while (self.len_confirmed != 0) {
                const p_idx: u16 = @ctz(self.len_confirmed);
                const p_string = by_length[p_idx];
                if (std.mem.eql(u8, p_string, text[0..p_string.len]))
                    return .{ .match = @enumFromInt(p_idx) };
                self.len_confirmed &= switch (p_idx) {
                    inline 0 ... by_length.len - 1 => |idx| ~(@as(Flags, 1) << idx),
                    else => unreachable,
                };
            }

            return .no_match;
        }
    };
}

const SkipTable = struct {
    const size: usize = std.math.maxInt(u8) + 1;
    min_len: u8,
    table: [size]u8,

    fn init(patterns: []const [:0]const u8) SkipTable {
        var self: SkipTable = .{
            .min_len = std.math.maxInt(u8),
            .table = undefined,
        };
        for (patterns) |p| self.min_len = @min(self.min_len, p.len);
        @memset(&self.table, self.min_len);
        for (patterns) |p| for (p[0 .. self.min_len - 1], 0..) |c, pos| {
            self.table[c] = @min(self.table[c], self.min_len - pos - 1);
        };
        return self;
    }

    fn skip(self: SkipTable, text: []const u8) usize {
        return self.table[text[self.min_len - 1]];
    }
};

const StreamCursor = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    data: []u8 = &.{},
    read: usize = 0,
    written: usize = 0,

    fn stream(self: *@This(), n: usize) !void {
        const bytes = self.data[0..n];
        self.written += try self.writer.write(bytes);
        self.read += n;
        self.reader.toss(n);
        self.data = self.data[n..];
    }

    fn replace(self: *@This(), n: usize, substitute: []const u8) !void {
        self.written += try self.writer.write(substitute);
        self.read += n;
        self.reader.toss(n);
        self.data = self.data[n..];
    }

    const ReaderState = enum{
        BufferFull,
        DelimiterReached,

    };

    const LoadError = error{
        /// More bytes could not be loaded because the buffer is full
        BufferFull,
        /// See the `Reader` implementation for detailed diagnostics.
        ReadFailed,
        EndOfStream,
    };

    fn loadToDelimiter(self: *@This(), delimiter: u8) LoadError!bool {
        const prev_len = self.data.len;
        if (self.reader.bufferedLen() == prev_len)
            try self.reader.fillMore();
        if (self.reader.bufferedLen() == prev_len)
            return error.BufferFull;

        const pos = std.mem.indexOfScalarPos(u8, self.reader.buffered(), prev_len, delimiter);
        self.data = if (pos) |p| self.reader.buffered()[0..p] else self.reader.buffered();
        return pos != null;
    }

    fn streamReplaceDelimiter(self: *@This(), delimiter: u8) !usize {
        const patterns: []const [:0]const u8 = &.{
            "&amp;", "&gt;", "&lt;", "&quote;", "&apos;"
        };
        const skip_table = SkipTable.init(patterns);
        var matcher = MatchCursor(patterns){};
        var delimiter_found = false;
        outer: while (!delimiter_found) {
            delimiter_found = try self.loadToDelimiter(delimiter);
            while (self.data.len >= skip_table.min_len) {
                switch (matcher.longest(self.data)) {
                    .no_match => {
                        const skip = skip_table.skip(self.data);
                        try self.stream(skip);
                        matcher = .{};
                    },
                    .possible_matches => {
                        @branchHint(.unlikely);
                        continue :outer;
                    },
                    .match => |pat| {
                        try self.replace(@tagName(pat).len, switch (pat) {
                            .@"&amp;" => "&",
                            .@"&gt;" => ">",
                            .@"&lt;" => "<",
                            .@"&quote;" => "\"",
                            .@"&apos;" => "'",
                        });
                        matcher = .{};
                    }
                }
            }
        }
        if (self.data.len > 0)
            try self.stream(self.data.len);
        return self.read;
    }
};

fn streamReplaceDelimiter(
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    delimiter: u8,
) !usize {
    var cursor: StreamCursor = .{ .reader = r, .writer = w };
    return cursor.streamReplaceDelimiter(delimiter);
}

test "streaming replacement" {
    const test_text =
        \\<request name="sync">
        \\  &lt;description summary=&quote;asynchronous roundtrip&quote;&gt;
        \\    The sync request asks the server to emit the &apos;done&apos; event...
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
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

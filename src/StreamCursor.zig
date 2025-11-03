const std = @import("std");
const root = @import("root.zig");


fn Cursor(comptime AreaLimit: type) type {
    return struct {
        const Self = @This();
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        /// Bytes read from the reader
        read: usize = 0,
        /// Bytes written to the writer
        written: usize = 0,
        /// The currently loaded operation area
        op_area: []u8 = &.{},
        area_limit: AreaLimit,

        fn replace(self: *Self, n: usize, substitute: []const u8) !void {
            self.written += try self.writer.write(substitute);
            self.read += n;
            self.reader.toss(n);
            self.op_area = self.op_area[n..];
        }

        fn stream(self: *Self, n: usize) !void {
            const bytes = self.op_area[0..n];
            return self.replace(bytes.len, bytes);
        }

        fn load(self: *Self) LoadError!bool {
            const prev_len = self.op_area.len;
            if (self.reader.bufferedLen() == prev_len)
                try self.reader.fillMore();
            if (self.reader.bufferedLen() == prev_len)
                return error.BufferFull;

            const pos = self.area_limit.nextPos(self.reader.buffered(), prev_len);
            self.op_area = self.reader.buffered()[0..pos];
            return self.op_area.len != self.reader.bufferedLen();
        }

        fn streamToNext(self: *Self, comptime Tokenizer: type) !?Tokenizer.Token {
            var limit_reached = false;
            var tokenizer = Tokenizer{};
            var token = tokenizer.next(self.data, 0);
            while (!limit_reached and token == null) {
                const pos = tokenizer.nextPos(self.data, 0);
                try self.stream(pos);
                limit_reached = try self.load();
                token = tokenizer.next(self.data, 0);
            }
            if (token == null) {
                const pos = tokenizer.nextPos(self.data, 0);
                try self.stream(pos);
                token = tokenizer.next(self.data, 0);
            }
            return token;
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

const LoadError = error{
    /// More bytes could not be loaded because the buffer is full
    BufferFull,
    /// See the `Reader` implementation for detailed diagnostics.
    ReadFailed,
    EndOfStream,
};

pub fn Delimiters(comptime delimiters: []const u8) type {
    return struct {
        const Token = u8;
        fn nextPos(_: Delimiters, buffer: []const u8, pos: usize) usize {
            return switch (delimiters.len) {
                inline 0 => null,
                inline 1 => std.mem.indexOfScalarPos(u8, buffer, pos, delimiters[0]),
                else => std.mem.indexOfAnyPos(u8, buffer, pos, delimiters),
            } orelse buffer.len;
        }

        fn next(_: Delimiters, buffer: []const u8, pos: usize) ?Token {
            if (buffer.len <= pos) return null;
            if (std.mem.indexOf(u8, delimiters, buffer[pos])) |i|
                return delimiters[i];
            return null;
        }
    };
}

pub fn Patterns(comptime patterns: []const [:0]const u8) type {
    const P = @TypeOf(patterns[0]);
    const Flags = @Type(.{ .int = .{ .bits = patterns.len, .signedness = .unsigned } });
    comptime var init_by_length = root.copy(P, patterns);
    _ = root.sortDesc(.{ .field = "len" }, P, &init_by_length);

    comptime var init_lengths: [root.uniques(.{ .field = "len" }, &init_by_length)]struct {
        len: usize,
        flags: Flags,
    } = undefined;
    {
        comptime var r_idx: usize = 0;
        init_lengths[r_idx] = .{ .len = init_by_length[0].len, .flags = 1 };
        for (init_by_length[1..], 1..) |pat, p_idx| {
            if (pat.len != init_lengths[r_idx].len) {
                r_idx += 1;
                init_lengths[r_idx] = .{ .len = pat.len, .flags = 1 << p_idx };
            } else init_lengths[r_idx].flags |= 1 << p_idx;
        }
    }

    comptime var init_table = [_]Flags{0} ** (std.math.maxInt(u8) + 1);
    for (init_by_length, 0..) |pat, p_idx| for (pat) |c| {
        init_table[c] |= 1 << p_idx;
    };

    comptime var init_first_chars: [init_by_length.len]u8 = undefined;
    comptime var first_chars_count: usize = 0;
    for (init_by_length) |pat| {
        if (null == std.mem.indexOf(u8, init_first_chars[0..first_chars_count], pat[0])) {
            init_first_chars[first_chars_count] = pat[0];
            first_chars_count += 1;
        }
    }

    comptime var init_enum_fields: [init_by_length.len]std.builtin.Type.EnumField = undefined;
    for (&init_enum_fields, init_by_length, 0..) |*ef, p, i|
        ef.* = .{ .name = p, .value = i };
    const enum_fields = init_enum_fields;

    return struct {
        const by_length = init_by_length;
        const length_table = init_lengths;
        const char_table = init_table;
        const skip_table = SkipTable.init(init_by_length);
        const first_chars: [first_chars_count]u8 = init_first_chars[0..first_chars_count];
        pub const Token = @Type(.{
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

        fn check(self: *@This(), text: []const u8) void {
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
            match: Token,
        };

        fn longest(self: *@This(), text: []const u8) Result {
            self.check(text);
            // Look for long potentially unfinished matches first
            while (self.char_confirmed != 0) {
                const p_idx: u16 = @ctz(self.char_confirmed);
                const p_string = by_length[p_idx][0..self.cur];
                if (std.mem.eql(u8, p_string, text[0..p_string.len]))
                    return .possible_matches;
                self.char_confirmed &= switch (p_idx) {
                    inline 0...by_length.len - 1 => |idx| ~(@as(Flags, 1) << idx),
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
                    inline 0...by_length.len - 1 => |idx| ~(@as(Flags, 1) << idx),
                    else => unreachable,
                };
            }

            return .no_match;
        }

        fn skip(self: *@This(), text: []const u8) usize {
            var pos = 0;
            while (text.len - pos >= skip_table.min_len) {
                pos += skip_table.skip(text);
                if (std.mem.indexOf(u8, &first_chars, text[pos])) |_| return pos;
            }
            while (text.len - pos > 0) : (pos += 1)
                if (std.mem.indexOf(u8, &first_chars, text[pos])) |_| return pos;
            return pos;
        }

        pub fn nextPos(self: *@This(), buffer: []const u8, pos: usize) usize {
            var _pos = pos;
            var text = buffer[_pos..];
            while (text.len > 0) : (text = buffer[_pos..]) {
                switch (self.longest(text)) {
                    .no_match => {
                        _pos += self.skip(text);
                        self.* = .{};
                    },
                    .possible_matches, .match => return _pos,
                }
            }
            return _pos;
        }

        pub fn next(self: *@This(), buffer: []const u8, pos: usize) ?Token {
            return switch (self.longest(buffer[pos..])) {
                .no_match, .possible_matches => null,
                .match => |token| token,
            };
        }
    };
}



// fn streamToPattern(self: *@This(), comptime patterns: []const [:0]const u8) !

// fn streamReplaceDelimiter(self: *@This(), delimiter: u8) !usize {
//     const patterns: []const [:0]const u8 = &.{
//         "&amp;", "&gt;", "&lt;", "&quote;", "&apos;"
//     };
//     const skip_table = SkipTable.init(patterns);
//     var matcher = MatchCursor(patterns){};
//     var delimiter_found = false;
//     outer: while (!delimiter_found) {
//         delimiter_found = try self.loadToDelimiter(delimiter);
//         while (self.data.len >= skip_table.min_len) {
//             switch (matcher.longest(self.data)) {
//                 .no_match => {
//                     const skip = skip_table.skip(self.data);
//                     try self.stream(skip);
//                     matcher = .{};
//                 },
//                 .possible_matches => {
//                     @branchHint(.unlikely);
//                     continue :outer;
//                 },
//                 .match => |pat| {
//                     try self.replace(@tagName(pat).len, switch (pat) {
//                         .@"&amp;" => "&",
//                         .@"&gt;" => ">",
//                         .@"&lt;" => "<",
//                         .@"&quote;" => "\"",
//                         .@"&apos;" => "'",
//                     });
//                     matcher = .{};
//                 }
//             }
//         }
//     }
//     if (self.data.len > 0)
//         try self.stream(self.data.len);
//     return self.read;
// }

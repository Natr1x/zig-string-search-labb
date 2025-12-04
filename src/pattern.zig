const std = @import("std");
const assert = std.debug.assert;
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;

const VECTOR_SIZE = 32;
const Block = @Vector(VECTOR_SIZE, u8);
const PosMask = std.bit_set.IntegerBitSet(32);

const Pattern = struct {
    const Self = @This();
    index: usize,
    content: []const u8,

    fn collection(comptime C: usize, items: *const [C][:0]const u8) [C]Self {
        var result: [C]Self = undefined;
        for (&result, items, 0..) |*dst, item, i| {
            dst.* = .{ .index = i, .content = item };
        }
        std.mem.sort(Self, &result, {}, struct {
            pub fn lessThan(_: void, lhs: Self, rhs: Self) bool {
                const len = @min(lhs.content.len, rhs.content.len);
                return for (lhs.content[0..len], rhs.content[0..len]) |l, r| {
                    if (l != r) break l < r;
                } else lhs.content.len < rhs.content.len;
            }
        }.lessThan);
        return result;
    }

    pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.print("{s} {{ index: {d}, content: '{s}' }}", .{
            @typeName(Self),
            self.index,
            self.content,
        });
    }

};

fn init_patterns(patterns: []Pattern, pat_strings: []const []const u8) struct {
    prefix_len: usize,
    unique_first_letters: usize,
    unique_prefixes: usize,
} {
    assert(patterns.len != 0 and pat_strings.len != 0);
    assert(patterns.len == pat_strings.len);

    var prefix_len = std.math.maxInt(usize);
    for (patterns, pat_strings, 0..) |*dst, src, i| {
        prefix_len = @min(prefix_len, src.len);
        dst.* = .{ .index = i, .content = src };
    }
    std.mem.sort(Pattern, patterns, {}, struct {
        pub fn lessThan(_: void, lhs: Pattern, rhs: Pattern) bool {
            const len = @min(lhs.content.len, rhs.content.len);
            return for (lhs.content[0..len], rhs.content[0..len]) |l, r| {
                if (l != r) break l < r;
            } else lhs.content.len < rhs.content.len;
        }
    }.lessThan);

    var unique_first_letters: usize = 1;
    var unique_prefixes: usize = 1;
    var previous = patterns[0].content[0..prefix_len];
    for (patterns[1..]) |pattern| {
        const current = pattern.content[0..prefix_len];
        unique_first_letters += @intFromBool(previous[0] != current[0]);
        unique_prefixes += @intFromBool(!eql(u8, previous, current));
        previous = current;
    }
    return .{
        .prefix_len = prefix_len,
        .unique_first_letters = unique_first_letters,
        .unique_prefixes = unique_prefixes,
    };
}

const FirstLetter = struct { letter: u8, count: usize };
const Prefix = struct { content: []const u8, count: usize };

fn init_prefix_stats(
    _first_letters: []FirstLetter,
    _prefixes: []Prefix,
    _prefix_len: usize,
    initialized_patterns: []const Pattern,
) void {
    assert(initialized_patterns.len >= _prefixes.len);
    assert(_prefixes.len >= _first_letters.len);

    var previous = initialized_patterns[0].content[0.._prefix_len];
    var first_letter_idx = 0;
    var prefix_idx = 0;
    _first_letters[first_letter_idx] = .{ .letter = previous[0], .count = 1 };
    _prefixes[prefix_idx] = .{ .content = previous, .count = 1 };

    for (initialized_patterns[1..]) |pattern| {
        const current = pattern.content[0.._prefix_len];
        if (previous[0] != current[0]) {
            first_letter_idx += 1;
            _first_letters[first_letter_idx] = .{ .letter = current[0], .count = 0 };
        }
        if (!eql(u8, previous, current)) {
            prefix_idx += 1;
            _prefixes[prefix_idx] = .{ .content = current, .count = 0 };
        }
        _first_letters[first_letter_idx].count += 1;
        _prefixes[prefix_idx].count += 1;
        previous = current;
    }
}

const Collection = struct {
    const Self = @This();

    prefix_len: usize,
    first_letters: []const FirstLetter,
    prefixes: []const Prefix,
    patterns: []const Pattern,


    /// Creates a new pattern collection from a slice of strings using.
    ///
    /// **OBS:** The created collection needs to be deinitialized with
    /// `deinit` using the same allocator in order to not leak memory.
    pub fn allocate(allocator: Allocator, pattern_strings: []const []const u8) error{OutOfMemory}!Self {
        const _patterns = try allocator.alloc(Pattern, pattern_strings.len);
        errdefer allocator.free(_patterns);
        const stats = init_patterns(_patterns, pattern_strings);

        const _first_letters = try allocator.alloc(FirstLetter, stats.unique_first_letters);
        errdefer allocator.free(_first_letters);
        const _prefixes = try allocator.alloc(Prefix, stats.unique_prefixes);
        errdefer allocator.free(_prefixes);
        init_prefix_stats(_first_letters, _prefixes, stats.prefix_len, _patterns);
        return Self {
            .prefix_len = stats.prefix_len,
            .first_letters = _first_letters,
            .prefixes = _prefixes,
            .patterns = _patterns,
        };
    }

    /// Deinitialize this collection, `allocator` should be the same as was
    /// used to create it.
    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.prefixes);
        allocator.free(self.first_letters);
        allocator.free(self.patterns);
        self.* = undefined;
    }

};

fn pattern_collection(comptime pattern_strings: []const []const u8) Collection {
    const n: usize = pattern_strings.len;
    comptime var _patterns: [n]Pattern = undefined;
    const stats = comptime init_patterns(&_patterns, pattern_strings);
    const patterns = _patterns;
    comptime var _first_letters: [stats.unique_first_letters]FirstLetter = undefined;
    comptime var _prefixes: [stats.unique_prefixes]Prefix = undefined;
    comptime init_prefix_stats(&_first_letters, &_prefixes, stats.prefix_len, &patterns);
    const first_letters = _first_letters;
    const prefixes = _prefixes;
    return .{
        .prefix_len = stats.prefix_len,
        .first_letters = &first_letters,
        .prefixes = &prefixes,
        .patterns = &patterns,
    };
}

test "does comptime works like this" {
    std.debug.print("\n", .{});
    const patterns = pattern_collection(&.{
        "hejsan", "svejsan", "på dejsan"
    });

    const patterns2 = pattern_collection(&.{
        "generical",
        "eric insta",
        "generic instance",
        "av",
        "hghhgh",
    });

    try std.testing.expectEqual(2, patterns2.prefix_len);
    try std.testing.expectEqual(6, patterns.prefix_len);

    std.debug.print("patterns2 prefixes:\n", .{});
    var expect: []const []const u8 = &.{
        "av", "er", "ge", "hg",
    };
    for (expect, patterns2.prefixes) |expected, prefix| {
        std.debug.print("\"{s}\",\n", .{prefix.content});
        try std.testing.expectEqualStrings(expected, prefix.content);
    }

    std.debug.print("patterns prefixes:\n", .{});
    expect = &.{
        "hejsan", "på de", "svejsa",
    };
    for (expect, patterns.prefixes) |expected, prefix| {
        std.debug.print("\"{s}\",\n", .{prefix.content});
        try std.testing.expectEqualStrings(expected, prefix.content);
    }

}


fn PatternPrefix(comptime N: usize) type {
    return struct {
        const Self = @This();

        first_letter: Block,
        last_letter: Block,
        inner: *const [N - 2]u8,
        pat_count: usize,

        fn match(self: Self, haystack: *const [VECTOR_SIZE + N]u8) PosMask {
            const first_block: Block = haystack[0..VECTOR_SIZE].*;
            const last_block: Block = haystack[N - 1..][0..VECTOR_SIZE].*;
            const eq_first = self.first_letter == first_block;
            const eq_last = self.last_letter == last_block;
            var maybe_pos = PosMask { .mask = @bitCast(eq_first & eq_last) };
            var confirmed_pos = PosMask { .mask = 0 };
            while (maybe_pos.findFirstSet()) |bitpos| : (maybe_pos.unset(bitpos)) {
                const candidate = haystack[bitpos + 1 ..][0 .. self.inner.len];
                if (eql(u8, self.inner, candidate)) {
                    confirmed_pos.set(bitpos);
                }
            }
            return confirmed_pos;
        }

        fn PrefixBuf(comptime C: usize) type {
            return struct {
                buf: [C]Self,
                len: usize,
                fn items(self: *const @This()) []const Self {
                    return self.buf[0..self.len];
                }
            };
        }

        fn new(pattern: *const [N]u8, count: usize) Self {
            std.debug.print("{s}.new(pattern: '{s}', count: {d})\n", .{
                @typeName(Self), pattern, count
            });
            return .{
                .first_letter = @splat(pattern[0]),
                .last_letter = @splat(pattern[N - 1]),
                .inner = pattern[1..N - 1],
                .pat_count = count,
            };
        }

        /// Assumes that `patterns` are from `Pattern.collection` (ie sorted)
        fn create_buffer(comptime C: usize, patterns: *const [C]Pattern) PrefixBuf(C) {
            if (C == 0)
                @compileError("`patterns` needs to contain at least one pattern");

            var result = PrefixBuf(C) { .buf = undefined, .len = 0 };
            var current = patterns[0].content[0..N];
            var count: usize = 1;
            for (patterns[1..]) |pattern| {
                const next = pattern.content[0..N];
                if (eql(u8, current, next)) {
                    count += 1;
                } else {
                    result.buf[result.len] = .new(current, count);
                    std.debug.print("[{d}] {f}\n", .{result.len, result.buf[result.len]});
                    result.len += 1;
                    count = 1;
                    current = next;
                }
            }
            result.buf[result.len] = .new(current, count);
            std.debug.print("[{d}] {f}\n", .{result.len, result.buf[result.len]});
            result.len += 1;

            return result;
        }

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return writer.print("{s} {{ prefix: '{c}{s}{c}', count: {d} }}", .{
                @typeName(Self),
                self.first_letter[0],
                self.inner,
                self.last_letter[0],
                self.pat_count,
            });
        }

    };
}

fn min_len(comptime T: type, items: []const T) usize {
    var len = items[0].len;
    for (items[1..]) |item| { len = @min(len, item.len); }
    return len;
}

fn findFirst(comptime needles: []const [:0]const u8, haystack: []const u8) ?struct {usize, usize} {
    const C = needles.len;
    const _needles = needles[0..C];
    const N = comptime min_len([:0]const u8, _needles);
    const PPrefix = PatternPrefix(N);
    const patterns = Pattern.collection(C, _needles);
    const prefixes = PPrefix.create_buffer(C, &patterns);

    std.debug.print("Patterns:\n", .{});
    for (patterns) |pattern| {
        std.debug.print("  {f}\n", .{pattern});
    }

    std.debug.print("Prefixes:\n", .{});
    for (prefixes.items()) |prefix| {
        std.debug.print("  {f}\n", .{prefix});
    }

    var result: struct {
        value: ?struct {usize, usize},
        fn set(self: *@This(), pos: usize, index: usize) void {
            std.debug.print("Candidate at pos: {d}, index: {d} '{s}'\n", .{
                pos, index, needles[index]
            });
            const old_pos, const old_index = self.value orelse .{pos, index};
            if ((pos == old_pos and index <= old_index) or pos < old_pos)
                self.value = .{pos, index};
        }
    } = .{ .value = null };

    var i: usize = 0;
    while (i + N + VECTOR_SIZE < haystack.len) : (i += VECTOR_SIZE) {
        const remaining = haystack[i..];
        var pat_index: usize = 0;
        prefix_loop: for (prefixes.items()) |prefix| {
            const prefix_pats = patterns[pat_index..][0..prefix.pat_count];
            pat_index += prefix.pat_count;
            var prefix_matches = prefix.match(remaining[0.. VECTOR_SIZE + N]);
            while (prefix_matches.findFirstSet()) |bitpos| : (prefix_matches.unset(bitpos)) {
                const suffix = remaining[bitpos + N..];
                for (prefix_pats) |pat| {
                    const pat_suffix = pat.content[N..];
                    if (suffix.len < pat_suffix.len) continue;
                    if (!eql(u8, pat_suffix, suffix[0..pat_suffix.len])) continue;
                    result.set(i + bitpos, pat.index);
                    continue :prefix_loop;
                }
            }
        }
        if (result.value) |value| return value;
    }

    return result.value;
}


test "findFirst finds values in correct order" {
    const testing = std.testing;
    std.debug.print("\n", .{});
    const test_data =
        \\ Debug Options (Zig Compiler Development):
        \\   -fopt-bisect-limit=[limit]   Only run [limit] first LLVM optimization passes
        \\   -fstack-report               Print stack size diagnostics
        \\   --verbose-link               Display linker invocations
        \\   --verbose-cc                 Display C compiler invocations
        \\   --verbose-air                Enable compiler debug output for Zig AIR
        \\   --verbose-intern-pool        Enable compiler debug output for InternPool
        \\   --verbose-generic-instances  Enable compiler debug output for generic instance generation
        \\   --verbose-llvm-ir[=path]     Enable compiler debug output for unoptimized LLVM IR
        \\   --verbose-llvm-bc=[path]     Enable compiler debug output for unoptimized LLVM BC
        \\   --verbose-cimport            Enable compiler debug output for C imports
        \\   --verbose-llvm-cpu-features  Enable compiler debug output for LLVM CPU features
        \\   --debug-log [scope]          Enable printing debug/info log messages for scope
        \\   --debug-compile-errors       Crash with helpful diagnostics at the first compile error
        \\   --debug-link-snapshot        Enable dumping of the linker's state in JSON format
        ;
    const patterns: []const [:0]const u8 = &.{
        "generical",
        "eric insta",
        "generic instance",
        "hejsan",
        "svejsan",
    };

    const pos, const index = findFirst(patterns, test_data).?;
    try testing.expectEqual(2, index);
    const expect = patterns[index];
    const actual = test_data[pos..][0..expect.len];
    try testing.expectEqualStrings(expect, actual);
}


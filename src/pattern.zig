const std = @import("std");
const assert = std.debug.assert;
const eql = std.mem.eql;

const VECTOR_SIZE = 32;
const Block = @Vector(VECTOR_SIZE, u8);
const PosMask = std.bit_set.IntegerBitSet(32);

const Pattern = struct {
    const Self = @This();
    index: usize,
    content: [:0]const u8,

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

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.print("{s} {{ index: {d}, content: '{s}' }}", .{
            @typeName(Self),
            self.index,
            self.content,
        });
    }

};

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
            while (maybe_pos.findFirstSet()) |bitpos| {
                const candidate = haystack[bitpos + 1 ..][0 .. self.inner.len];
                if (eql(u8, self.inner, candidate)) {
                    confirmed_pos.set(bitpos);
                }
                maybe_pos.unset(bitpos);
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
    const Prefix = PatternPrefix(N);
    const patterns = Pattern.collection(C, _needles);
    const prefixes = Prefix.create_buffer(C, &patterns);

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
            while (prefix_matches.findFirstSet()) |bitpos| {
                prefix_matches.unset(bitpos);
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


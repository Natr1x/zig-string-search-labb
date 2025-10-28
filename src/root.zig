//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const CompareOperator = std.math.CompareOperator;

pub const Mapper = union(enum) {
    field: []const u8,
    getter: []const u8,
    value,

    pub fn cmp(comptime mapper: Mapper, comptime op: CompareOperator, lhs: anytype, rhs: anytype) bool {
        const lhs_val, const rhs_val = switch (mapper) {
            inline .field => |f| .{ @field(lhs, f), @field(rhs, f) },
            inline .getter => |g| .{ @field(lhs, g)(lhs), @field(rhs, g)(rhs) },
            inline .value => .{ lhs, rhs },
        };
        return std.math.compare(lhs_val, op, rhs_val);
    }
};

/// Sort a slice on a Mapper (in descending order)
pub fn sortDesc(comptime mapper: Mapper, comptime T: type, items: []T) []T {
    std.mem.sort(T, items, {}, struct {
        pub fn lessThan(_: void, lhs: T, rhs: T) bool {
            return mapper.cmp(.gt, lhs, rhs);
        }
    }.lessThan);
    return items;
}

/// Sort a slice on a Mapper (in ascending order)
pub fn sortAsc(comptime mapper: Mapper, comptime T: type, items: []T) []T {
    std.mem.sort(T, items, {}, struct {
        pub fn lessThan(_: void, lhs: T, rhs: T) bool {
            return mapper.cmp(.lt, lhs, rhs);
        }
    }.lessThan);
    return items;
}

pub fn select(comptime mapper: Mapper, comptime T: type, comptime len: usize, items: anytype) [len]T {
    var result: [len]T = undefined;
    for (&result, items[0..len]) |*r, item| r.* = switch (mapper) {
        inline .field => |f| @field(item, f),
        inline .getter => |g| @field(item, g)(item),
        inline .value => item,
    };
    return result;
}

/// Deduplicates on a Mapper by swap removing, the `items` must be sorted.
pub fn dedupOn(comptime mapper: Mapper, T: type, items: []T) []T {
    var result = items;
    var idx: usize = 1;
    while (idx < result.len) {
        if (mapper.cmp(.eq, result[idx - 1], result[idx])) {
            std.mem.swap(T, &result[idx], &result[result.len - 1]);
            result = result[0 .. result.len - 1];
        } else idx += 1;
    }
    return result;
}

pub fn copy(comptime T: type, comptime items: []const T) [items.len]T {
    var result: [items.len]T = undefined;
    @memcpy(&result, items);
    return result;
}

test "ashedtio" {
    try std.testing.expectEqual(65535, std.math.maxInt(u16));
}

test "If we can instantiate new arrays through dereferencing" {
    const patterns: []const [:0]const u8 = &.{
        "&amp;", "&gt;", "&lt;", "&quote;", "&apos;", "12345"
    };

    const P = @TypeOf(patterns[0]);
    const by_length = comptime init: {
        var res = copy(P, patterns);
        _ = sortAsc(.{ .field = "len" }, P, &res);
        break :init res;
    };
    const lengths = (comptime init: {
        var vals = select(.{ .field = "len" }, usize, by_length.len, &by_length);
        break :init copy(usize, sortAsc(.value, usize, dedupOn(.value, usize, &vals)));
    });
    try std.testing.expectEqualSlices(usize, &.{ 4, 5, 6, 7 }, &lengths);
}

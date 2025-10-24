const std = @import("std");


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

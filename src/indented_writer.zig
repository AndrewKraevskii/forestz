const std = @import("std");
const io = std.io;

/// Prints `indent_level` spaces before first write and before any write
pub fn IndentedWriter(comptime WriterType: type) type {
    return struct {
        child_writer: WriterType,
        need_to_indent: bool = true,
        indent_level: usize,

        pub const Error = WriterType.Error;
        pub const Writer = io.Writer(*Self, Error, write);

        const Self = @This();

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            if (bytes.len == 0) return 0;

            if (self.need_to_indent) {
                for (0..self.indent_level) |_| {
                    _ = try self.child_writer.write(" ");
                }
                self.need_to_indent = false;
            }
            var rest = bytes[0..];
            var written: usize = 0;
            while (rest.len != 0) {
                const index = std.mem.indexOfScalar(u8, rest, '\n') orelse {
                    return try self.child_writer.write(rest) + written;
                };
                written += try self.child_writer.write(rest[0 .. index + 1]);
                self.need_to_indent = true;
                if (rest.len > index + 1) {
                    for (0..self.indent_level) |_| {
                        _ = try self.child_writer.write(" ");
                    }
                    rest = rest[index + 1 ..];
                } else break;
            }
            return written;
        }
    };
}

pub fn indentedWriter(indent: usize, child_writer: anytype) IndentedWriter(@TypeOf(child_writer)) {
    return .{
        .indent_level = indent,
        .child_writer = child_writer,
    };
}

test "No indent" {
    var buffer: std.ArrayList(u8) = .init(std.testing.allocator);
    defer buffer.deinit();

    var indented_writer = indentedWriter(0, buffer.writer());
    try indented_writer.writer().print("Hello\nworld!\n", .{});

    try std.testing.expectEqualSlices(u8, "Hello\nworld!\n", buffer.items);
}

test "Some indent" {
    var buffer: std.ArrayList(u8) = .init(std.testing.allocator);
    defer buffer.deinit();

    var indented_writer = indentedWriter(2, buffer.writer());
    try indented_writer.writer().print("Hello\nworld!\n", .{});

    const expected =
        \\  Hello
        \\  world!
        \\
    ;
    try std.testing.expectEqualSlices(u8, expected, buffer.items);
}

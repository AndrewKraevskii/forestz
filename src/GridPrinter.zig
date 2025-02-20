const std = @import("std");
const GridPrinter = @This();

columns_size: []u8,
buffer: std.ArrayListUnmanaged(u8),
cells: std.ArrayListUnmanaged(u8),
padding: u8,
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, columns: u8, padding: u8) std.mem.Allocator.Error!GridPrinter {
    const column_sizes = try gpa.alloc(u8, columns);
    @memset(column_sizes, 0);
    return .{
        .columns_size = column_sizes,
        .buffer = .empty,
        .cells = .empty,
        .padding = padding,
        .gpa = gpa,
    };
}

pub fn print(self: *GridPrinter, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
    const start = self.buffer.items.len;
    try self.buffer.writer(self.gpa).print(fmt, args);
    const size: u8 = @intCast(self.buffer.items.len - start);

    const current_columnt = self.cells.items.len % self.columns_size.len;

    self.columns_size[current_columnt] = @max(size, self.columns_size[current_columnt]);

    try self.cells.append(self.gpa, size);
}

pub fn flush(self: *GridPrinter, writer: anytype) !void {
    defer {
        self.buffer.clearRetainingCapacity();
        self.cells.clearRetainingCapacity();
        @memset(self.columns_size, 0);
    }
    var i: usize = 0;
    var start: usize = 0;
    while (true) {
        for (self.columns_size, 0..) |column, index| {
            if (i == self.cells.items.len) return;
            defer i += 1;

            const end = start + self.cells.items[i];
            defer start = end;

            const string = self.buffer.items[start..end];
            try writer.writeAll(string);

            const last_column = self.columns_size.len == index + 1;

            try writer.writeByteNTimes(' ', column - string.len + if (last_column) 0 else self.padding);
        }
        try writer.writeByte('\n');
    }
}

pub fn lineBreak(self: *GridPrinter) std.mem.Allocator.Error!void {
    const written_columns = self.cells.items.len % self.columns_size.len;
    try self.cells.appendNTimes(self.gpa, 0, self.columns_size.len - written_columns);
}

pub fn deinit(self: *GridPrinter) void {
    self.buffer.deinit(self.gpa);
    self.cells.deinit(self.gpa);
    self.gpa.free(self.columns_size);
}

test GridPrinter {
    var printer = try init(std.testing.allocator, 2, 1);
    defer printer.deinit();

    try printer.print("a", .{});
    try printer.print("{d}", .{1});
    try printer.print("{d}", .{10000});
    try printer.print("*", .{});
    try printer.print("***", .{});

    var buffer: [10000]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try printer.flush(fbs.writer());

    try std.testing.expectEqualSlices(u8,
        \\a     1
        \\10000 *
        \\***   
    , fbs.buffer[0..fbs.pos]);
}

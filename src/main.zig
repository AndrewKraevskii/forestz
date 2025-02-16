const std = @import("std");

const tree = @import("tree.zig");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);

    if (args.len == 0) {
        @panic("no program path given");
    }

    var config: tree.Config = .{
        .print_files = false,
    };
    var path: []const u8 = ".";

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--files") or std.mem.eql(u8, arg, "-f")) {
            config.print_files = true;
        } else {
            path = arg;
        }
    }

    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    try tree.printZigFiles(gpa, dir);
}

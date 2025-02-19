const std = @import("std");

const getDependencyTree = @import("tree.zig").getDependencyTree;
const Tree = @import("tree.zig").Tree;
const loc = @import("loc.zig");
const indentedWriter = @import("indented_writer.zig").indentedWriter;

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

    var path: []const u8 = ".";

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--files") or std.mem.eql(u8, arg, "-f")) {
            // config.print_files = true;
        } else {
            path = arg;
        }
    }

    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    const tree = try getDependencyTree(arena, gpa, dir);

    try printDependency(gpa, tree.root, 0, .{
        .print_files = true,
        .print_total_for_project = true,
    });
}

fn printDependency(
    gpa: std.mem.Allocator,
    dep: Tree.Dependency,
    indent: u16,
    config: struct {
        print_files: bool = false,
        print_total_for_project: bool = false,
        // sort_by: enum {
        //     name,
        //     lines,
        //     code,
        //     comments,
        //     blanks,
        // } = .name,
    },
) !void {
    const stdout = std.io.getStdOut().writer();
    var writer_state = indentedWriter(indent, stdout);
    const writer = writer_state.writer();

    for (dep.children) |child| {
        var dep_root_dir = try std.fs.openDirAbsolute(child.dependency.absolute_path, .{
            .iterate = true,
        });
        defer dep_root_dir.close();

        const total_text = "total stats";

        const max_len = max_len: {
            var max_len: usize = total_text.len;
            if (config.print_files) {
                var iter = dep_root_dir.iterateAssumeFirstIteration();
                while (try iter.next()) |entry| {
                    if (entry.kind != .file) continue;
                    max_len = @max(max_len, entry.name.len);
                }
            }
            break :max_len max_len;
        };
        try writer.print("{s}", .{child.import_name});
        if (config.print_files or config.print_total_for_project) {
            try writer.writeByteNTimes(' ', max_len);
            try writer.print(" lines    code     comments blanks\n", .{});
        }
        var iter = dep_root_dir.iterate();
        var total_stats: loc.Stats = .empty;
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const file_content = try dep_root_dir.readFileAlloc(gpa, entry.name, 1000 * 1000 * 1000);
            defer gpa.free(file_content);
            const stats = loc.statsFromSlice(file_content);
            if (config.print_files) {
                try writer.print("{s}", .{entry.name});
                try writer.writeByteNTimes(' ', max_len - entry.name.len + 1);
                try writer.print("{d:<8} {d:<8} {d:<8} {d:<8}\n", .{ stats.lines, stats.code, stats.comments, stats.blanks });
            }
            total_stats = total_stats.add(stats);
        }
        if (config.print_total_for_project) {
            try writer.print(total_text, .{});
            try writer.writeByteNTimes(' ', max_len - "total stats".len + 1);
            try writer.print("{d:<8} {d:<8} {d:<8} {d:<8}\n", .{ total_stats.lines, total_stats.code, total_stats.comments, total_stats.blanks });
        }
        try printDependency(gpa, child.dependency, indent + 1, config);
    }
}

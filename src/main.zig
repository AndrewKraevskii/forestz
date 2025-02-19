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

    var path: ?[]const u8 = null;
    var sort_by: ?@FieldType(PrintConfig, "sort_by") = null;
    var print_files: ?bool = null;
    var print_total_for_project: ?bool = null;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.startsWith(u8, args[index], "--sort=")) {
            sort_by = std.meta.stringToEnum(@FieldType(PrintConfig, "sort_by"), args[index]["--sort=".len..]) orelse {
                std.debug.print("Unexpected sort option. Options:", .{});
                for (std.enums.values(@FieldType(PrintConfig, "sort_by"))) |variant| {
                    std.debug.print(" {s}", .{@tagName(variant)});
                }
                std.debug.print("\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, args[index], "--files") or std.mem.eql(u8, args[index], "-f")) {
            print_files = true;
        } else if (std.mem.eql(u8, args[index], "--project-total")) {
            print_total_for_project = true;
        } else if (std.mem.startsWith(u8, args[index], "--")) {
            std.debug.print("Unexpected flag\n", .{});
            return;
        } else {
            path = args[index];
        }
    }

    var dir = try std.fs.cwd().openDir(path orelse ".", .{ .iterate = true });
    defer dir.close();

    const tree = try getDependencyTree(arena, gpa, dir);

    try printDependency(gpa, tree.root, 0, .{
        .print_files = print_files orelse false,
        .sort_by = sort_by orelse .name,
        .print_total_for_project = print_total_for_project orelse false,
        .filter_dirs = &.{
            ".zig-cache",
            "zig-out",
        },
    });
}

const PrintConfig = struct {
    print_files: bool,
    print_total_for_project: bool,
    sort_by: enum {
        name,
        lines,
        code,
        comments,
        blanks,
    },
    filter_dirs: []const []const u8,
};

fn printDependency(
    gpa: std.mem.Allocator,
    dep: Tree.Dependency,
    indent: u16,
    config: PrintConfig,
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
            var max_len: usize = @max(total_text.len, child.import_name.len);
            if (config.print_files) {
                var iter = try dep_root_dir.walk(gpa);
                defer iter.deinit();
                while (try iter.next()) |entry| {
                    if (entry.kind != .file) continue;
                    const file_name = entry.path;
                    max_len = @max(max_len, file_name.len);
                }
            }
            break :max_len max_len;
        };
        if (config.print_files or config.print_total_for_project) {
            try writer.print("{s}", .{child.import_name});
            try writer.writeByteNTimes(' ', max_len - child.import_name.len);
            try writer.print(" lines    code     comments blanks\n", .{});
        }

        var iter = try dep_root_dir.walk(gpa);
        defer iter.deinit();

        var total_stats: loc.Stats = .empty;
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const file_name = entry.path;
            const file_content = try dep_root_dir.readFileAlloc(gpa, file_name, 1000 * 1000 * 1000);
            defer gpa.free(file_content);
            const stats = loc.statsFromSlice(file_content);
            if (config.print_files) {
                try writer.print("{s}", .{file_name});
                try writer.writeByteNTimes(' ', max_len - file_name.len + 1);
                try writer.print("{d:<8} {d:<8} {d:<8} {d:<8}\n", .{ stats.lines, stats.code, stats.comments, stats.blanks });
            }
            total_stats = total_stats.add(stats);
        }
        if (config.print_total_for_project) {
            try writer.print(total_text, .{});
            try writer.writeByteNTimes(' ', max_len - "total stats".len + 1);
            try writer.print("{d:<8} {d:<8} {d:<8} {d:<8}\n", .{ total_stats.lines, total_stats.code, total_stats.comments, total_stats.blanks });
        }
        // } else {
        try writer.print("{s}\n", .{child.import_name});
        // }
        try printDependency(gpa, child.dependency, indent + 1, config);
    }
}

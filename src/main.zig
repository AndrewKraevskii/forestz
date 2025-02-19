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
    var print_path: ?bool = null;
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
        } else if (std.mem.eql(u8, args[index], "--project-path")) {
            print_path = true;
        } else if (std.mem.eql(u8, args[index], "--help")) {
            printHelpAndExit();
        } else if (std.mem.startsWith(u8, args[index], "--")) {
            std.debug.print("Unexpected flag\n", .{});
            printHelpAndExit();
        } else {
            path = args[index];
        }
    }

    var dir = try std.fs.cwd().openDir(path orelse ".", .{ .iterate = true });
    defer dir.close();

    var real_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try std.fs.cwd().realpath(path orelse ".", &real_path_buffer);

    const tree = try getDependencyTree(arena, gpa, dir);

    const total_stats = stats: {
        var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
        defer bw.flush() catch {};

        break :stats try printDependency(gpa, bw.writer(), .{
            .absolute_path = real_path,
            .children = &.{.{
                .import_name = std.fs.path.basename(real_path),
                .dependency = tree.root,
            }},
            .name = null,
        }, 0, .{
            .print_files = print_files orelse false,
            .print_path = print_path orelse false,
            .sort_by = sort_by orelse .name,
            .print_total_for_project = print_total_for_project orelse false,
            .filter_dirs = &.{
                ".zig-cache",
                "zig-out",
            },
            .extensions = &.{
                ".zig",
            },
        });
    };
    std.debug.print("Total stats\n", .{});
    std.debug.print("lines    code     comments blanks\n", .{});
    std.debug.print("{d:<8} {d:<8} {d:<8} {d:<8}\n", .{
        total_stats.lines,
        total_stats.code,
        total_stats.comments,
        total_stats.blanks,
    });
}

pub fn printHelpAndExit() noreturn {
    std.debug.print(
        \\forests path/to/project/root
        \\
        \\Flags:
        \\ --project-total   print stats for each project
        \\ --project-path    print absolute path for each project
        \\ --files           print induvidual file stats
        \\ --sort=<query>    sort files when printing file by <query> where <query> is one of
        \\                          name
        \\                          code
        \\                          lines
        \\                          blanks
        \\                          comments
        \\
    , .{});
    std.process.exit(0);
}

const PrintConfig = struct {
    print_path: bool,
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
    extensions: []const []const u8,
};

fn printDependency(
    gpa: std.mem.Allocator,
    _writer: anytype,
    dep: Tree.Dependency,
    indent: u16,
    config: PrintConfig,
) !loc.Stats {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var writer_state = indentedWriter(indent, _writer);
    const writer = writer_state.writer();

    const arena = arena_state.allocator();

    var project_stats: loc.Stats = .empty;

    for (dep.children) |child| {
        _ = arena_state.reset(.retain_capacity);

        const File = struct {
            path: []const u8,
            stats: loc.Stats,
        };
        const files_list = files_list: {
            var dep_root_dir = try std.fs.openDirAbsolute(child.dependency.absolute_path, .{
                .iterate = true,
            });
            defer dep_root_dir.close();

            var files_list: std.ArrayListUnmanaged(File) = .empty;
            defer files_list.deinit(gpa);

            var iter = try dep_root_dir.walk(gpa);
            defer iter.deinit();

            entry: while (try iter.next()) |entry| {
                const file_name = entry.path;
                if (entry.kind != .file) continue;
                for (config.filter_dirs) |filter_dir| {
                    if (std.mem.containsAtLeast(u8, file_name, 1, filter_dir)) {
                        continue :entry;
                    }
                }
                for (config.extensions) |extension| {
                    if (std.mem.eql(u8, std.fs.path.extension(entry.basename), extension)) {
                        break;
                    }
                } else continue;
                const file_content = try dep_root_dir.readFileAlloc(gpa, file_name, 1000 * 1000 * 1000);
                defer gpa.free(file_content);
                const stats = loc.statsFromSlice(file_content);
                project_stats = project_stats.add(stats);
                try files_list.append(gpa, .{ .stats = stats, .path = try arena.dupe(u8, file_name) });
            }
            break :files_list try files_list.toOwnedSlice(gpa);
        };
        defer gpa.free(files_list);

        std.mem.sort(File, files_list, config.sort_by, struct {
            fn less(ctx: @TypeOf(config.sort_by), lhs: File, rhs: File) bool {
                return switch (ctx) {
                    .name => std.mem.lessThan(u8, lhs.path, rhs.path),
                    .lines => lhs.stats.lines < rhs.stats.lines,
                    .code => lhs.stats.code < rhs.stats.code,
                    .comments => lhs.stats.comments < rhs.stats.comments,
                    .blanks => lhs.stats.blanks < rhs.stats.blanks,
                };
            }
        }.less);

        const total_text = "total stats";
        const max_len = max_len: {
            var max_len: usize = @max(total_text.len, child.import_name.len);
            if (config.print_files) {
                for (files_list) |file| {
                    const file_name = file.path;
                    max_len = @max(max_len, file_name.len);
                }
            }
            break :max_len max_len;
        };
        if (config.print_path) {
            try writer.print("{s}\n", .{child.dependency.absolute_path});
        }
        if (config.print_files or config.print_total_for_project) {
            try writer.print("{s}", .{child.import_name});
            try writer.writeByteNTimes(' ', max_len - child.import_name.len);
            try writer.print(" lines    code     comments blanks", .{});
            try writer.print("\n", .{});
        }

        var total_stats: loc.Stats = .empty;
        for (files_list) |entry| {
            const file_name = entry.path;
            const stats = entry.stats;
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
        if (config.print_files or config.print_total_for_project) {
            try writer.print("\n", .{});
        }
        project_stats = project_stats.add(try printDependency(gpa, _writer, child.dependency, indent + 1, config));
    }

    return project_stats;
}

const std = @import("std");

const getDependencyTree = @import("tree.zig").getDependencyTree;
const indentedWriter = @import("indented_writer.zig").indentedWriter;
const loc = @import("loc.zig");
const Tree = @import("tree.zig").Tree;
const walk = @import("stdx.zig").walk;
const Language = @import("languages.zig").Language;
const language_by_extension = @import("languages.zig").language_by_extension;

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

    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    defer bw.flush() catch {};
    const total_stats = stats: {
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
        });
    };
    var languages_sum: loc.Stats = .empty;
    for (total_stats.stats()) |language_stat| {
        languages_sum = languages_sum.add(language_stat);
    }
    var grid: @import("GridPrinter.zig") = try .init(gpa, 5, 1);
    defer grid.deinit();

    try grid.print("Total stats", .{});
    try grid.print("lines", .{});
    try grid.print("code", .{});
    try grid.print("comments", .{});
    try grid.print("blanks", .{});

    var iter = total_stats.skipZeroIter();
    while (iter.next()) |entry| {
        try grid.print("{s}", .{@tagName(entry.language)});
        try grid.print("{d}", .{entry.stats.lines});
        try grid.print("{d}", .{entry.stats.code});
        try grid.print("{d}", .{entry.stats.comments});
        try grid.print("{d}", .{entry.stats.blanks});
    }
    try grid.flush(bw.writer());
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
};

fn printDependency(
    gpa: std.mem.Allocator,
    _writer: anytype,
    dep: Tree.Dependency,
    indent: u16,
    config: PrintConfig,
) !loc.MultilanguageStats {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var writer_state = indentedWriter(indent, _writer);
    const writer = writer_state.writer();

    var project_stats: loc.MultilanguageStats = .empty;

    var grid: @import("GridPrinter.zig") = try .init(gpa, 5, 1);
    defer grid.deinit();

    for (dep.children) |child| {
        {
            _ = arena_state.reset(.retain_capacity);
            defer grid.flush(writer) catch {};

            const File = struct {
                path: []const u8,
                language: Language,
                stats: loc.Stats,
            };
            const files_list = files_list: {
                var dep_root_dir = try std.fs.openDirAbsolute(child.dependency.absolute_path, .{
                    .iterate = true,
                });
                defer dep_root_dir.close();

                var files_list: std.ArrayListUnmanaged(File) = .empty;
                defer files_list.deinit(gpa);

                var iter = try walk(dep_root_dir, gpa);
                defer iter.deinit();

                entry: while (try iter.next()) |entry| {
                    const file_name = entry.path;
                    if (entry.kind != .file) continue;
                    for (config.filter_dirs) |filter_dir| {
                        if (std.mem.containsAtLeast(u8, file_name, 1, filter_dir)) {
                            iter.exitDir();
                            continue :entry;
                        }
                    }
                    const extension = std.fs.path.extension(entry.basename);
                    if (extension.len == 0) continue :entry;

                    const language = language_by_extension.get(extension[1..]) orelse continue :entry;

                    const stats = loc.statsFromFile(gpa, dep_root_dir, entry.path) catch |e| switch (e) {
                        error.UnknownLanguage => continue :entry,
                        else => |other| return other,
                    };
                    project_stats.addStatForLanguage(language, stats);
                    try files_list.append(gpa, .{ .stats = stats, .path = try arena.dupe(u8, file_name), .language = language });
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

            if (config.print_path) {
                try grid.print("{s}", .{child.dependency.absolute_path});
                try grid.lineBreak();
            }
            if (config.print_files or config.print_total_for_project) {
                try grid.print("{s}", .{child.import_name});
                try grid.print("lines", .{});
                try grid.print("code", .{});
                try grid.print("comments", .{});
                try grid.print("blanks", .{});
            }

            var dependency_stats: loc.MultilanguageStats = .empty;
            for (files_list) |entry| {
                const file_name = entry.path;
                const stats = entry.stats;
                if (config.print_files) {
                    try grid.print("{s}", .{file_name});
                    try grid.print("{d}", .{stats.lines});
                    try grid.print("{d}", .{stats.code});
                    try grid.print("{d}", .{stats.comments});
                    try grid.print("{d}", .{stats.blanks});
                }
                dependency_stats.addStatForLanguage(entry.language, stats);
            }
            if (config.print_total_for_project) {
                if (config.print_files) {
                    try grid.lineBreak();
                    try grid.print("By language", .{});
                    try grid.print("lines", .{});
                    try grid.print("code", .{});
                    try grid.print("comments", .{});
                    try grid.print("blanks", .{});
                }
                var iter = dependency_stats.skipZeroIter();
                while (iter.next()) |entry| {
                    const stats = entry.stats;
                    const name = entry.language;
                    try grid.print("{s}", .{@tagName(name)});
                    try grid.print("{d}", .{stats.lines});
                    try grid.print("{d}", .{stats.code});
                    try grid.print("{d}", .{stats.comments});
                    try grid.print("{d}", .{stats.blanks});
                }
            }
            if (config.print_total_for_project or config.print_files) {
                try grid.lineBreak();
            }
        }
        const dep_stats = try printDependency(gpa, _writer, child.dependency, indent + 1, config);
        project_stats.add(dep_stats);
    }

    return project_stats;
}

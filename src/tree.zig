const std = @import("std");

pub const Config = struct {
    print_files: bool,
    skip_directories: []const []const u8 = &.{
        ".zig-cache",
        "zig-out",
    },
};

pub fn printZigFiles(gpa: std.mem.Allocator, dir: std.fs.Dir, config: Config) !void {
    var visited_files: StringMap(FileInfo) = .empty;
    defer visited_files.deinit(gpa);

    var visited_projects: StringMap(ProjectInfo) = .empty;
    defer visited_projects.deinit(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const out = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(out);
    std.debug.print("root\n", .{});

    var state: State = .{
        .gpa = gpa,
        .tree_arena = arena.allocator(),
        .visited_projects = &visited_projects,
        .visited_files = &visited_files,
        .writer = bw.writer().any(),
        .config = config,
    };

    const lines = try state.innerPrintZigFiles(dir, 0);
    bw.flush() catch {};

    std.debug.print("total lines {d}\n", .{lines});
}

const StringMap = std.StringArrayHashMapUnmanaged;

const FileInfo = struct {
    lines: u32,
};

const ProjectInfo = struct {
    files: u32,
    lines: u32,
};

const State = struct {
    gpa: std.mem.Allocator,
    tree_arena: std.mem.Allocator,
    visited_files: *StringMap(FileInfo),
    visited_projects: *StringMap(ProjectInfo),
    writer: std.io.AnyWriter,
    config: Config,

    fn innerPrintZigFiles(
        state: *State,
        dir: std.fs.Dir,
        depth: u16,
    ) !u64 {
        var iter = try dir.walk(state.gpa);
        defer iter.deinit();

        var arena = std.heap.ArenaAllocator.init(state.gpa);
        defer arena.deinit();

        var count: u64 = 0;

        entry: while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;

            file: {
                if (!std.mem.eql(u8, std.fs.path.extension(entry.path), ".zig")) break :file;

                for (state.config.skip_directories) |dir_name| {
                    if (std.mem.containsAtLeast(u8, entry.path, 1, dir_name)) continue :entry;
                }
                const gop = try state.visited_files.getOrPut(state.gpa, try state.tree_arena.dupe(u8, entry.path));
                if (gop.found_existing) continue;

                const lines = try countLines(arena.allocator(), dir, entry.path);
                count += lines;
                if (state.config.print_files) {
                    try printIndented(state.writer, "{s} - {d}\n", .{ entry.path, lines }, depth);
                }
                continue;
            }
            if (std.mem.eql(u8, entry.path, "build.zig.zon")) {
                const result = try openBuildZigZon(arena.allocator(), dir, entry.path);

                for (result.dependencies.keys(), result.dependencies.values()) |key, value| {
                    const gop = try state.visited_projects.getOrPut(state.gpa, try state.tree_arena.dupe(u8, key));
                    if (gop.found_existing) continue;

                    const path =
                        if (value.path.len != 0) value.path else path: {
                        const cache_path = try resolveGlobalCacheDir(arena.allocator());
                        break :path try std.fs.path.join(arena.allocator(), &.{ cache_path, "p", value.hash });
                    };

                    try printIndented(state.writer, "{s} - {s}\n", .{ key, path }, depth + 1);
                    var dep_dir = dir.openDir(path, .{ .iterate = true }) catch |e| switch (e) {
                        error.FileNotFound => continue,
                        else => |other| return other,
                    };
                    defer dep_dir.close();

                    count += try state.innerPrintZigFiles(
                        dep_dir,
                        depth + 1,
                    );
                }
            }

            _ = arena.reset(.retain_capacity);
        }

        return count;
    }
};

fn printIndented(writer: anytype, comptime fmt: []const u8, args: anytype, indent: u16) !void {
    try writer.writeByteNTimes(' ', indent);
    try writer.print(fmt, args);
}

fn countLines(arena: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !u64 {
    const content = try dir.readFileAlloc(arena, path, 1000 * 1000 * 1000);

    var iter = std.mem.tokenizeAny(u8, content, "\n\r");
    var lines: u64 = 0;
    while (iter.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, &std.ascii.whitespace);

        if (std.mem.startsWith(u8, trimmed, "//")) continue; // this is comment

        lines += 1;
    }

    return lines;
}

const BuildZigZon = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    dependencies: std.StringArrayHashMapUnmanaged(Dependency) = .empty,

    const Dependency = struct {
        url: []const u8 = "",
        hash: []const u8 = "",
        path: []const u8 = "",
        lazy: bool = false,
    };
};

fn openBuildZigZon(arena: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !BuildZigZon {
    const content = try dir.readFileAllocOptions(arena, path, 1000 * 1000 * 1000, null, 1, 0);

    const ast = try std.zig.Ast.parse(arena, content, .zon);
    const zoir = try std.zig.ZonGen.generate(arena, ast, .{ .parse_str_lits = true });

    const root = std.zig.Zoir.Node.Index.root.get(zoir);
    const root_struct = if (root == .struct_literal) root.struct_literal else return error.Parse;

    var result: BuildZigZon = .{};

    for (root_struct.names, 0..root_struct.vals.len) |name_node, index| {
        const value = root_struct.vals.at(@intCast(index));
        const name = name_node.get(zoir);

        if (std.mem.eql(u8, name, "name")) {
            result.name = value.get(zoir).string_literal;
        }

        if (std.mem.eql(u8, name, "version")) {
            result.version = value.get(zoir).string_literal;
        }

        if (std.mem.eql(u8, name, "dependencies")) dep: {
            switch (value.get(zoir)) {
                .struct_literal => |sl| {
                    for (sl.names, 0..sl.vals.len) |dep_name, dep_index| {
                        const node = sl.vals.at(@intCast(dep_index));
                        const dep_body = try std.zon.parse.fromZoirNode(BuildZigZon.Dependency, arena, ast, zoir, node, null, .{});

                        try result.dependencies.put(arena, dep_name.get(zoir), dep_body);
                    }
                },
                .empty_literal => {
                    break :dep;
                },
                else => return error.Parse,
            }
        }
    }

    return result;
}

const builtin = @import("builtin");
const fs = std.fs;

/// copied from src/introspect.zig:82
fn resolveGlobalCacheDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .wasi)
        @compileError("on WASI the global cache dir must be resolved with preopens");

    if (try std.zig.EnvVar.ZIG_GLOBAL_CACHE_DIR.get(allocator)) |value| return value;

    const appname = "zig";

    if (builtin.os.tag != .windows) {
        if (std.zig.EnvVar.XDG_CACHE_HOME.getPosix()) |cache_root| {
            if (cache_root.len > 0) {
                return fs.path.join(allocator, &.{ cache_root, appname });
            }
        }
        if (std.zig.EnvVar.HOME.getPosix()) |home| {
            return fs.path.join(allocator, &.{ home, ".cache", appname });
        }
    }

    return fs.getAppDataDir(allocator, appname);
}

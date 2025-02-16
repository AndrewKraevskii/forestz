const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    print_files: bool,
    skip_directories: []const []const u8 = &.{
        ".zig-cache",
        "zig-out",
    },
};

pub fn printZigFiles(gpa: Allocator, dir: std.fs.Dir) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const tree = try getDependencyTree(arena.allocator(), gpa, dir);
    const out = std.io.getStdOut().writer();

    try tree.root.dump(out, 0);
}

pub fn getDependencyTree(
    arena: Allocator,
    gpa: Allocator,
    dir: std.fs.Dir,
) !Tree {
    var state: State = .{
        .cache_path = try resolveGlobalCacheDir(arena),
        .gpa = gpa,
        .tree_arena = arena,
        .visited_projects = .empty,
    };
    defer {
        state.visited_projects.deinit(gpa);
    }

    return .{ .root = try state.innerPrintZigFiles(dir, 0) };
}

const Tree = struct {
    root: Dependency,

    const Dependency = struct {
        absolute_path: []const u8,
        /// Name is null if build.zig.zon is absent
        name: ?[]const u8,
        children: []Child,

        const Child = struct {
            name: []const u8,
            dep: Dependency,

            pub fn dump(c: Child, writer: anytype, indent: u16) @TypeOf(writer).Error!void {
                try printIndented(writer, "{s}\n", .{c.name}, indent);
                for (c.dep.children) |child| {
                    try child.dump(writer, indent + 1);
                }
            }
        };

        pub fn displayName(d: Dependency) []const u8 {
            return if (d.name) |name| name else std.fs.path.basename(d.absolute_path);
        }

        pub fn dump(t: Dependency, writer: anytype, indent: u16) @TypeOf(writer).Error!void {
            try printIndented(writer, "{s}\n", .{t.displayName()}, indent);
            for (t.children) |child| {
                try child.dump(writer, indent + 1);
            }
        }
    };
};

const State = struct {
    gpa: Allocator,
    tree_arena: Allocator,
    visited_projects: std.StringHashMapUnmanaged(void),
    cache_path: []const u8,

    fn innerPrintZigFiles(
        state: *State,
        dir: std.fs.Dir,
        depth: u16,
    ) !Tree.Dependency {
        var arena = std.heap.ArenaAllocator.init(state.gpa);
        defer arena.deinit();
        const full_path = try dir.realpathAlloc(state.tree_arena, ".");
        const result = openBuildZigZon(arena.allocator(), dir, "build.zig.zon") catch |e| switch (e) {
            error.FileNotFound => return .{
                .absolute_path = full_path,
                .name = null,
                .children = &.{},
            },
            else => return e,
        };
        var deps_array: std.ArrayListUnmanaged(Tree.Dependency.Child) = try .initCapacity(state.tree_arena, result.dependencies.values().len);
        for (result.dependencies.keys(), result.dependencies.values()) |key, value| {
            const gop = try state.visited_projects.getOrPut(state.gpa, try state.tree_arena.dupe(u8, key));
            if (gop.found_existing) continue;

            const path = if (value.path.len != 0) value.path else path: {
                break :path try std.fs.path.join(arena.allocator(), &.{ state.cache_path, "p", value.hash });
            };

            var dep_dir = dir.openDir(path, .{ .iterate = true }) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => |other| return other,
            };
            defer dep_dir.close();

            deps_array.appendAssumeCapacity(.{
                .name = try state.tree_arena.dupe(u8, key),
                .dep = try state.innerPrintZigFiles(
                    dep_dir,
                    depth + 1,
                ),
            });
        }
        return .{
            .absolute_path = full_path,
            .name = if (result.name) |name| try state.tree_arena.dupe(u8, name) else null,
            .children = try deps_array.toOwnedSlice(state.tree_arena),
        };
    }
};

fn printIndented(writer: anytype, comptime fmt: []const u8, args: anytype, indent: u16) !void {
    try writer.writeByteNTimes(' ', indent);
    try writer.print(fmt, args);
}

fn countLines(arena: Allocator, dir: std.fs.Dir, path: []const u8) !u64 {
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

fn openBuildZigZon(arena: Allocator, dir: std.fs.Dir, path: []const u8) !BuildZigZon {
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
fn resolveGlobalCacheDir(allocator: Allocator) ![]u8 {
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

const std = @import("std");
const Allocator = std.mem.Allocator;
const resolveGlobalCacheDir = @import("stdx.zig").resolveGlobalCacheDir;

pub const Config = struct {
    print_files: bool,
    skip_directories: []const []const u8 = &.{
        ".zig-cache",
        "zig-out",
    },
};

pub fn getDependencyTree(
    arena: Allocator,
    gpa: Allocator,
    dir: std.fs.Dir,
) !Tree {
    var state: TreeBuilder = .{
        .cache_path = try resolveGlobalCacheDir(arena),
        .gpa = gpa,
        .tree_arena = arena,
        .visited_projects = .empty,
    };
    defer {
        state.visited_projects.deinit(gpa);
    }

    return .{
        .root = try state.innerBuildTree(dir, 0),
    };
}

pub const Tree = struct {
    root: Dependency,

    pub const Dependency = struct {
        absolute_path: []const u8,
        /// Name is null if build.zig.zon is absent
        name: ?[]const u8,
        children: []const Child,

        const Child = struct {
            /// name specified in build.zig.zon as name of module
            import_name: []const u8,
            dependency: Dependency,

            pub fn dump(c: Child, writer: anytype, indent: u16) @TypeOf(writer).Error!void {
                try printIndented(writer, "{s}\n", .{c.import_name}, indent);
                for (c.dependency.children) |child| {
                    try child.dump(writer, indent + 1);
                }
            }
        };

        pub fn displayName(d: Dependency) []const u8 {
            return if (d.name) |name| name else std.fs.path.basename(d.absolute_path);
        }
    };

    pub fn dump(t: Tree, writer: anytype) @TypeOf(writer).Error!void {
        try printIndented(writer, "{s}\n", .{t.root.displayName()}, 0);

        for (t.root.children) |child| {
            try child.dump(writer, 1);
        }
    }
};

const TreeBuilder = struct {
    gpa: Allocator,
    tree_arena: Allocator,
    visited_projects: std.StringArrayHashMapUnmanaged(void),
    cache_path: []const u8,

    fn innerBuildTree(
        state: *TreeBuilder,
        dir: std.fs.Dir,
        depth: u16,
    ) !Tree.Dependency {
        var arena = std.heap.ArenaAllocator.init(state.gpa);
        defer arena.deinit();
        const full_path = try dir.realpathAlloc(state.tree_arena, ".");
        const result = readBuildZigZon(arena.allocator(), dir) catch |e| switch (e) {
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
                .import_name = try state.tree_arena.dupe(u8, key),
                .dependency = try state.innerBuildTree(
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

fn readBuildZigZon(arena: Allocator, dir: std.fs.Dir) !BuildZigZon {
    const content = try dir.readFileAllocOptions(arena, "build.zig.zon", 1000 * 1000 * 1000, null, 1, 0);

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

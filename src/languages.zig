const std = @import("std");

pub const Description = struct {
    blank: bool = false,
    doc_quotes: []const [2][]const u8 = &.{},
    env: []const []const u8 = &.{},
    extensions: ?[]const []const u8 = null,
    filenames: []const []const u8 = &.{},
    important_syntax: []const []const u8 = &.{},
    kind: ?[]const u8 = null,
    line_comment: []const []const u8 = &.{},
    literate: bool = false,
    mime: []const []const u8 = &.{},
    multi_line_comments: []const [2][]const u8 = &.{},
    name: ?[]const u8 = null,
    nested: bool = false,
    nested_comments: []const [2][]const u8 = &.{},
    quotes: []const [2][]const u8 = &.{},
    shebangs: []const []const u8 = &.{},
    verbatim_quotes: []const [2][]const u8 = &.{},
};

const LanguageWithName = struct {
    id: [:0]const u8,

    description: Description,
};

const languages: []const LanguageWithName = @import("languages.zon");

pub const language_by_extension = blk: {
    @setEvalBranchQuota(2000);

    var extensions: []const struct { []const u8, Language } = &.{};
    var mutable_map = map;
    var iter = mutable_map.iterator();

    while (iter.next()) |entry| {
        for (entry.value.extensions orelse &.{}) |extension| {
            extensions = extensions ++ .{.{
                extension,
                entry.key,
            }};
        }
    }

    const result: std.StaticStringMap(Language) = .initComptime(extensions);

    break :blk result;
};

test {
    try std.testing.expectEqual(language_by_extension.get("zig"), .zig);
    try std.testing.expectEqual(language_by_extension.get("c++"), .cpp);
    try std.testing.expectEqual(language_by_extension.get("cpp"), .cpp);
    try std.testing.expectEqual(language_by_extension.get("c"), .c);
}

pub const map: std.EnumArray(
    Language,
    Description,
) = blk: {
    var temp_map: std.EnumArray(
        Language,
        Description,
    ) = .initUndefined();
    for (languages, 0..) |language, index| {
        temp_map.values[index] = language.description;
    }
    break :blk temp_map;
};

pub const Language = blk: {
    var fields: [languages.len]std.builtin.Type.EnumField = undefined;

    for (&fields, languages, 0..) |*field, language, index| {
        field.* = .{ .name = language.id, .value = index };
    }
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = std.math.IntFittingRange(0, fields.len),
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

pub const max_language_name = blk: {
    var max: usize = 0;
    for (languages) |entry| {
        max = @max(max, entry.id.len, (entry.description.name orelse "").len);
    }

    break :blk max;
};

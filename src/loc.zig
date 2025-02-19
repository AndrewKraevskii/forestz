const std = @import("std");
const Language = @import("languages.zig").Language;
const languages_map = @import("languages.zig").map;
const language_by_extension = @import("languages.zig").language_by_extension;

pub const MultilanguageStats = struct {
    stats_per_language: std.EnumArray(Language, Stats),

    pub const empty: @This() = .{ .stats_per_language = .initFill(.empty) };

    pub fn addStatForLanguage(self: *MultilanguageStats, language: Language, stat: Stats) void {
        const value = self.stats_per_language.getPtr(language);
        value.* = value.add(stat);
    }

    pub fn add(self: *MultilanguageStats, other: MultilanguageStats) void {
        for (&self.stats_per_language.values, &other.stats_per_language.values) |*project, dep_stat| {
            project.* = project.add(dep_stat);
        }
    }

    pub fn stats(self: *const MultilanguageStats) []const Stats {
        return &self.stats_per_language.values;
    }

    const languages = std.enums.values(Language);
};

pub const Stats = struct {
    lines: u64,
    code: u64,
    comments: u64,
    blanks: u64,

    pub const empty: Stats = .{
        .lines = 0,
        .code = 0,
        .comments = 0,
        .blanks = 0,
    };

    pub fn add(lhs: Stats, rhs: Stats) Stats {
        return .{
            .lines = lhs.lines + rhs.lines,
            .code = lhs.code + rhs.code,
            .comments = lhs.comments + rhs.comments,
            .blanks = lhs.blanks + rhs.blanks,
        };
    }
};

pub fn statsFromSlice(slice: []const u8, language: Language) Stats {
    // we use \n since extra \r will be dropped in trimming.
    const line_comment_tokens = languages_map.get(language).line_comment;

    var iter = std.mem.splitScalar(u8, slice, '\n');
    var code: u64 = 0;
    var lines: u64 = 0;
    var comments: u64 = 0;
    var blanks: u64 = 0;
    line: while (iter.next()) |line| : (lines += 1) {
        const trimmed = std.mem.trimLeft(u8, line, &std.ascii.whitespace);

        if (trimmed.len == 0) {
            blanks += 1;
            continue;
        }

        for (line_comment_tokens) |line_comment| {
            if (std.mem.startsWith(u8, trimmed, line_comment)) {
                comments += 1;
                continue :line;
            } // this is comment
        }
        code += 1;
    }

    std.debug.assert(lines == code + comments + blanks);

    return .{
        .lines = lines,
        .code = code,
        .comments = comments,
        .blanks = blanks,
    };
}

pub fn statsFromFile(gpa: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !Stats {
    const extension_without_dot = std.mem.trimLeft(u8, std.fs.path.extension(path), ".");
    const language = language_by_extension.get(extension_without_dot) orelse return error.UnknownLanguage;

    const file = try dir.readFileAlloc(gpa, path, 1000_000_000);
    defer gpa.free(file);

    return statsFromSlice(
        file,
        language,
    );
}

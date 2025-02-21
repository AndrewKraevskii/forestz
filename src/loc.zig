const std = @import("std");
const Language = @import("languages.zig").Language;
const languages_map = @import("languages.zig").info;
const language_by_extension = @import("languages.zig").by_extension;
const whitespace = std.ascii.whitespace;

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

    pub fn skipZeroIter(self: *const MultilanguageStats) SkipZeroIterator {
        return .{
            .multilanguage_stats = self,
            .index = 0,
        };
    }

    const SkipZeroIterator = struct {
        multilanguage_stats: *const MultilanguageStats,
        index: std.math.IntFittingRange(0, @typeInfo(Language).@"enum".fields.len),

        pub fn next(self: *SkipZeroIterator) ?struct { language: Language, stats: Stats } {
            while (true) {
                if (self.index == self.multilanguage_stats.stats_per_language.values.len) return null;
                defer self.index += 1;

                if (std.meta.eql(self.multilanguage_stats.stats_per_language.values[self.index], .empty)) continue;

                break;
            }
            const stat = self.multilanguage_stats.stats_per_language.values[self.index - 1];

            return .{
                .language = std.enums.values(Language)[self.index - 1],
                .stats = stat,
            };
        }
    };

    const languages = std.enums.values(Language);
};

pub const Stats = struct {
    code: u64,
    comments: u64,
    blanks: u64,

    pub const empty: Stats = .{
        .code = 0,
        .comments = 0,
        .blanks = 0,
    };

    pub fn add(lhs: Stats, rhs: Stats) Stats {
        return .{
            .code = lhs.code + rhs.code,
            .comments = lhs.comments + rhs.comments,
            .blanks = lhs.blanks + rhs.blanks,
        };
    }

    pub fn lines(s: Stats) u64 {
        return s.code + s.comments + s.blanks;
    }
};

pub fn statsFromSlice(slice: []const u8, language: Language) Stats {
    // we use \n since extra \r will be dropped in trimming.
    const lang_info = languages_map.get(language);
    const line_comment_tokens = lang_info.line_comment;
    const multi_line_comments = lang_info.multi_line_comments;

    var iter = std.mem.splitScalar(u8, slice, '\n');
    var code: u64 = 0;
    var lines: u64 = 0;
    var comments: u64 = 0;
    var blanks: u64 = 0;
    const State = union(enum) {
        plain,
        multiline_comment: []const u8,
    };

    var state: State = .plain;

    line: while (iter.next()) |line| : (lines += 1) {
        var trimmed = std.mem.trimLeft(u8, line, &whitespace);

        var line_type: enum {
            unknown,
            code,
            comment,
            blank,

            pub fn set(typ: *@This(), new: @This()) void {
                std.debug.assert(new != .unknown);

                if (typ.* == .unknown) typ.* = new;
            }
        } = .unknown;
        defer {
            switch (line_type) {
                .code => code += 1,
                .comment => comments += 1,
                .blank => blanks += 1,
                .unknown => unreachable,
            }
        }
        state: switch (state) {
            .plain => {
                if (trimmed.len == 0) {
                    line_type.set(.blank);
                    continue :line;
                }

                for (line_comment_tokens) |line_comment| {
                    if (std.mem.startsWith(u8, trimmed, line_comment)) {
                        line_type.set(.comment);
                        continue :line;
                    }
                }
                for (multi_line_comments) |multiline_comment| {
                    const multiline_comment_start = multiline_comment[0];
                    const multiline_comment_end = multiline_comment[1];
                    if (std.mem.startsWith(u8, trimmed, multiline_comment_start)) {
                        line_type.set(.comment);
                        state = .{ .multiline_comment = multiline_comment_end };
                        trimmed = trimmed[multiline_comment_start.len..];
                        continue :state state;
                    }

                    if (std.mem.containsAtLeast(u8, trimmed, 1, multiline_comment_start)) {
                        line_type.set(.code);
                        state = .{ .multiline_comment = multiline_comment_end };
                        trimmed = trimmed[multiline_comment_start.len..];
                        continue :state state;
                    }
                }
                line_type.set(.code);
            },
            .multiline_comment => |end_token| {
                if (std.mem.indexOf(u8, trimmed, end_token)) |index| {
                    state = .plain;
                    if (std.mem.trim(u8, trimmed[index + end_token.len ..], &whitespace).len > 0) {
                        line_type.set(.code);
                    } else {
                        line_type.set(.comment);
                    }
                    trimmed = trimmed[index..];
                    continue :state state;
                } else {
                    line_type.set(.comment);
                }
            },
        }
    }

    std.debug.assert(lines == code + comments + blanks);

    return .{
        .code = code,
        .comments = comments,
        .blanks = blanks,
    };
}

test "Ziglang" {
    const zig_program =
        \\//! File level doc comment
        \\//!
        \\
        \\// regular comment
        \\//
        \\// regular comment
        \\const std = @import("std");
        \\
        \\/// Doc comment
        \\const Struct = struct {
        \\
        \\};
        \\
        \\const comment_in_string = "//";
        \\
    ;
    const stats = statsFromSlice(zig_program, .zig);
    try std.testing.expectEqual(Stats{
        .code = 4,
        .comments = 6,
        .blanks = 5,
    }, stats);
}

test "C" {
    const c_program =
        \\// regular comment
        \\// and another one
        \\
        \\#include <stdio.h>
        \\
        \\int main() {
        \\    printf("Hello, world!"); // This should count as code
        \\    int foo /* this one should be ignored */ = 10;
        \\
        \\    /* this one should be comment */ /** continuation */ // and line comment
        \\}
        \\
        \\/*
        \\ Multiline comment
        \\
        \\ more lines
        \\ and yet more */
        \\
    ;
    const stats = statsFromSlice(c_program, .c);
    try std.testing.expectEqual(Stats{
        .code = 5,
        .comments = 8,
        .blanks = 5,
    }, stats);
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

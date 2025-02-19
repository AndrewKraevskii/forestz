const std = @import("std");

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

pub fn statsFromSlice(slice: []const u8) Stats {
    // we use \n since extra \r will be droped in trimming.
    var iter = std.mem.splitScalar(u8, slice, '\n');
    var code: u64 = 0;
    var lines: u64 = 0;
    var comments: u64 = 0;
    var blanks: u64 = 0;
    while (iter.next()) |line| : (lines += 1) {
        const trimmed = std.mem.trimLeft(u8, line, &std.ascii.whitespace);

        if (trimmed.len == 0) {
            blanks += 1;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "//")) {
            comments += 1;
            continue;
        } // this is comment
        code += 1;
    }

    return .{
        .lines = lines,
        .code = code,
        .comments = comments,
        .blanks = blanks,
    };
}

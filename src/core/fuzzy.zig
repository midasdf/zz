const std = @import("std");

pub const Match = struct {
    index: usize, // Index in the original list
    score: i32, // Higher = better match
};

/// Fuzzy match a query against a candidate string.
/// Returns a score > 0 if matches, 0 if no match.
pub fn score(query: []const u8, candidate: []const u8) i32 {
    if (query.len == 0) return 1; // Empty query matches everything
    if (query.len > candidate.len) return 0;

    var total: i32 = 0;
    var qi: usize = 0;
    var prev_match_idx: ?usize = null;
    var consecutive: i32 = 0;

    for (candidate, 0..) |ch, ci| {
        if (qi >= query.len) break;

        const qch = toLower(query[qi]);
        const cch = toLower(ch);

        if (qch == cch) {
            // Base match score
            total += 1;

            // Consecutive character bonus
            if (prev_match_idx) |prev| {
                if (ci == prev + 1) {
                    consecutive += 1;
                    total += consecutive * 3;
                } else {
                    consecutive = 0;
                }
            }

            // Start of word bonus (after /, ., _, -, space, or at index 0)
            if (ci == 0 or isWordBoundary(candidate[ci - 1])) {
                total += 5;
            }

            // Exact case match bonus
            if (query[qi] == ch) {
                total += 1;
            }

            prev_match_idx = ci;
            qi += 1;
        }
    }

    // All query chars must match
    if (qi < query.len) return 0;

    // Basename bonus: matches in the last path component score higher
    if (std.mem.lastIndexOfScalar(u8, candidate, '/')) |slash| {
        // Check if most matches are in the basename
        if (prev_match_idx) |last_match| {
            if (last_match > slash) {
                total += 10;
            }
        }
    }

    // Shorter candidates score slightly higher (prefer precise matches)
    const len_penalty: i32 = @intCast(@min(candidate.len, 50));
    total -= @divTrunc(len_penalty, 5);

    return @max(total, 1);
}

/// Filter and sort a list of strings by fuzzy match score.
/// Returns indices sorted by score (descending). Caller must free.
pub fn filter(
    allocator: std.mem.Allocator,
    query: []const u8,
    candidates: []const []const u8,
    max_results: usize,
) ![]Match {
    var matches: std.ArrayList(Match) = .{};
    defer matches.deinit(allocator);

    for (candidates, 0..) |cand, i| {
        const s = score(query, cand);
        if (s > 0) {
            try matches.append(allocator, .{ .index = i, .score = s });
        }
    }

    // Sort by score descending
    const items = matches.items;
    std.mem.sort(Match, items, {}, struct {
        fn cmp(_: void, a: Match, b: Match) bool {
            return a.score > b.score;
        }
    }.cmp);

    const result_len = @min(items.len, max_results);
    const result = try allocator.alloc(Match, result_len);
    @memcpy(result, items[0..result_len]);
    return result;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn isWordBoundary(c: u8) bool {
    return c == '/' or c == '.' or c == '_' or c == '-' or c == ' ' or c == '\\';
}

// Tests
test "empty query matches everything" {
    try std.testing.expect(score("", "anything") > 0);
}

test "exact match scores high" {
    const s1 = score("main", "main.zig");
    const s2 = score("main", "some/path/domain.zig");
    try std.testing.expect(s1 > s2);
}

test "no match returns 0" {
    try std.testing.expectEqual(@as(i32, 0), score("xyz", "abc"));
}

test "case insensitive" {
    try std.testing.expect(score("main", "Main.zig") > 0);
}

test "basename priority" {
    const s1 = score("view", "src/editor/view.zig");
    const s2 = score("view", "src/overview/lib.zig");
    try std.testing.expect(s1 > s2);
}

test "filter returns sorted results" {
    const candidates = [_][]const u8{
        "src/main.zig",
        "src/editor/view.zig",
        "src/ui/window.zig",
        "README.md",
    };
    const result = try filter(std.testing.allocator, "view", &candidates, 10);
    defer std.testing.allocator.free(result);
    try std.testing.expect(result.len > 0);
    try std.testing.expectEqual(@as(usize, 1), result[0].index); // view.zig should be first
}

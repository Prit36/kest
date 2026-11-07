//! JSON bracket pairing ignores string contents, including escaped quotes.
const json = @import("json.zig");
const std = @import("std");

pub fn pair(source: []const u8, caret: usize) ?[2]usize {
    const at = @min(caret, source.len);
    const target = if (at > 0 and bracket(source[at - 1])) at - 1 else if (at < source.len and bracket(source[at])) at else return null;
    var stack: [4096]usize = undefined;
    var depth: usize = 0;
    var offset: usize = 0;
    while (offset < source.len) {
        const token = json.nextToken(source, offset);
        if (token.kind == .eof or token.end <= offset) break;
        offset = token.end;
        switch (token.kind) {
            .lbrace, .lbracket => {
                if (depth == stack.len) return null;
                stack[depth] = token.start;
                depth += 1;
            },
            .rbrace, .rbracket => {
                if (depth == 0) return null;
                depth -= 1;
                const open = stack[depth];
                if ((source[open] == '{') != (token.kind == .rbrace)) return null;
                if (open == target or token.start == target) return .{ open, token.start };
            },
            else => if (target >= token.start and target < token.end) return null,
        }
    }
    return null;
}

fn bracket(byte: u8) bool {
    return byte == '{' or byte == '}' or byte == '[' or byte == ']';
}

test "JSON bracket pairs ignore quoted and escaped brackets, reject mismatches" {
    const t = std.testing;
    const source = "{\"brackets\":\"[}\\\"\",\"a\":[{}]}";
    const found = pair(source, 0).?;
    try t.expectEqual(@as(usize, 0), found[0]);
    try t.expectEqual(source.len - 1, found[1]);
    try t.expect(pair(source, 15) == null);
    try t.expect(pair("{]", 0) == null);
    try t.expect(pair("[", 1) == null);
    try t.expectEqual(@as(usize, 1), pair("[{}]", 2).?[0]);
    try t.expectEqual(@as(usize, 2), pair("[{}]", 2).?[1]);
}

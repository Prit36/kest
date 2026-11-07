//! Request view policy, independent of CUI and persisted request data.
const std = @import("std");
const request = @import("../core/request.zig");

pub const Pane = enum { params, headers, body, settings };

pub fn preferred(method: []const u8, body: request.BodyKind, params: usize, headers: usize) Pane {
    if (body != .none) return .body;
    if (params > 0) return .params;
    if (headers > 0) return .headers;
    for ([_][]const u8{ "POST", "PUT", "PATCH" }) |value| {
        if (std.ascii.eqlIgnoreCase(method, value)) return .body;
    }
    return .params;
}

test "content takes priority over method defaults" {
    const t = std.testing;
    try t.expectEqual(Pane.body, preferred("POST", .json, 3, 2));
    try t.expectEqual(Pane.body, preferred("GET", .file, 0, 0));
    try t.expectEqual(Pane.body, preferred("PUT", .multipart, 1, 0));
    try t.expectEqual(Pane.params, preferred("POST", .none, 1, 4));
    try t.expectEqual(Pane.headers, preferred("PATCH", .none, 0, 1));
    for ([_][]const u8{ "POST", "put", "PATCH" }) |method|
        try t.expectEqual(Pane.body, preferred(method, .none, 0, 0));
    try t.expectEqual(Pane.params, preferred("GET", .none, 0, 0));
}

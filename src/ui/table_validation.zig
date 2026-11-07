//! Validation does not rewrite values or include their contents in tooltips.
const std = @import("std");
const variables = @import("../core/variables.zig");
const headers = @import("../network/header_check.zig");
pub const Kind = enum {
    params,
    headers,
    form,
    variables,

    pub fn scope(kind: Kind) [*:0]const u8 {
        return switch (kind) {
            .params => "params",
            .headers => "headers",
            .form => "form",
            .variables => "variables",
        };
    }
};
pub const Problem = struct { message: ?[]const u8 = null, danger: bool = false };

pub fn check(a: std.mem.Allocator, kind: Kind, key: []const u8, value: []const u8, vars: []const variables.Var) Problem {
    for (key) |ch| if (ch < 0x20 or ch == 0x7f) return .{ .message = "The name contains a control character", .danger = true };
    if (kind == .headers or kind == .params) for (value) |ch| {
        if (ch == 0 or ch == '\r' or ch == '\n' or (kind == .params and (ch < 0x20 or ch == 0x7f))) return .{ .message = "The value contains a control character", .danger = true };
    };
    if (kind != .params and key.len == 0 and value.len > 0) return .{ .message = "A name is required; this row is not used" };
    if (kind == .variables) return .{};
    for ([_][]const u8{ key, value }) |text| {
        var from: usize = 0;
        while (variables.nextReference(text, from)) |ref| : (from = ref.end) {
            if (variables.lookup(vars, ref.name) == null) return .{ .message = "Unresolved variable; inspect the active environment" };
        }
        if (std.mem.indexOf(u8, text, "{{") != null) {
            const resolved = variables.resolve(a, text, vars) catch return .{ .message = "Couldn't validate variables" };
            if (std.mem.indexOf(u8, resolved, "{{") != null) return .{ .message = "Unresolved or malformed variable expression" };
            if (kind == .params) for (resolved) |ch| {
                if (ch < 0x20 or ch == 0x7f) return .{ .message = "The resolved cell contains a control character", .danger = true };
            };
        }
    }
    if (kind == .headers and key.len > 0) {
        const resolved_key = if (std.mem.indexOf(u8, key, "{{") != null) variables.resolve(a, key, vars) catch key else key;
        const resolved_value = if (std.mem.indexOf(u8, value, "{{") != null) variables.resolve(a, value, vars) catch value else value;
        if (!headers.validHeader(resolved_key, resolved_value)) return .{ .message = "Invalid HTTP header name or value", .danger = true };
        if (std.ascii.eqlIgnoreCase(resolved_key, "content-length")) return .{ .message = "Content-Length is managed on send; this supplied value is ignored" };
    }
    return .{};
}

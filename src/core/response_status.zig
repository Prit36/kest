//! Presentation categories do not turn HTTP 4xx/5xx into transport failures.
const response = @import("response.zig");
pub const StartFailure = enum { none, method, url, header, memory, busy };
pub const Tone = enum { neutral, success, info, warning, danger };
pub const Issue = struct { title: []const u8, hint: []const u8, tone: Tone };

pub fn startIssue(failure: StartFailure) ?Issue {
    return switch (failure) {
        .none => null,
        .method => .{ .title = "Request not sent", .hint = "Enter a valid HTTP method.", .tone = .danger },
        .url => .{ .title = "Request not sent", .hint = "Check the URL and resolve its environment variables.", .tone = .danger },
        .header => .{ .title = "Request not sent", .hint = "Check request headers and any required upload file.", .tone = .danger },
        .memory => .{ .title = "Request not sent", .hint = "Not enough memory to prepare this request. Your draft was kept.", .tone = .danger },
        .busy => .{ .title = "Request not sent", .hint = "The request could not start. Try again when fewer jobs are running.", .tone = .warning },
    };
}

pub fn issue(r: *const response.Response) ?Issue {
    if (r.spill_failed) return .{ .title = "Response storage failed", .hint = "The response could not be stored completely. Only available data can be saved.", .tone = .danger };
    return switch (r.stop) {
        .complete => if (r.error_text.len == 0) null else .{ .title = "Response error", .hint = "Open Details for the reported error.", .tone = .danger },
        .canceled => .{ .title = "Request cancelled", .hint = if (r.status > 0) "The transfer was cancelled. The received part remains available below." else "No HTTP response was received. You can send the request again.", .tone = if (r.status > 0) .warning else .neutral },
        .timed_out => .{ .title = "Request timed out", .hint = if (r.status > 0) "The transfer timed out. The received part remains available below." else "No complete response arrived before the timeout. Check request settings and try again.", .tone = if (r.status > 0) .warning else .danger },
        .too_large => .{ .title = "Response size limit reached", .hint = "The received part remains available. Increase Response limit in request settings to receive more.", .tone = .warning },
        .failed => switch (r.failure) {
            .dns => .{ .title = "DNS lookup failed", .hint = "Check the hostname and network connection.", .tone = .danger },
            .refused => .{ .title = "Connection refused", .hint = "Check the host, port and whether the server is running.", .tone = .danger },
            .unreachable_host => .{ .title = "Host unreachable", .hint = "Check the network connection and destination address.", .tone = .danger },
            .connection_lost => .{ .title = "Connection lost", .hint = if (r.status > 0) "The connection ended early. The received part remains available below." else "The connection ended before an HTTP response arrived.", .tone = .danger },
            .tls_certificate => .{ .title = "Certificate verification failed", .hint = "Check the server certificate and request TLS settings.", .tone = .danger },
            .tls_handshake => .{ .title = "TLS handshake failed", .hint = "Check the server's TLS configuration and network connection.", .tone = .danger },
            .invalid_url => .{ .title = "Invalid URL", .hint = "Check the URL and active environment variables.", .tone = .danger },
            .invalid_header => .{ .title = "Invalid request headers", .hint = "Check header names and values.", .tone = .danger },
            .too_many_redirects => .{ .title = "Redirect limit reached", .hint = "Check the redirect destination or request redirect limit.", .tone = .warning },
            .file => .{ .title = "Upload file unavailable", .hint = "Check the selected file path and read permissions.", .tone = .danger },
            .protocol => .{ .title = "Invalid HTTP response", .hint = "The server's reply could not be read as an HTTP response.", .tone = .danger },
            else => .{ .title = "Request failed", .hint = "Open Details for the reported error. Your request draft was kept.", .tone = .danger },
        },
    };
}

pub fn category(status: u16) []const u8 {
    return if (status == 0) "No HTTP response" else if (status < 100 or status >= 600) "Unrecognized HTTP status" else if (status >= 500) "Server error (HTTP 5xx)" else if (status >= 400) "Client error (HTTP 4xx)" else if (status >= 300) "Redirect (HTTP 3xx)" else if (status >= 200) "Success (HTTP 2xx)" else "Informational (HTTP 1xx)";
}

test "HTTP errors remain responses; cancellations and structured failures differ" {
    const std = @import("std");
    const t = std.testing;
    var r = response.Response.init(t.allocator, t.io, ".");
    defer r.deinit();
    r.status = 404;
    try t.expect(issue(&r) == null);
    try t.expectEqualStrings("Client error (HTTP 4xx)", category(r.status));
    r.status = 503;
    try t.expect(issue(&r) == null);
    r.status = 0;
    r.stop = .canceled;
    try t.expectEqual(Tone.neutral, issue(&r).?.tone);
    r.stop = .timed_out;
    try t.expectEqualStrings("Request timed out", issue(&r).?.title);
    r.stop = .failed;
    r.failure = .dns;
    try t.expectEqualStrings("DNS lookup failed", issue(&r).?.title);
    r.failure = .tls_certificate;
    try t.expectEqualStrings("Certificate verification failed", issue(&r).?.title);
    r.failure = .refused;
    try t.expectEqualStrings("Connection refused", issue(&r).?.title);
    r.failure = .connection_lost;
    try t.expectEqualStrings("Connection lost", issue(&r).?.title);
}

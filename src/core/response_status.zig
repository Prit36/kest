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

/// One sentence on what a status code means, for its hover card; common
/// codes have their own, the rest fall back to their class.
pub fn explain(status: u16) []const u8 {
    return switch (status) {
        100 => "The server got the request headers; the client may send the body.",
        101 => "The server is switching to the protocol the client asked for.",
        200 => "The request succeeded.",
        201 => "The request succeeded and created a resource, usually named in Location.",
        202 => "The request was accepted for processing, which hasn't finished yet.",
        204 => "The request succeeded and there is no body to return.",
        206 => "The server sent the part of the resource that the Range header asked for.",
        301 => "The resource moved for good to the URL in Location.",
        302 => "The resource is temporarily at the URL in Location.",
        303 => "The result is at the URL in Location; fetch it with GET.",
        304 => "The cached copy is still current, so no body was sent.",
        307 => "Temporarily at the URL in Location; repeat the request there unchanged.",
        308 => "Moved for good to the URL in Location; repeat the request there unchanged.",
        400 => "The server couldn't understand the request; check its syntax and body.",
        401 => "Credentials are missing or were refused; check the Authorization header.",
        403 => "The server understood the request but won't allow it with these credentials.",
        404 => "Nothing was found at this URL.",
        405 => "This URL doesn't accept this method; the Allow header lists the ones it does.",
        406 => "The server can't produce a body matching the Accept headers.",
        408 => "The server gave up waiting for the request.",
        409 => "The request conflicts with the resource's current state.",
        410 => "The resource was here but has been removed for good.",
        411 => "The server needs a Content-Length header.",
        412 => "A precondition header, such as If-Match, didn't hold.",
        413 => "The request body is larger than the server accepts.",
        414 => "The URL is longer than the server accepts.",
        415 => "The server doesn't accept the body's Content-Type.",
        418 => "The server refuses to brew coffee because it is a teapot.",
        422 => "The body was readable but its contents didn't pass validation.",
        425 => "The server won't risk processing a request that might be replayed.",
        428 => "The server needs a conditional request, such as one with If-Match.",
        429 => "Too many requests; wait before retrying, as Retry-After may say.",
        431 => "The request headers are too large.",
        451 => "The resource is unavailable for legal reasons.",
        500 => "The server hit an unexpected error while handling the request.",
        501 => "The server doesn't support what the request needs.",
        502 => "A gateway or proxy got a bad response from the server behind it.",
        503 => "The server can't handle the request right now; it may be down or overloaded.",
        504 => "A gateway or proxy timed out waiting for the server behind it.",
        505 => "The server doesn't support this HTTP version.",
        else => if (status >= 500 and status < 600) "The server failed to handle a valid request." else if (status >= 400 and status < 500) "The server says the request was wrong in some way." else if (status >= 300 and status < 400) "Further action, usually following Location, is needed." else if (status >= 200 and status < 300) "The request was received and accepted." else if (status >= 100 and status < 200) "An interim response; the final one follows." else "This code isn't one HTTP defines.",
    };
}

test "status explanations cover common codes and fall back by class" {
    const t = @import("std").testing;
    try t.expectEqualStrings("Nothing was found at this URL.", explain(404));
    try t.expectEqualStrings("The server failed to handle a valid request.", explain(599));
    try t.expectEqualStrings("The request was received and accepted.", explain(299));
    try t.expectEqualStrings("This code isn't one HTTP defines.", explain(42));
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

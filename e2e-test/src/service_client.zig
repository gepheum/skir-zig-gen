const std = @import("std");
const serializer_mod = @import("serializer.zig");

const Method = serializer_mod.Method;

/// Error returned by `ServiceClient.invokeRemote` when the server responds
/// with a non-2xx HTTP status code or when a network-level failure occurs.
pub const RpcError = struct {
    /// HTTP status code from the server, or 0 for client-side/network failures.
    status_code: u16,
    /// Human-readable error message.
    message: []const u8,
};

const Header = struct {
    /// Header name.
    key: []const u8,
    /// Header value.
    value: []const u8,
};

/// Result of a remote invocation.
///
/// - `.ok`: decoded response value.
/// - `.err`: RPC or transport error.
pub fn RpcResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: RpcError,
    };
}

/// Sends RPCs to a SkirRPC service.
pub const ServiceClient = struct {
    allocator: std.mem.Allocator,
    service_url: []const u8,
    headers: std.ArrayList(Header),

    /// Creates a client targeting `service_url`.
    ///
    /// The URL must not include a query string. Per-call data belongs in the
    /// request payload, not URL query parameters.
    pub fn init(allocator: std.mem.Allocator, service_url: []const u8) !ServiceClient {
        if (std.mem.indexOfScalar(u8, service_url, '?') != null) {
            return error.InvalidServiceUrl;
        }
        return .{
            .allocator = allocator,
            .service_url = try allocator.dupe(u8, service_url),
            .headers = .empty,
        };
    }

    /// Releases client-owned allocations.
    ///
    /// Call once when the client is no longer needed.
    pub fn deinit(self: *ServiceClient) void {
        for (self.headers.items) |h| {
            self.allocator.free(h.key);
            self.allocator.free(h.value);
        }
        self.headers.deinit(self.allocator);
        self.allocator.free(self.service_url);
    }

    /// Adds an HTTP header sent with every invocation.
    ///
    /// Can be chained while setting up the client.
    pub fn addHeader(self: *ServiceClient, key: []const u8, value: []const u8) !*ServiceClient {
        try self.headers.append(self.allocator, .{
            .key = try self.allocator.dupe(u8, key),
            .value = try self.allocator.dupe(u8, value),
        });
        return self;
    }

    /// Invokes a remote method and returns either a decoded response or
    /// `RpcError`.
    ///
    /// The request is serialized using dense JSON. Successful responses are
    /// deserialized while keeping unrecognized values so the client can talk to
    /// a newer server schema when possible.
    ///
    /// For errors:
    /// - non-2xx HTTP responses become `RpcError` with the server status code;
    /// - transport/client failures use `status_code = 0`.
    ///
    /// Example:
    /// ```zig
    /// var client = try skir_client.ServiceClient.init(allocator, "http://127.0.0.1:18787/myapi");
    /// defer client.deinit();
    ///
    /// _ = try client.addHeader("Authorization", "Bearer <token>");
    ///
    /// const result = try client.invokeRemote(
    ///     GetUserRequest,
    ///     GetUserResponse,
    ///     &service_mod.get_user_method(),
    ///     &.{ .user_id = 42, ._unrecognized = null },
    /// );
    /// ```
    pub fn invokeRemote(
        self: *const ServiceClient,
        comptime Req: type,
        comptime Resp: type,
        method: *const Method(Req, Resp),
        request: *const Req,
    ) !RpcResult(Resp) {
        const request_json = method.request_serializer.serialize(self.allocator, request.*, .{ .format = .denseJson }) catch |err| {
            return RpcResult(Resp){ .err = .{ .status_code = 0, .message = try std.fmt.allocPrint(self.allocator, "failed to encode request: {s}", .{@errorName(err)}) } };
        };
        defer self.allocator.free(request_json);

        const wire_body = try std.fmt.allocPrint(self.allocator, "{s}:{d}::{s}", .{ method.name, method.number, request_json });
        defer self.allocator.free(wire_body);

        const parsed = parseServiceUrl(self.service_url) catch |err| {
            return RpcResult(Resp){ .err = .{ .status_code = 0, .message = try std.fmt.allocPrint(self.allocator, "invalid service URL: {s}", .{@errorName(err)}) } };
        };

        const response = doHttpPost(self.allocator, parsed, wire_body, self.headers.items) catch |err| {
            return RpcResult(Resp){ .err = .{ .status_code = 0, .message = try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)}) } };
        };
        defer self.allocator.free(response.content_type);
        defer self.allocator.free(response.body);

        if (response.status_code < 200 or response.status_code >= 300) {
            const msg = if (std.mem.indexOf(u8, response.content_type, "text/plain") != null)
                try self.allocator.dupe(u8, response.body)
            else
                try self.allocator.dupe(u8, "");
            return RpcResult(Resp){ .err = .{ .status_code = response.status_code, .message = msg } };
        }

        const value = method.response_serializer.deserialize(self.allocator, response.body, .{ .keepUnrecognizedValues = true }) catch |err| {
            return RpcResult(Resp){ .err = .{ .status_code = 0, .message = try std.fmt.allocPrint(self.allocator, "failed to decode response: {s}", .{@errorName(err)}) } };
        };

        return RpcResult(Resp){ .ok = value };
    }
};

const ParsedServiceUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseServiceUrl(url: []const u8) !ParsedServiceUrl {
    const prefix = "http://";
    if (!std.mem.startsWith(u8, url, prefix)) return error.UnsupportedScheme;

    const rest = url[prefix.len..];
    const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash_idx];
    const path = if (slash_idx < rest.len) rest[slash_idx..] else "/";

    const colon_idx = std.mem.lastIndexOfScalar(u8, host_port, ':');
    if (colon_idx) |idx| {
        const host = host_port[0..idx];
        const port = try std.fmt.parseInt(u16, host_port[idx + 1 ..], 10);
        if (host.len == 0) return error.InvalidHost;
        return .{ .host = host, .port = port, .path = path };
    }

    if (host_port.len == 0) return error.InvalidHost;
    return .{ .host = host_port, .port = 80, .path = path };
}

const HttpResponse = struct {
    status_code: u16,
    content_type: []u8,
    body: []u8,
};

fn doHttpPost(
    allocator: std.mem.Allocator,
    parsed: ParsedServiceUrl,
    body: []const u8,
    headers: []const Header,
) !HttpResponse {
    const stream = try std.net.tcpConnectToHost(allocator, parsed.host, parsed.port);
    defer stream.close();

    var line_buf: [256]u8 = undefined;
    const request_line = try std.fmt.bufPrint(&line_buf, "POST {s} HTTP/1.1\r\n", .{parsed.path});
    try stream.writeAll(request_line);
    const host_line = try std.fmt.bufPrint(&line_buf, "Host: {s}\r\n", .{parsed.host});
    try stream.writeAll(host_line);
    try stream.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
    const content_len_line = try std.fmt.bufPrint(&line_buf, "Content-Length: {d}\r\n", .{body.len});
    try stream.writeAll(content_len_line);
    try stream.writeAll("Connection: close\r\n");
    for (headers) |h| {
        const header_line = try std.fmt.bufPrint(&line_buf, "{s}: {s}\r\n", .{ h.key, h.value });
        try stream.writeAll(header_line);
    }
    try stream.writeAll("\r\n");
    try stream.writeAll(body);

    var raw_list = std.ArrayList(u8).empty;
    defer raw_list.deinit(allocator);

    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = try stream.read(&read_buf);
        if (n == 0) break;
        try raw_list.appendSlice(allocator, read_buf[0..n]);
        if (raw_list.items.len > 8 * 1024 * 1024) return error.ResponseTooLarge;
    }

    const raw = raw_list.items;

    const headers_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidHttpResponse;
    const headers_block = raw[0..headers_end];
    const body_slice = raw[headers_end + 4 ..];

    const line_end = std.mem.indexOf(u8, headers_block, "\r\n") orelse headers_block.len;
    const status_line = headers_block[0..line_end];
    var status_it = std.mem.splitScalar(u8, status_line, ' ');
    _ = status_it.next();
    const status_code_str = status_it.next() orelse return error.InvalidHttpResponse;
    const status_code = try std.fmt.parseInt(u16, status_code_str, 10);

    const content_type = try headerValue(allocator, headers_block, "content-type");
    const body_copy = try allocator.dupe(u8, body_slice);

    return .{
        .status_code = status_code,
        .content_type = content_type,
        .body = body_copy,
    };
}

fn headerValue(allocator: std.mem.Allocator, headers_block: []const u8, key_lower: []const u8) ![]u8 {
    var it = std.mem.splitSequence(u8, headers_block, "\r\n");
    _ = it.next(); // status line
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const k = std.mem.trim(u8, line[0..colon], " ");
        if (std.ascii.eqlIgnoreCase(k, key_lower)) {
            const v = std.mem.trim(u8, line[colon + 1 ..], " ");
            return allocator.dupe(u8, v);
        }
    }
    return allocator.dupe(u8, "");
}

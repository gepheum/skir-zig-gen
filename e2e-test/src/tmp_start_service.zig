// TEMPORARY SCRIPT: starts a SkirRPC service on http://127.0.0.1:18787/myapi
//
// Run with:
//   zig run src/tmp_start_service.zig
//
// Remove this file (and tmp_call_service.zig) when no longer needed.

const std = @import("std");
const skir_client = @import("skir_client.zig");
const service_mod = @import("skirout/service.zig");
const service_user_mod = @import("skirout/service_user.zig");

const User = service_user_mod.User;
const GetUserRequest = service_mod.GetUserRequest;
const GetUserResponse = service_mod.GetUserResponse;
const AddUserRequest = service_mod.AddUserRequest;
const AddUserResponse = service_mod.AddUserResponse;

const UserStore = std.AutoHashMap(i32, User);

var g_store: ?*UserStore = null;
var g_store_mutex: std.Thread.Mutex = .{};

fn get_user_impl(_: std.mem.Allocator, req: GetUserRequest, _: void) skir_client.MethodResult(GetUserResponse) {
    const store = g_store orelse return .{ .unknown_error = "store not initialized" };
    g_store_mutex.lock();
    defer g_store_mutex.unlock();
    const user = store.get(req.user_id);
    return .{ .ok = .{
        .user = user,
        ._unrecognized = null,
    } };
}

fn add_user_impl(_: std.mem.Allocator, req: AddUserRequest, _: void) skir_client.MethodResult(AddUserResponse) {
    if (req.user.user_id == 0) {
        return .{ .service_error = .{
            .status_code = ._400_BadRequest,
            .message = "user_id must be non-zero",
        } };
    }

    const store = g_store orelse return .{ .unknown_error = "store not initialized" };
    g_store_mutex.lock();
    defer g_store_mutex.unlock();
    store.put(req.user.user_id, req.user) catch return .{ .unknown_error = "failed to persist user" };
    return .{ .ok = .{
        ._unrecognized = null,
    } };
}

const ParsedRequest = struct {
    method: []const u8,
    target: []const u8,
    body: []u8,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var store = std.AutoHashMap(i32, User).init(allocator);
    defer store.deinit();
    g_store = &store;

    var service = try skir_client.Service(void).init(allocator);
    _ = try service.addMethod(GetUserRequest, GetUserResponse, &service_mod.get_user_method(), get_user_impl);
    _ = try service.addMethod(AddUserRequest, AddUserResponse, &service_mod.add_user_method(), add_user_impl);
    defer service.deinit();

    const addr = try std.net.Address.parseIp("127.0.0.1", 18787);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Listening on http://127.0.0.1:18787/myapi\n", .{});

    while (true) {
        var conn = try server.accept();
        defer conn.stream.close();
        handleConnection(allocator, &service, conn.stream) catch |err| {
            std.debug.print("request handling error: {s}\n", .{@errorName(err)});
        };
    }
}

fn handleConnection(allocator: std.mem.Allocator, service: *skir_client.Service(void), stream: std.net.Stream) !void {
    const req = try readRequest(allocator, stream);
    defer allocator.free(req.method);
    defer allocator.free(req.target);
    defer allocator.free(req.body);

    var body_for_service: []u8 = undefined;
    defer allocator.free(body_for_service);

    if (std.mem.eql(u8, req.method, "GET")) {
        const q = if (std.mem.indexOfScalar(u8, req.target, '?')) |idx| req.target[idx + 1 ..] else "";
        body_for_service = try percentDecodeQuery(allocator, q);
    } else {
        body_for_service = try allocator.dupe(u8, req.body);
    }

    var request_arena = std.heap.ArenaAllocator.init(allocator);
    defer request_arena.deinit();
    const request_allocator = request_arena.allocator();

    const raw_response = try service.handleRequest(request_allocator, body_for_service, {});

    try stream.writeAll(raw_response.status_line);
    var line_buf: [128]u8 = undefined;
    const content_type_line = try std.fmt.bufPrint(&line_buf, "Content-Type: {s}\r\n", .{raw_response.content_type});
    try stream.writeAll(content_type_line);
    const content_len_line = try std.fmt.bufPrint(&line_buf, "Content-Length: {d}\r\n", .{raw_response.data.len});
    try stream.writeAll(content_len_line);
    try stream.writeAll("Connection: close\r\n\r\n");
    try stream.writeAll(raw_response.data);
}

fn readRequest(allocator: std.mem.Allocator, stream: std.net.Stream) !ParsedRequest {
    var raw_list = std.ArrayList(u8).empty;
    defer raw_list.deinit(allocator);

    var header_end: ?usize = null;
    var content_length: usize = 0;
    var expected_total: ?usize = null;

    var buf: [2048]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) break;
        try raw_list.appendSlice(allocator, buf[0..n]);
        if (raw_list.items.len > 8 * 1024 * 1024) return error.RequestTooLarge;

        if (header_end == null) {
            if (std.mem.indexOf(u8, raw_list.items, "\r\n\r\n")) |idx| {
                header_end = idx;

                const headers_block = raw_list.items[0..idx];
                var lines = std.mem.splitSequence(u8, headers_block, "\r\n");
                _ = lines.next();
                while (lines.next()) |line| {
                    if (std.mem.indexOfScalar(u8, line, ':')) |sep| {
                        const key = std.mem.trim(u8, line[0..sep], " ");
                        const value = std.mem.trim(u8, line[sep + 1 ..], " ");
                        if (std.ascii.eqlIgnoreCase(key, "content-length")) {
                            content_length = std.fmt.parseInt(usize, value, 10) catch 0;
                        }
                    }
                }

                expected_total = idx + 4 + content_length;
            }
        }

        if (expected_total) |need| {
            if (raw_list.items.len >= need) break;
        }
    }

    const raw = raw_list.items;

    const headers_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadRequest;
    const headers_block = raw[0..headers_end];
    const body_slice = raw[headers_end + 4 ..];

    const first_line_end = std.mem.indexOf(u8, headers_block, "\r\n") orelse headers_block.len;
    const request_line = headers_block[0..first_line_end];

    var req_it = std.mem.splitScalar(u8, request_line, ' ');
    const method = req_it.next() orelse return error.BadRequest;
    const target = req_it.next() orelse return error.BadRequest;

    content_length = body_slice.len;
    var lines = std.mem.splitSequence(u8, headers_block, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, ':')) |idx| {
            const key = std.mem.trim(u8, line[0..idx], " ");
            const value = std.mem.trim(u8, line[idx + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(key, "content-length")) {
                content_length = std.fmt.parseInt(usize, value, 10) catch body_slice.len;
            }
        }
    }

    if (content_length > body_slice.len) return error.BadRequest;
    const body = try allocator.dupe(u8, body_slice[0..content_length]);

    return .{
        .method = try allocator.dupe(u8, method),
        .target = try allocator.dupe(u8, target),
        .body = body,
    };
}

fn percentDecodeQuery(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                try out.append(allocator, c);
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                try out.append(allocator, c);
                continue;
            };
            try out.append(allocator, @as(u8, @intCast((hi << 4) | lo)));
            i += 2;
        } else if (c == '+') {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, c);
        }
    }

    return out.toOwnedSlice(allocator);
}

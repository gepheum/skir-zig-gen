const std = @import("std");
const serializer_mod = @import("serializer.zig");
const type_descriptor = @import("type_descriptor.zig");

const SerializeFormat = serializer_mod.SerializeFormat;
const Method = serializer_mod.Method;

// =============================================================================
// RawResponse
// =============================================================================

pub const RawResponse = struct {
    data: []const u8,
    status_code: u16,
    content_type: []const u8,

    fn okJson(data: []const u8) RawResponse {
        return .{
            .data = data,
            .status_code = 200,
            .content_type = "application/json",
        };
    }

    fn okHtml(data: []const u8) RawResponse {
        return .{
            .data = data,
            .status_code = 200,
            .content_type = "text/html; charset=utf-8",
        };
    }

    fn badRequest(msg: []const u8) RawResponse {
        return .{
            .data = msg,
            .status_code = 400,
            .content_type = "text/plain; charset=utf-8",
        };
    }

    fn serverError(msg: []const u8, status_code: u16) RawResponse {
        return .{
            .data = msg,
            .status_code = status_code,
            .content_type = "text/plain; charset=utf-8",
        };
    }
};

// =============================================================================
// HttpErrorCode
// =============================================================================

pub const HttpErrorCode = enum(u16) {
    _400_BadRequest = 400,
    _401_Unauthorized = 401,
    _402_PaymentRequired = 402,
    _403_Forbidden = 403,
    _404_NotFound = 404,
    _405_MethodNotAllowed = 405,
    _406_NotAcceptable = 406,
    _407_ProxyAuthenticationRequired = 407,
    _408_RequestTimeout = 408,
    _409_Conflict = 409,
    _410_Gone = 410,
    _411_LengthRequired = 411,
    _412_PreconditionFailed = 412,
    _413_ContentTooLarge = 413,
    _414_UriTooLong = 414,
    _415_UnsupportedMediaType = 415,
    _416_RangeNotSatisfiable = 416,
    _417_ExpectationFailed = 417,
    _418_ImATeapot = 418,
    _421_MisdirectedRequest = 421,
    _422_UnprocessableContent = 422,
    _423_Locked = 423,
    _424_FailedDependency = 424,
    _425_TooEarly = 425,
    _426_UpgradeRequired = 426,
    _428_PreconditionRequired = 428,
    _429_TooManyRequests = 429,
    _431_RequestHeaderFieldsTooLarge = 431,
    _451_UnavailableForLegalReasons = 451,
    _500_InternalServerError = 500,
    _501_NotImplemented = 501,
    _502_BadGateway = 502,
    _503_ServiceUnavailable = 503,
    _504_GatewayTimeout = 504,
    _505_HttpVersionNotSupported = 505,
    _506_VariantAlsoNegotiates = 506,
    _507_InsufficientStorage = 507,
    _508_LoopDetected = 508,
    _510_NotExtended = 510,
    _511_NetworkAuthenticationRequired = 511,

    pub fn asU16(self: HttpErrorCode) u16 {
        return @intFromEnum(self);
    }
};

// =============================================================================
// ServiceError
// =============================================================================

pub const ServiceError = struct {
    status_code: HttpErrorCode,
    message: []const u8,
};

pub fn MethodResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        service_error: ServiceError,
        unknown_error: []const u8,
    };
}

pub fn MethodErrorInfo(comptime Meta: type) type {
    return struct {
        method_name: []const u8,
        raw_request: []const u8,
        request_meta: Meta,
        error_message: []const u8,
        service_error: ?ServiceError,
    };
}

const DEFAULT_STUDIO_APP_JS_URL = "https://cdn.jsdelivr.net/npm/skir-studio/dist/skir-studio-standalone.js";

fn InvokeOutcome(comptime Meta: type) type {
    _ = Meta;
    return union(enum) {
        ok_json: []const u8,
        service_error: ServiceError,
        unknown_error: []const u8,
    };
}

fn MethodEntry(comptime Meta: type) type {
    return struct {
        name: []const u8,
        number: i64,
        doc: []const u8,
        request_type_descriptor_json: []const u8,
        response_type_descriptor_json: []const u8,
        invoke_fn: *const fn (std.mem.Allocator, []const u8, bool, bool, Meta) anyerror!InvokeOutcome(Meta),
    };
}

pub fn Service(comptime Meta: type) type {
    return struct {
        const Self = @This();
        const Entry = MethodEntry(Meta);
        const ErrorInfo = MethodErrorInfo(Meta);

        allocator: std.mem.Allocator,
        keep_unrecognized_values: bool,
        can_send_unknown_error_message_fn: *const fn (*const ErrorInfo) bool,
        error_logger_fn: *const fn (*const ErrorInfo) void,
        studio_app_js_url: []const u8,
        by_num: std.AutoHashMap(i64, Entry),
        by_name: std.StringHashMap(i64),

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .allocator = allocator,
                .keep_unrecognized_values = false,
                .can_send_unknown_error_message_fn = defaultCanSendUnknownErrorMessage(Meta),
                .error_logger_fn = defaultErrorLogger(Meta),
                .studio_app_js_url = try allocator.dupe(u8, DEFAULT_STUDIO_APP_JS_URL),
                .by_num = std.AutoHashMap(i64, Entry).init(allocator),
                .by_name = std.StringHashMap(i64).init(allocator),
            };
        }

        pub fn setKeepUnrecognizedValues(self: *Self, keep: bool) *Self {
            self.keep_unrecognized_values = keep;
            return self;
        }

        pub fn setCanSendUnknownErrorMessage(self: *Self, can: bool) *Self {
            if (can) {
                self.can_send_unknown_error_message_fn = alwaysTrueCanSend(Meta);
            } else {
                self.can_send_unknown_error_message_fn = alwaysFalseCanSend(Meta);
            }
            return self;
        }

        pub fn setCanSendUnknownErrorMessageFn(self: *Self, f: *const fn (*const ErrorInfo) bool) *Self {
            self.can_send_unknown_error_message_fn = f;
            return self;
        }

        pub fn setErrorLogger(self: *Self, logger: *const fn (*const ErrorInfo) void) *Self {
            self.error_logger_fn = logger;
            return self;
        }

        pub fn setStudioAppJsUrl(self: *Self, url: []const u8) !*Self {
            self.allocator.free(self.studio_app_js_url);
            self.studio_app_js_url = try self.allocator.dupe(u8, url);
            return self;
        }

        pub fn addMethod(
            self: *Self,
            comptime Req: type,
            comptime Resp: type,
            comptime method: *const Method(Req, Resp),
            comptime impl_fn: *const fn (std.mem.Allocator, Req, Meta) MethodResult(Resp),
        ) !*Self {
            const number: i64 = method.number;
            if (self.by_num.contains(number)) {
                return error.DuplicateMethodNumber;
            }

            const req_td = try method.request_serializer.typeDescriptor(self.allocator);
            const req_td_json = try type_descriptor.typeDescriptorToJson(self.allocator, req_td);
            const resp_td = try method.response_serializer.typeDescriptor(self.allocator);
            const resp_td_json = try type_descriptor.typeDescriptorToJson(self.allocator, resp_td);

            const entry: Entry = .{
                .name = try self.allocator.dupe(u8, method.name),
                .number = number,
                .doc = try self.allocator.dupe(u8, method.doc),
                .request_type_descriptor_json = req_td_json,
                .response_type_descriptor_json = resp_td_json,
                .invoke_fn = struct {
                    fn invoke(allocator: std.mem.Allocator, request_json: []const u8, keep_unrecognized: bool, readable: bool, meta: Meta) anyerror!InvokeOutcome(Meta) {
                        const req = serializerDeserialize(Req, method.request_serializer, allocator, request_json, keep_unrecognized) catch |err| {
                            const msg = try std.fmt.allocPrint(allocator, "bad request: can't parse JSON: {s}", .{@errorName(err)});
                            return .{ .service_error = .{
                                .status_code = ._400_BadRequest,
                                .message = msg,
                            } };
                        };

                        switch (impl_fn(allocator, req, meta)) {
                            .ok => |resp| {
                                const fmt: SerializeFormat = if (readable) .readableJson else .denseJson;
                                const response_json = try method.response_serializer.serialize(allocator, resp, .{ .format = fmt });
                                return .{ .ok_json = response_json };
                            },
                            .service_error => |svc| return .{ .service_error = svc },
                            .unknown_error => |m| return .{ .unknown_error = m },
                        }
                    }
                }.invoke,
            };

            try self.by_name.put(try self.allocator.dupe(u8, method.name), number);
            try self.by_num.put(number, entry);
            return self;
        }

        pub fn deinit(self: *Self) void {
            var by_num_it = self.by_num.iterator();
            while (by_num_it.next()) |kv| {
                const e = kv.value_ptr.*;
                self.allocator.free(e.name);
                self.allocator.free(e.doc);
                self.allocator.free(e.request_type_descriptor_json);
                self.allocator.free(e.response_type_descriptor_json);
            }
            self.by_num.deinit();

            var by_name_it = self.by_name.iterator();
            while (by_name_it.next()) |kv| {
                self.allocator.free(kv.key_ptr.*);
            }
            self.by_name.deinit();
            self.allocator.free(self.studio_app_js_url);
        }

        pub fn handleRequest(self: *const Self, allocator: std.mem.Allocator, body: []const u8, meta: Meta) !RawResponse {
            if (std.mem.eql(u8, body, "") or std.mem.eql(u8, body, "studio")) {
                return serveStudio(allocator, self.studio_app_js_url);
            }
            if (std.mem.eql(u8, body, "list")) {
                return self.serveList(allocator);
            }

            const first = if (body.len > 0) body[0] else ' ';
            if (first == '{' or std.ascii.isWhitespace(first)) {
                return self.handleJsonRequest(allocator, body, meta);
            }
            return self.handleColonRequest(allocator, body, meta);
        }

        fn serveList(self: *const Self, allocator: std.mem.Allocator) !RawResponse {
            const entries = try allocator.alloc(Entry, self.by_num.count());
            defer allocator.free(entries);

            var i: usize = 0;
            var it = self.by_num.valueIterator();
            while (it.next()) |entry_ptr| : (i += 1) {
                entries[i] = entry_ptr.*;
            }
            std.sort.pdq(Entry, entries, {}, struct {
                fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
                    return lhs.number < rhs.number;
                }
            }.lessThan);

            var out = std.ArrayList(u8).empty;
            defer out.deinit(allocator);

            try out.appendSlice(allocator, "{\"methods\":[");
            for (entries, 0..) |e, idx| {
                if (idx != 0) try out.append(allocator, ',');
                try out.appendSlice(allocator, "{\"method\":");
                try appendJsonString(&out, allocator, e.name);
                try out.appendSlice(allocator, ",\"number\":");
                try std.fmt.format(out.writer(allocator), "{d}", .{e.number});
                try out.appendSlice(allocator, ",\"request\":");
                try appendRawJsonOrNull(&out, allocator, e.request_type_descriptor_json);
                try out.appendSlice(allocator, ",\"response\":");
                try appendRawJsonOrNull(&out, allocator, e.response_type_descriptor_json);
                if (e.doc.len > 0) {
                    try out.appendSlice(allocator, ",\"doc\":");
                    try appendJsonString(&out, allocator, e.doc);
                }
                try out.append(allocator, '}');
            }
            try out.appendSlice(allocator, "]}");

            return RawResponse.okJson(try out.toOwnedSlice(allocator));
        }

        fn handleJsonRequest(self: *const Self, allocator: std.mem.Allocator, body: []const u8, meta: Meta) !RawResponse {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
                return RawResponse.badRequest("bad request: invalid JSON");
            };
            defer parsed.deinit();

            const obj = if (parsed.value == .object) parsed.value.object else {
                return RawResponse.badRequest("bad request: expected JSON object");
            };

            const method_val = obj.get("method") orelse {
                return RawResponse.badRequest("bad request: missing 'method' field in JSON");
            };

            const entry = switch (method_val) {
                .integer => |n| self.by_num.get(@intCast(n)) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "bad request: method not found: {d}", .{n});
                    return RawResponse.badRequest(msg);
                },
                .string => |name| blk: {
                    const number = self.by_name.get(name) orelse {
                        const msg = try std.fmt.allocPrint(allocator, "bad request: method not found: {s}", .{name});
                        return RawResponse.badRequest(msg);
                    };
                    break :blk self.by_num.get(number).?;
                },
                else => return RawResponse.badRequest("bad request: 'method' field must be a string or integer"),
            };

            const request_val = obj.get("request") orelse {
                return RawResponse.badRequest("bad request: missing 'request' field in JSON");
            };
            const request_json = try std.json.Stringify.valueAlloc(allocator, request_val, .{});
            defer allocator.free(request_json);

            return self.invokeEntry(allocator, entry, request_json, self.keep_unrecognized_values, true, meta);
        }

        fn handleColonRequest(self: *const Self, allocator: std.mem.Allocator, body: []const u8, meta: Meta) !RawResponse {
            var it = std.mem.splitScalar(u8, body, ':');
            const name_str = it.next() orelse return RawResponse.badRequest("bad request: invalid request format");
            const number_str = it.next() orelse return RawResponse.badRequest("bad request: invalid request format");
            const format_str = it.next() orelse return RawResponse.badRequest("bad request: invalid request format");
            const request_json_raw = it.rest();

            const request_json = if (request_json_raw.len == 0) "{}" else request_json_raw;
            const entry = if (number_str.len == 0) blk: {
                const number = self.by_name.get(name_str) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "bad request: method not found: {s}", .{name_str});
                    return RawResponse.badRequest(msg);
                };
                break :blk self.by_num.get(number).?;
            } else blk: {
                const number = std.fmt.parseInt(i64, number_str, 10) catch {
                    return RawResponse.badRequest("bad request: can't parse method number");
                };
                break :blk self.by_num.get(number) orelse {
                    const msg = try std.fmt.allocPrint(allocator, "bad request: method not found: {s}; number: {d}", .{ name_str, number });
                    return RawResponse.badRequest(msg);
                };
            };

            const readable = std.mem.eql(u8, format_str, "readable");
            return self.invokeEntry(allocator, entry, request_json, self.keep_unrecognized_values, readable, meta);
        }

        fn invokeEntry(
            self: *const Self,
            allocator: std.mem.Allocator,
            entry: Entry,
            request_json: []const u8,
            keep_unrecognized: bool,
            readable: bool,
            meta: Meta,
        ) !RawResponse {
            const raw_request = try allocator.dupe(u8, request_json);
            defer allocator.free(raw_request);

            const outcome = entry.invoke_fn(allocator, request_json, keep_unrecognized, readable, meta) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
                defer allocator.free(msg);
                const info: ErrorInfo = .{
                    .method_name = entry.name,
                    .raw_request = raw_request,
                    .request_meta = meta,
                    .error_message = msg,
                    .service_error = null,
                };
                self.error_logger_fn(&info);

                const out_msg = if (self.can_send_unknown_error_message_fn(&info))
                    try std.fmt.allocPrint(allocator, "server error: {s}", .{msg})
                else
                    try allocator.dupe(u8, "server error");
                return RawResponse.serverError(out_msg, 500);
            };

            switch (outcome) {
                .ok_json => |response_json| return RawResponse.okJson(response_json),
                .service_error => |svc| {
                    const info: ErrorInfo = .{
                        .method_name = entry.name,
                        .raw_request = raw_request,
                        .request_meta = meta,
                        .error_message = svc.message,
                        .service_error = svc,
                    };
                    self.error_logger_fn(&info);
                    const msg = if (svc.message.len == 0)
                        try allocator.dupe(u8, httpStatusText(svc.status_code.asU16()))
                    else
                        try allocator.dupe(u8, svc.message);
                    return RawResponse.serverError(msg, svc.status_code.asU16());
                },
                .unknown_error => |err_msg| {
                    const info: ErrorInfo = .{
                        .method_name = entry.name,
                        .raw_request = raw_request,
                        .request_meta = meta,
                        .error_message = err_msg,
                        .service_error = null,
                    };
                    self.error_logger_fn(&info);
                    const msg = if (self.can_send_unknown_error_message_fn(&info))
                        try std.fmt.allocPrint(allocator, "server error: {s}", .{err_msg})
                    else
                        try allocator.dupe(u8, "server error");
                    return RawResponse.serverError(msg, 500);
                },
            }
        }
    };
}

fn serializerDeserialize(
    comptime Req: type,
    ser: serializer_mod.Serializer(Req),
    allocator: std.mem.Allocator,
    request_json: []const u8,
    keep_unrecognized: bool,
) !Req {
    return ser.deserialize(allocator, request_json, .{ .keepUnrecognizedValues = keep_unrecognized });
}

fn appendRawJsonOrNull(out: *std.ArrayList(u8), allocator: std.mem.Allocator, source: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch {
        try out.appendSlice(allocator, "null");
        return;
    };
    parsed.deinit();
    try out.appendSlice(allocator, source);
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => if (c < 0x20) {
                try std.fmt.format(out.writer(allocator), "\\u{X:0>4}", .{c});
            } else {
                try out.append(allocator, c);
            },
        }
    }
    try out.append(allocator, '"');
}

fn serveStudio(allocator: std.mem.Allocator, js_url: []const u8) !RawResponse {
    return RawResponse.okHtml(try studioHtml(allocator, js_url));
}

fn studioHtml(allocator: std.mem.Allocator, js_url: []const u8) ![]u8 {
    const safe = try htmlEscapeAttr(allocator, js_url);
    defer allocator.free(safe);
    return std.fmt.allocPrint(
        allocator,
        "<!DOCTYPE html><html>  <head>    <meta charset=\"utf-8\" />    <title>RPC Studio</title>    <link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>🐙</text></svg>\">    <script src=\"{s}\"></script>  </head>  <body style=\"margin: 0; padding: 0;\">    <skir-studio-app></skir-studio-app>  </body></html>",
        .{safe},
    );
}

fn htmlEscapeAttr(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '"' => try out.appendSlice(allocator, "&#34;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn httpStatusText(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Error",
    };
}

fn defaultCanSendUnknownErrorMessage(comptime Meta: type) fn (*const MethodErrorInfo(Meta)) bool {
    return struct {
        fn f(_: *const MethodErrorInfo(Meta)) bool {
            return false;
        }
    }.f;
}

fn alwaysTrueCanSend(comptime Meta: type) fn (*const MethodErrorInfo(Meta)) bool {
    return struct {
        fn f(_: *const MethodErrorInfo(Meta)) bool {
            return true;
        }
    }.f;
}

fn alwaysFalseCanSend(comptime Meta: type) fn (*const MethodErrorInfo(Meta)) bool {
    return struct {
        fn f(_: *const MethodErrorInfo(Meta)) bool {
            return false;
        }
    }.f;
}

fn defaultErrorLogger(comptime Meta: type) fn (*const MethodErrorInfo(Meta)) void {
    return struct {
        fn f(info: *const MethodErrorInfo(Meta)) void {
            std.debug.print("skir: error in method {s}: {s}\n", .{ info.method_name, info.error_message });
        }
    }.f;
}

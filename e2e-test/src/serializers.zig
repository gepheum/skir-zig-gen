const std = @import("std");

// =============================================================================
// UnrecognizedFields
// =============================================================================

/// Holds raw field data encountered during deserialization that does not
/// correspond to any declared field in the struct.
///
/// Every generated struct has a `_unrecognized: ?UnrecognizedFields = null`
/// field. Assign it `null` when constructing a struct — the deserializer fills
/// it in automatically when needed. You never need to read or write this field
/// in normal usage.
pub const UnrecognizedFields = struct {
    // The real library stores raw deserialized field bytes here.
    // This stub is a placeholder — instances are never created directly by
    // user code (the `_unrecognized` field always starts as null).
};

// =============================================================================
// Timestamp
// =============================================================================

/// An instant in time, represented as milliseconds since the Unix epoch.
pub const Timestamp = struct {
    unix_millis: i64 = 0,

    /// The Unix epoch (1970-01-01T00:00:00Z).
    pub const epoch: Timestamp = .{};
};

// =============================================================================
// Serializer
// =============================================================================

/// Output format for `Serializer.serialize`.
pub const SerializeFormat = enum {
    /// Dense JSON: field-index-based array layout. Safe for persistent storage
    /// and transport — renaming a field does not break deserialization.
    denseJson,
    /// Readable JSON: field-name-based with indentation. For debugging only.
    readableJson,
    /// Compact binary encoding, prefixed with the four-byte magic `"skir"`.
    binary,
};

/// A value that can serialize and deserialize values of type `T`.
///
/// Obtain instances via the factory functions (`boolSerializer`, etc.).
/// Default-initialize one (`Serializer(MyRecord){}`) for generated record types.
///
/// For primitive serializers the vtable points to comptime-generated constants,
/// so the `Serializer` is a thin single-pointer value with no heap allocation.
pub fn Serializer(comptime T: type) type {
    return struct {
        const Self = @This();

        // Each concrete adapter is a zero-size struct, so all behaviour is
        // comptime-constant. The vtable holds plain function pointers with no
        // runtime context pointer.
        pub const VTable = struct {
            toJsonFn: *const fn (std.mem.Allocator, T, ?[]const u8, *std.ArrayList(u8)) anyerror!void,
            fromJsonFn: *const fn (std.mem.Allocator, std.json.Value, bool) anyerror!T,
            encodeFn: *const fn (std.mem.Allocator, T, *std.ArrayList(u8)) anyerror!void,
            decodeFn: *const fn (std.mem.Allocator, *[]const u8, bool) anyerror!T,
            typeDescriptorFn: *const fn () TypeDescriptor,
        };

        fn vtableFor(comptime Impl: type) *const VTable {
            return &struct {
                fn doTypeDescriptor() TypeDescriptor {
                    const impl: Impl = .{};
                    return impl.typeDescriptor();
                }

                fn doToJson(alloc: std.mem.Allocator, value: T, eol: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
                    const impl: Impl = .{};
                    return impl.toJson(alloc, value, eol, out);
                }

                fn doFromJson(alloc: std.mem.Allocator, json: std.json.Value, keep: bool) anyerror!T {
                    const impl: Impl = .{};
                    return impl.fromJson(alloc, json, keep);
                }

                fn doEncode(alloc: std.mem.Allocator, value: T, out: *std.ArrayList(u8)) anyerror!void {
                    const impl: Impl = .{};
                    return impl.encode(alloc, value, out);
                }

                fn doDecode(alloc: std.mem.Allocator, input: *[]const u8, keep: bool) anyerror!T {
                    const impl: Impl = .{};
                    return impl.decode(alloc, input, keep);
                }

                const vt: VTable = .{
                    .toJsonFn = doToJson,
                    .fromJsonFn = doFromJson,
                    .encodeFn = doEncode,
                    .decodeFn = doDecode,
                    .typeDescriptorFn = doTypeDescriptor,
                };
            }.vt;
        }

        // Stub implementation for default-initialized Serializers (generated
        // record types fill this in via their own generated adapter).
        const StubImpl = struct {
            pub fn toJson(_: @This(), _: std.mem.Allocator, _: T, _: ?[]const u8, _: *std.ArrayList(u8)) anyerror!void {}
            pub fn fromJson(_: @This(), _: std.mem.Allocator, _: std.json.Value, _: bool) anyerror!T {
                return error.Stub;
            }
            pub fn encode(_: @This(), _: std.mem.Allocator, _: T, _: *std.ArrayList(u8)) anyerror!void {}
            pub fn decode(_: @This(), _: std.mem.Allocator, _: *[]const u8, _: bool) anyerror!T {
                return error.Stub;
            }
            pub fn typeDescriptor(_: @This()) TypeDescriptor {
                return TypeDescriptor{ .primitive = .Bool };
            }
        };

        _vtable: *const VTable = vtableFor(StubImpl),

        /// Constructs a `Serializer` backed by the given adapter implementation.
        /// For use only by primitive/composite serializer factory functions.
        pub fn fromAdapter(comptime Impl: type) Self {
            return .{ ._vtable = vtableFor(Impl) };
        }

        // ── Public API ────────────────────────────────────────────────────────

        /// Serializes `value` to the requested format.
        ///
        /// The caller owns the returned slice and must free it with
        /// `allocator.free(result)`.
        pub fn serialize(self: Self, allocator: std.mem.Allocator, value: T, opts: struct {
            format: SerializeFormat = .denseJson,
        }) ![]u8 {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            switch (opts.format) {
                .denseJson => try self._vtable.toJsonFn(allocator, value, null, &buf),
                .readableJson => try self._vtable.toJsonFn(allocator, value, "\n", &buf),
                .binary => {
                    try buf.appendSlice(allocator, "skir");
                    try self._vtable.encodeFn(allocator, value, &buf);
                },
            }
            return buf.toOwnedSlice(allocator);
        }

        /// Deserializes a value from a JSON string or binary byte slice.
        ///
        /// JSON and binary formats (`"skir"` prefix) are detected automatically.
        pub fn deserialize(self: Self, allocator: std.mem.Allocator, input: []const u8, opts: struct {
            keepUnrecognizedValues: bool = false,
        }) !T {
            if (input.len >= 4 and std.mem.eql(u8, input[0..4], "skir")) {
                var rest: []const u8 = input[4..];
                return self._vtable.decodeFn(allocator, &rest, opts.keepUnrecognizedValues);
            } else {
                const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
                defer parsed.deinit();
                return self._vtable.fromJsonFn(allocator, parsed.value, opts.keepUnrecognizedValues);
            }
        }

        /// Returns the `TypeDescriptor` describing the shape of `T`.
        pub fn typeDescriptor(self: Self) TypeDescriptor {
            return self._vtable.typeDescriptorFn();
        }
    };
}

// =============================================================================
// BoolAdapter
// =============================================================================

/// Concrete adapter for `bool` values.
///
/// Dense JSON:    "1" (true) / "0" (false)
/// Readable JSON: "true" / "false"
/// Wire encoding: single byte 0x01 (true) / 0x00 (false)
pub const BoolAdapter = struct {
    const Self = @This();

    pub fn isDefault(_: Self, input: bool) bool {
        return !input;
    }

    pub fn toJson(_: Self, allocator: std.mem.Allocator, input: bool, eol_indent: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
        if (eol_indent != null) {
            try out.appendSlice(allocator, if (input) "true" else "false");
        } else {
            try out.append(allocator, if (input) '1' else '0');
        }
    }

    pub fn fromJson(_: Self, _: std.mem.Allocator, json: std.json.Value, _: bool) anyerror!bool {
        return switch (json) {
            .bool => |b| b,
            .integer => |n| n != 0,
            .float => |f| f != 0.0,
            // Any string other than "0" is truthy; "0" is the only falsy string.
            .string => |s| !std.mem.eql(u8, s, "0"),
            else => false,
        };
    }

    pub fn encode(_: Self, allocator: std.mem.Allocator, input: bool, out: *std.ArrayList(u8)) anyerror!void {
        try out.append(allocator, if (input) @as(u8, 1) else @as(u8, 0));
    }

    pub fn decode(_: Self, _: std.mem.Allocator, input: *[]const u8, _: bool) anyerror!bool {
        if (input.len == 0) return error.UnexpectedEndOfInput;
        const b = input.*[0];
        input.* = input.*[1..];
        return b != 0;
    }

    pub fn typeDescriptor(_: Self) TypeDescriptor {
        return TypeDescriptor{ .primitive = .Bool };
    }
};

// =============================================================================
// Binary I/O helpers — variable-length number encoding (shared by numeric adapters)
// =============================================================================

fn readU8(input: *[]const u8) error{UnexpectedEndOfInput}!u8 {
    if (input.len == 0) return error.UnexpectedEndOfInput;
    const b = input.*[0];
    input.* = input.*[1..];
    return b;
}

fn readU16Le(input: *[]const u8) error{UnexpectedEndOfInput}!u16 {
    if (input.len < 2) return error.UnexpectedEndOfInput;
    const v = std.mem.readInt(u16, input.*[0..2], .little);
    input.* = input.*[2..];
    return v;
}

fn readU32Le(input: *[]const u8) error{UnexpectedEndOfInput}!u32 {
    if (input.len < 4) return error.UnexpectedEndOfInput;
    const v = std.mem.readInt(u32, input.*[0..4], .little);
    input.* = input.*[4..];
    return v;
}

fn readU64Le(input: *[]const u8) error{UnexpectedEndOfInput}!u64 {
    if (input.len < 8) return error.UnexpectedEndOfInput;
    const v = std.mem.readInt(u64, input.*[0..8], .little);
    input.* = input.*[8..];
    return v;
}

/// Decodes the body of a variable-length number given the already-consumed wire byte.
fn decodeNumberBody(wire: u8, input: *[]const u8) error{UnexpectedEndOfInput}!i64 {
    return switch (wire) {
        0...231 => @as(i64, wire),
        232 => @as(i64, try readU16Le(input)),
        233 => @as(i64, try readU32Le(input)),
        234 => @as(i64, @bitCast(try readU64Le(input))),
        235 => @as(i64, try readU8(input)) - 256,
        236 => @as(i64, try readU16Le(input)) - 65536,
        237 => @as(i64, @as(i32, @bitCast(try readU32Le(input)))),
        238, 239 => @as(i64, @bitCast(try readU64Le(input))),
        else => 0,
    };
}

/// Reads and decodes the next variable-length number.
fn decodeNumber(input: *[]const u8) error{UnexpectedEndOfInput}!i64 {
    const wire = try readU8(input);
    return decodeNumberBody(wire, input);
}

/// Encodes an `i32` using the skir variable-length wire format.
fn encodeI32(v: i32, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) anyerror!void {
    if (v >= std.math.minInt(i32) and v <= -65537) {
        try out.append(allocator, 237);
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(i32, v)));
    } else if (v >= -65536 and v <= -257) {
        try out.append(allocator, 236);
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(v + 65536))));
    } else if (v >= -256 and v <= -1) {
        try out.append(allocator, 235);
        try out.append(allocator, @as(u8, @intCast(v + 256)));
    } else if (v >= 0 and v <= 231) {
        try out.append(allocator, @intCast(v));
    } else if (v >= 232 and v <= 65535) {
        try out.append(allocator, 232);
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(v))));
    } else {
        try out.append(allocator, 233);
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, @bitCast(v))));
    }
}

/// Encodes a non-negative integer as a variable-length unsigned value used for
/// array lengths and string/bytes sizes.
///
///  0..=231   → single byte equal to the value
///  232..=65535 → wire 232 + u16 LE
///  else      → wire 233 + u32 LE
fn encodeUint32(n: u32, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) anyerror!void {
    if (n <= 231) {
        try out.append(allocator, @intCast(n));
    } else if (n <= 65535) {
        try out.append(allocator, 232);
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(n))));
    } else {
        try out.append(allocator, 233);
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, n)));
    }
}

// =============================================================================
// Int32Adapter
// =============================================================================

/// Concrete adapter for `i32` values.
///
/// JSON (both dense and readable): a plain JSON number.
/// Wire encoding: variable-length signed integer.
pub const Int32Adapter = struct {
    const Self = @This();

    pub fn isDefault(_: Self, input: i32) bool {
        return input == 0;
    }

    pub fn toJson(_: Self, allocator: std.mem.Allocator, input: i32, _: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{input}) catch unreachable;
        try out.appendSlice(allocator, s);
    }

    pub fn fromJson(_: Self, _: std.mem.Allocator, json: std.json.Value, _: bool) anyerror!i32 {
        return switch (json) {
            .integer => |n| @intCast(n),
            .float => |f| @intFromFloat(f),
            .string => |s| blk: {
                const f = std.fmt.parseFloat(f64, s) catch break :blk 0;
                break :blk @intFromFloat(f);
            },
            else => 0,
        };
    }

    pub fn encode(_: Self, allocator: std.mem.Allocator, input: i32, out: *std.ArrayList(u8)) anyerror!void {
        try encodeI32(input, allocator, out);
    }

    pub fn decode(_: Self, _: std.mem.Allocator, input: *[]const u8, _: bool) anyerror!i32 {
        return @truncate(try decodeNumber(input));
    }

    pub fn typeDescriptor(_: Self) TypeDescriptor {
        return TypeDescriptor{ .primitive = .Int32 };
    }
};

// =============================================================================
// Int64Adapter
// =============================================================================

/// Values within `[-MAX_SAFE_INT, MAX_SAFE_INT]` are emitted as JSON numbers;
/// larger values are quoted strings, matching JS `Number.MAX_SAFE_INTEGER`.
const max_safe_int64_json: i64 = 9_007_199_254_740_991;

/// Concrete adapter for `i64` values.
///
/// Dense/readable JSON: number if within JS safe integer range, else quoted string.
/// Wire encoding: variable-length; falls back to i32 encoding if value fits.
pub const Int64Adapter = struct {
    const Self = @This();

    pub fn isDefault(_: Self, input: i64) bool {
        return input == 0;
    }

    pub fn toJson(_: Self, allocator: std.mem.Allocator, input: i64, _: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
        var buf: [64]u8 = undefined;
        if (input >= -max_safe_int64_json and input <= max_safe_int64_json) {
            const s = std.fmt.bufPrint(&buf, "{d}", .{input}) catch unreachable;
            try out.appendSlice(allocator, s);
        } else {
            const s = std.fmt.bufPrint(&buf, "\"{d}\"", .{input}) catch unreachable;
            try out.appendSlice(allocator, s);
        }
    }

    pub fn fromJson(_: Self, _: std.mem.Allocator, json: std.json.Value, _: bool) anyerror!i64 {
        return switch (json) {
            .integer => |n| n,
            .float => |f| @intFromFloat(@round(f)),
            .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
            else => 0,
        };
    }

    pub fn encode(_: Self, allocator: std.mem.Allocator, input: i64, out: *std.ArrayList(u8)) anyerror!void {
        if (input >= std.math.minInt(i32) and input <= std.math.maxInt(i32)) {
            try encodeI32(@intCast(input), allocator, out);
        } else {
            try out.append(allocator, 238);
            try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(i64, input)));
        }
    }

    pub fn decode(_: Self, _: std.mem.Allocator, input: *[]const u8, _: bool) anyerror!i64 {
        return decodeNumber(input);
    }

    pub fn typeDescriptor(_: Self) TypeDescriptor {
        return TypeDescriptor{ .primitive = .Int64 };
    }
};

// =============================================================================
// Hash64Adapter
// =============================================================================

const max_safe_hash64_json: u64 = 9_007_199_254_740_991;

/// Concrete adapter for `u64` hash values.
///
/// Dense/readable JSON: number if within JS safe integer range, else quoted string.
/// Wire encoding: variable-length unsigned integer.
pub const Hash64Adapter = struct {
    const Self = @This();

    pub fn isDefault(_: Self, input: u64) bool {
        return input == 0;
    }

    pub fn toJson(_: Self, allocator: std.mem.Allocator, input: u64, _: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
        var buf: [64]u8 = undefined;
        if (input <= max_safe_hash64_json) {
            const s = std.fmt.bufPrint(&buf, "{d}", .{input}) catch unreachable;
            try out.appendSlice(allocator, s);
        } else {
            const s = std.fmt.bufPrint(&buf, "\"{d}\"", .{input}) catch unreachable;
            try out.appendSlice(allocator, s);
        }
    }

    pub fn fromJson(_: Self, _: std.mem.Allocator, json: std.json.Value, _: bool) anyerror!u64 {
        return switch (json) {
            .integer => |n| if (n >= 0) @intCast(n) else 0,
            .float => |f| if (f < 0.0) 0 else @intFromFloat(@round(f)),
            .string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
            else => 0,
        };
    }

    pub fn encode(_: Self, allocator: std.mem.Allocator, input: u64, out: *std.ArrayList(u8)) anyerror!void {
        if (input <= 231) {
            try out.append(allocator, @intCast(input));
        } else if (input <= 65535) {
            try out.append(allocator, 232);
            try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(input))));
        } else if (input <= 4_294_967_295) {
            try out.append(allocator, 233);
            try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(input))));
        } else {
            try out.append(allocator, 234);
            try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u64, input)));
        }
    }

    pub fn decode(_: Self, _: std.mem.Allocator, input: *[]const u8, _: bool) anyerror!u64 {
        return @bitCast(try decodeNumber(input));
    }

    pub fn typeDescriptor(_: Self) TypeDescriptor {
        return TypeDescriptor{ .primitive = .Hash64 };
    }
};

// =============================================================================
// TimestampAdapter
// =============================================================================

const min_timestamp_millis: i64 = -8_640_000_000_000_000;
const max_timestamp_millis: i64 = 8_640_000_000_000_000;

/// Converts a unix-millisecond value to an ISO-8601 UTC string with millisecond
/// precision, e.g. `"2009-02-13T23:31:30.000Z"`.
///
/// Uses Howard Hinnant's civil-from-days algorithm.
/// https://howardhinnant.github.io/date_algorithms.html
fn millisToIso8601(ms_raw: i64) [24]u8 {
    const ms = std.math.clamp(ms_raw, min_timestamp_millis, max_timestamp_millis);
    const millis_part: u32 = @intCast(@mod(ms, 1000));
    const secs = @divFloor(ms, 1000);
    const time_of_day: u32 = @intCast(@mod(secs, 86400));
    const h = time_of_day / 3600;
    const mi = (time_of_day % 3600) / 60;
    const s = time_of_day % 60;

    const days = @divFloor(secs, 86400);
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe: u32 = @intCast(z - era * 146_097);
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    const y_base: i64 = @as(i64, yoe) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y: i64 = if (m <= 2) y_base + 1 else y_base;

    var buf: [24]u8 = undefined;
    // Year (4 digits, always positive in the supported range)
    const y_u = @as(u32, @intCast(y));
    buf[0] = '0' + @as(u8, @intCast(y_u / 1000));
    buf[1] = '0' + @as(u8, @intCast(y_u / 100 % 10));
    buf[2] = '0' + @as(u8, @intCast(y_u / 10 % 10));
    buf[3] = '0' + @as(u8, @intCast(y_u % 10));
    buf[4] = '-';
    buf[5] = '0' + @as(u8, @intCast(m / 10));
    buf[6] = '0' + @as(u8, @intCast(m % 10));
    buf[7] = '-';
    buf[8] = '0' + @as(u8, @intCast(d / 10));
    buf[9] = '0' + @as(u8, @intCast(d % 10));
    buf[10] = 'T';
    buf[11] = '0' + @as(u8, @intCast(h / 10));
    buf[12] = '0' + @as(u8, @intCast(h % 10));
    buf[13] = ':';
    buf[14] = '0' + @as(u8, @intCast(mi / 10));
    buf[15] = '0' + @as(u8, @intCast(mi % 10));
    buf[16] = ':';
    buf[17] = '0' + @as(u8, @intCast(s / 10));
    buf[18] = '0' + @as(u8, @intCast(s % 10));
    buf[19] = '.';
    buf[20] = '0' + @as(u8, @intCast(millis_part / 100));
    buf[21] = '0' + @as(u8, @intCast(millis_part / 10 % 10));
    buf[22] = '0' + @as(u8, @intCast(millis_part % 10));
    buf[23] = 'Z';
    return buf;
}

/// Concrete adapter for `Timestamp` values (unix milliseconds).
///
/// Dense JSON:    unix millis as a plain JSON number.
/// Readable JSON: `{"unix_millis": N, "formatted": "<ISO-8601>"}`.
/// Wire encoding: millis == 0 → wire 0x00; else wire 0xEF (239) + i64 LE.
pub const TimestampAdapter = struct {
    const Self = @This();

    pub fn isDefault(_: Self, input: Timestamp) bool {
        return input.unix_millis == 0;
    }

    pub fn toJson(_: Self, allocator: std.mem.Allocator, input: Timestamp, eol_indent: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
        const ms = input.unix_millis;
        if (eol_indent) |eol| {
            // Readable: {"unix_millis": N, "formatted": "ISO8601"}
            var ms_buf: [32]u8 = undefined;
            const ms_str = std.fmt.bufPrint(&ms_buf, "{d}", .{ms}) catch unreachable;
            const iso = millisToIso8601(ms);
            try out.append(allocator, '{');
            try out.appendSlice(allocator, eol);
            try out.appendSlice(allocator, "  ");
            try out.appendSlice(allocator, "\"unix_millis\": ");
            try out.appendSlice(allocator, ms_str);
            try out.append(allocator, ',');
            try out.appendSlice(allocator, eol);
            try out.appendSlice(allocator, "  ");
            try out.appendSlice(allocator, "\"formatted\": \"");
            try out.appendSlice(allocator, &iso);
            try out.append(allocator, '"');
            try out.appendSlice(allocator, eol);
            try out.append(allocator, '}');
        } else {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{ms}) catch unreachable;
            try out.appendSlice(allocator, s);
        }
    }

    pub fn fromJson(self: Self, allocator: std.mem.Allocator, json: std.json.Value, keep_unrecognized: bool) anyerror!Timestamp {
        const ms: i64 = switch (json) {
            .integer => |n| n,
            .float => |f| @intFromFloat(@round(f)),
            .string => |str| blk: {
                const f = std.fmt.parseFloat(f64, str) catch break :blk 0;
                break :blk @intFromFloat(@round(f));
            },
            .object => |obj| blk: {
                if (obj.get("unix_millis")) |field| {
                    const inner = try self.fromJson(allocator, field, keep_unrecognized);
                    return inner;
                }
                break :blk 0;
            },
            else => 0,
        };
        return Timestamp{ .unix_millis = ms };
    }

    pub fn encode(_: Self, allocator: std.mem.Allocator, input: Timestamp, out: *std.ArrayList(u8)) anyerror!void {
        const ms = input.unix_millis;
        if (ms == 0) {
            try out.append(allocator, 0);
        } else {
            try out.append(allocator, 239);
            try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(i64, ms)));
        }
    }

    pub fn decode(_: Self, _: std.mem.Allocator, input: *[]const u8, _: bool) anyerror!Timestamp {
        const ms = try decodeNumber(input);
        return Timestamp{ .unix_millis = ms };
    }

    pub fn typeDescriptor(_: Self) TypeDescriptor {
        return TypeDescriptor{ .primitive = .Timestamp };
    }
};

// =============================================================================
// Float helpers
// =============================================================================

/// Returns the TypeScript-compatible string for NaN / ±Infinity.
fn floatSpecialString(f: f64) []const u8 {
    if (std.math.isNan(f)) return "NaN";
    if (f > 0) return "Infinity";
    return "-Infinity";
}

// =============================================================================
// Float32Adapter
// =============================================================================

/// Concrete adapter for `f32` values.
///
/// Dense/readable JSON: finite values as shortest round-trip decimal; NaN/±Inf
/// as quoted strings `"NaN"`, `"Infinity"`, `"-Infinity"`.
/// Wire encoding: 0.0 → wire 0; else wire 240 + f32 bits as 4 LE bytes.
pub const Float32Adapter = struct {
    const Self = @This();

    pub fn isDefault(_: Self, input: f32) bool {
        return input == 0.0;
    }

    pub fn toJson(_: Self, allocator: std.mem.Allocator, input: f32, _: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
        if (std.math.isInf(input) or std.math.isNan(input)) {
            try out.append(allocator, '"');
            try out.appendSlice(allocator, floatSpecialString(@floatCast(input)));
            try out.append(allocator, '"');
        } else {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{}", .{input}) catch unreachable;
            try out.appendSlice(allocator, s);
        }
    }

    pub fn fromJson(_: Self, _: std.mem.Allocator, json: std.json.Value, _: bool) anyerror!f32 {
        return switch (json) {
            .float => |f| @floatCast(f),
            .integer => |n| @floatFromInt(n),
            .string => |s| std.fmt.parseFloat(f32, s) catch 0.0,
            else => 0.0,
        };
    }

    pub fn encode(_: Self, allocator: std.mem.Allocator, input: f32, out: *std.ArrayList(u8)) anyerror!void {
        if (input == 0.0) {
            try out.append(allocator, 0);
        } else {
            try out.append(allocator, 240);
            try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, @bitCast(input))));
        }
    }

    pub fn decode(_: Self, _: std.mem.Allocator, input: *[]const u8, _: bool) anyerror!f32 {
        const wire = try readU8(input);
        if (wire == 240) {
            return @bitCast(try readU32Le(input));
        } else {
            return @floatFromInt(try decodeNumberBody(wire, input));
        }
    }

    pub fn typeDescriptor(_: Self) TypeDescriptor {
        return TypeDescriptor{ .primitive = .Float32 };
    }
};

// =============================================================================
// Float64Adapter
// =============================================================================

/// Concrete adapter for `f64` values.
///
/// Dense/readable JSON: finite values as shortest round-trip decimal; NaN/±Inf
/// as quoted strings `"NaN"`, `"Infinity"`, `"-Infinity"`.
/// Wire encoding: 0.0 → wire 0; else wire 241 + f64 bits as 8 LE bytes.
pub const Float64Adapter = struct {
    const Self = @This();

    pub fn isDefault(_: Self, input: f64) bool {
        return input == 0.0;
    }

    pub fn toJson(_: Self, allocator: std.mem.Allocator, input: f64, _: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
        if (std.math.isInf(input) or std.math.isNan(input)) {
            try out.append(allocator, '"');
            try out.appendSlice(allocator, floatSpecialString(input));
            try out.append(allocator, '"');
        } else {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{}", .{input}) catch unreachable;
            try out.appendSlice(allocator, s);
        }
    }

    pub fn fromJson(_: Self, _: std.mem.Allocator, json: std.json.Value, _: bool) anyerror!f64 {
        return switch (json) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            .string => |s| std.fmt.parseFloat(f64, s) catch 0.0,
            else => 0.0,
        };
    }

    pub fn encode(_: Self, allocator: std.mem.Allocator, input: f64, out: *std.ArrayList(u8)) anyerror!void {
        if (input == 0.0) {
            try out.append(allocator, 0);
        } else {
            try out.append(allocator, 241);
            try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(input))));
        }
    }

    pub fn decode(_: Self, _: std.mem.Allocator, input: *[]const u8, _: bool) anyerror!f64 {
        const wire = try readU8(input);
        if (wire == 241) {
            return @bitCast(try readU64Le(input));
        } else {
            return @floatFromInt(try decodeNumberBody(wire, input));
        }
    }

    pub fn typeDescriptor(_: Self) TypeDescriptor {
        return TypeDescriptor{ .primitive = .Float64 };
    }
};

// =============================================================================
// String helpers
// =============================================================================

/// Writes `s` as a JSON string literal to `out`, escaping `"`, `\`, and
/// control characters (matching the Rust `write_json_escaped_string`).
fn writeJsonEscapedString(s: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) anyerror!void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            '\x08' => try out.appendSlice(allocator, "\\b"),
            '\x0C' => try out.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F, 0x7F => {
                var buf: [6]u8 = undefined;
                const written = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try out.appendSlice(allocator, written);
            },
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

/// Copies `bytes` to a newly-allocated slice, replacing any invalid UTF-8
/// sequences with the replacement character U+FFFD (0xEF 0xBF 0xBD).
fn utf8LossyDupe(bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return allocator.dupe(u8, bytes);
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < bytes.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(allocator, "\xef\xbf\xbd");
            i += 1;
            continue;
        };
        if (i + seq_len > bytes.len) {
            try out.appendSlice(allocator, "\xef\xbf\xbd");
            break;
        }
        _ = std.unicode.utf8Decode(bytes[i .. i + seq_len]) catch {
            try out.appendSlice(allocator, "\xef\xbf\xbd");
            i += 1;
            continue;
        };
        try out.appendSlice(allocator, bytes[i .. i + seq_len]);
        i += seq_len;
    }
    return out.toOwnedSlice(allocator);
}

// =============================================================================
// StringAdapter
// =============================================================================

/// Concrete adapter for `[]const u8` string values (valid UTF-8).
///
/// Dense/readable JSON: a JSON string literal with escaping (same in both modes).
/// Wire encoding: empty → wire 242; non-empty → wire 243 + encodeUint32(len) + UTF-8 bytes.
pub const StringAdapter = struct {
    const Self = @This();

    pub fn isDefault(_: Self, input: []const u8) bool {
        return input.len == 0;
    }

    pub fn toJson(_: Self, allocator: std.mem.Allocator, input: []const u8, _: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
        try writeJsonEscapedString(input, allocator, out);
    }

    pub fn fromJson(_: Self, allocator: std.mem.Allocator, json: std.json.Value, _: bool) anyerror![]const u8 {
        return switch (json) {
            .string => |s| allocator.dupe(u8, s),
            else => allocator.dupe(u8, &.{}),
        };
    }

    pub fn encode(_: Self, allocator: std.mem.Allocator, input: []const u8, out: *std.ArrayList(u8)) anyerror!void {
        if (input.len == 0) {
            try out.append(allocator, 242);
        } else {
            try out.append(allocator, 243);
            try encodeUint32(@intCast(input.len), allocator, out);
            try out.appendSlice(allocator, input);
        }
    }

    pub fn decode(_: Self, allocator: std.mem.Allocator, input: *[]const u8, _: bool) anyerror![]const u8 {
        const wire = try readU8(input);
        if (wire == 0 or wire == 242) {
            return allocator.dupe(u8, &.{});
        }
        const n: usize = @intCast(try decodeNumber(input));
        if (input.len < n) return error.UnexpectedEndOfInput;
        const raw = input.*[0..n];
        input.* = input.*[n..];
        return utf8LossyDupe(raw, allocator);
    }

    pub fn typeDescriptor(_: Self) TypeDescriptor {
        return TypeDescriptor{ .primitive = .String };
    }
};

// =============================================================================
// Primitive Serializers
// =============================================================================

/// Returns a `Serializer` for `bool` values.
pub fn boolSerializer() Serializer(bool) {
    return Serializer(bool).fromAdapter(BoolAdapter);
}

pub fn int32Serializer() Serializer(i32) {
    return Serializer(i32).fromAdapter(Int32Adapter);
}
pub fn int64Serializer() Serializer(i64) {
    return Serializer(i64).fromAdapter(Int64Adapter);
}
pub fn hash64Serializer() Serializer(u64) {
    return Serializer(u64).fromAdapter(Hash64Adapter);
}
pub fn float32Serializer() Serializer(f32) {
    return Serializer(f32).fromAdapter(Float32Adapter);
}
pub fn float64Serializer() Serializer(f64) {
    return Serializer(f64).fromAdapter(Float64Adapter);
}
pub fn stringSerializer() Serializer([]const u8) {
    return Serializer([]const u8).fromAdapter(StringAdapter);
}
pub fn bytesSerializer() Serializer([]const u8) {
    return Serializer([]const u8).fromAdapter(BytesAdapter);
}
pub fn timestampSerializer() Serializer(Timestamp) {
    return Serializer(Timestamp).fromAdapter(TimestampAdapter);
}

// =============================================================================
// Base64 / hex helpers
// =============================================================================

const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn encodeBase64(bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const out_len = ((bytes.len + 2) / 3) * 4;
    const out = try allocator.alloc(u8, out_len);
    var i: usize = 0;
    var o: usize = 0;
    while (i < bytes.len) : (i += 3) {
        const b0: u32 = bytes[i];
        const b1: u32 = if (i + 1 < bytes.len) bytes[i + 1] else 0;
        const b2: u32 = if (i + 2 < bytes.len) bytes[i + 2] else 0;
        const triple = (b0 << 16) | (b1 << 8) | b2;
        out[o] = base64_alphabet[(triple >> 18) & 0x3F];
        out[o + 1] = base64_alphabet[(triple >> 12) & 0x3F];
        out[o + 2] = if (i + 1 < bytes.len) base64_alphabet[(triple >> 6) & 0x3F] else '=';
        out[o + 3] = if (i + 2 < bytes.len) base64_alphabet[triple & 0x3F] else '=';
        o += 4;
    }
    return out;
}

fn base64DecodeChar(c: u8) ?u8 {
    return switch (c) {
        'A'...'Z' => c - 'A',
        'a'...'z' => c - 'a' + 26,
        '0'...'9' => c - '0' + 52,
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

fn decodeBase64(s: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Strip trailing '=' padding.
    var end = s.len;
    while (end > 0 and s[end - 1] == '=') end -= 1;
    const trimmed = s[0..end];
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: u32 = 0;
    var bits: u5 = 0;
    for (trimmed) |ch| {
        const v = base64DecodeChar(ch) orelse return error.InvalidBase64;
        buf = (buf << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            try out.append(allocator, @intCast((buf >> bits) & 0xFF));
        }
    }
    return out.toOwnedSlice(allocator);
}

fn encodeHex(bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const hex_digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_digits[b >> 4];
        out[i * 2 + 1] = hex_digits[b & 0xF];
    }
    return out;
}

fn decodeHex(s: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (s.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, s.len / 2);
    errdefer allocator.free(out);
    for (0..s.len / 2) |i| {
        out[i] = try std.fmt.parseInt(u8, s[i * 2 .. i * 2 + 2], 16);
    }
    return out;
}

// =============================================================================
// BytesAdapter
// =============================================================================

/// Concrete adapter for `[]const u8` byte-array values.
///
/// Dense JSON:    standard base64 with `=` padding.
/// Readable JSON: `"hex:<lowercase-hex>"`.
/// Wire:  empty → 0xF4; non-empty → 0xF5 + encodeUint32(len) + raw bytes.
pub const BytesAdapter = struct {
    const Self = @This();

    pub fn isDefault(_: Self, input: []const u8) bool {
        return input.len == 0;
    }

    pub fn toJson(_: Self, allocator: std.mem.Allocator, input: []const u8, eol_indent: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
        try out.append(allocator, '"');
        if (eol_indent != null) {
            try out.appendSlice(allocator, "hex:");
            const hex = try encodeHex(input, allocator);
            defer allocator.free(hex);
            try out.appendSlice(allocator, hex);
        } else {
            const b64 = try encodeBase64(input, allocator);
            defer allocator.free(b64);
            try out.appendSlice(allocator, b64);
        }
        try out.append(allocator, '"');
    }

    pub fn fromJson(_: Self, allocator: std.mem.Allocator, json: std.json.Value, _: bool) anyerror![]const u8 {
        switch (json) {
            .string => |s| {
                if (std.mem.startsWith(u8, s, "hex:")) {
                    return decodeHex(s[4..], allocator);
                } else {
                    return decodeBase64(s, allocator);
                }
            },
            else => return allocator.dupe(u8, &.{}),
        }
    }

    pub fn encode(_: Self, allocator: std.mem.Allocator, input: []const u8, out: *std.ArrayList(u8)) anyerror!void {
        if (input.len == 0) {
            try out.append(allocator, 244);
        } else {
            try out.append(allocator, 245);
            try encodeUint32(@intCast(input.len), allocator, out);
            try out.appendSlice(allocator, input);
        }
    }

    pub fn decode(_: Self, allocator: std.mem.Allocator, input: *[]const u8, _: bool) anyerror![]const u8 {
        const wire = try readU8(input);
        if (wire == 0 or wire == 244) return allocator.dupe(u8, &.{});
        const n: usize = @intCast(try decodeNumber(input));
        if (input.len < n) return error.UnexpectedEndOfInput;
        const bytes = try allocator.dupe(u8, input.*[0..n]);
        input.* = input.*[n..];
        return bytes;
    }

    pub fn typeDescriptor(_: Self) TypeDescriptor {
        return TypeDescriptor{ .primitive = .Bytes };
    }
};

// =============================================================================
// Composite Serializers
// =============================================================================

/// Returns a serializer for optional values of type `?T`.
///
/// `None` encodes as JSON `null` / wire byte `0xFF`.
/// `Some(v)` delegates to `inner` for both JSON and binary encoding.
pub fn optionalSerializer(comptime T: type, comptime inner: Serializer(T)) Serializer(?T) {
    const ivt = inner._vtable;
    const Adapter = struct {
        pub fn toJson(_: @This(), alloc: std.mem.Allocator, value: ?T, eol: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
            if (value) |v| {
                try ivt.toJsonFn(alloc, v, eol, out);
            } else {
                try out.appendSlice(alloc, "null");
            }
        }
        pub fn fromJson(_: @This(), alloc: std.mem.Allocator, json: std.json.Value, keep: bool) anyerror!?T {
            if (json == .null) return null;
            return try ivt.fromJsonFn(alloc, json, keep);
        }
        pub fn encode(_: @This(), alloc: std.mem.Allocator, value: ?T, out: *std.ArrayList(u8)) anyerror!void {
            if (value) |v| {
                try ivt.encodeFn(alloc, v, out);
            } else {
                try out.append(alloc, 255);
            }
        }
        pub fn decode(_: @This(), alloc: std.mem.Allocator, input: *[]const u8, keep: bool) anyerror!?T {
            if (input.*.len > 0 and input.*[0] == 255) {
                input.* = input.*[1..];
                return null;
            }
            return try ivt.decodeFn(alloc, input, keep);
        }
        pub fn typeDescriptor(_: @This()) TypeDescriptor {
            // Static storage for the inner descriptor so we can return a stable pointer.
            const S = struct {
                var inner_td: TypeDescriptor = undefined;
                var ready = false;
            };
            if (!S.ready) {
                S.inner_td = ivt.typeDescriptorFn();
                S.ready = true;
            }
            return TypeDescriptor{ .optional = &S.inner_td };
        }
    };
    return Serializer(?T).fromAdapter(Adapter);
}

/// Returns a serializer for slice values of type `[]const T`.
///
/// Dense JSON:    `[v1,v2,...]`
/// Readable JSON: `[\n  v1,\n  v2\n]`
/// Wire:  0 items → 0xF6; 1–3 items → 0xF7–0xF9 (no length);
///        4+ items → 0xFA + encodeUint32(count).
pub fn arraySerializer(comptime T: type, comptime inner: Serializer(T)) Serializer([]const T) {
    const ivt = inner._vtable;
    const Adapter = struct {
        pub fn toJson(_: @This(), alloc: std.mem.Allocator, value: []const T, eol: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
            try out.append(alloc, '[');
            if (eol) |eol_str| {
                // Readable: each item on its own line, indented 2 more spaces than the parent.
                var child_buf: [256]u8 = undefined;
                const child_len = @min(eol_str.len + 2, child_buf.len);
                @memcpy(child_buf[0..eol_str.len], eol_str);
                child_buf[eol_str.len] = ' ';
                if (eol_str.len + 1 < child_buf.len) child_buf[eol_str.len + 1] = ' ';
                const child_eol: []const u8 = child_buf[0..child_len];
                for (value, 0..) |item, i| {
                    try out.appendSlice(alloc, child_eol);
                    try ivt.toJsonFn(alloc, item, child_eol, out);
                    if (i + 1 < value.len) try out.append(alloc, ',');
                }
                if (value.len > 0) try out.appendSlice(alloc, eol_str);
            } else {
                for (value, 0..) |item, i| {
                    if (i > 0) try out.append(alloc, ',');
                    try ivt.toJsonFn(alloc, item, null, out);
                }
            }
            try out.append(alloc, ']');
        }
        pub fn fromJson(_: @This(), alloc: std.mem.Allocator, json: std.json.Value, keep: bool) anyerror![]const T {
            const arr = switch (json) {
                .array => |a| a.items,
                else => return alloc.dupe(T, &.{}),
            };
            const items = try alloc.alloc(T, arr.len);
            errdefer alloc.free(items);
            for (arr, 0..) |v, i| {
                items[i] = try ivt.fromJsonFn(alloc, v, keep);
            }
            return items;
        }
        pub fn encode(_: @This(), alloc: std.mem.Allocator, value: []const T, out: *std.ArrayList(u8)) anyerror!void {
            const n = value.len;
            if (n <= 3) {
                try out.append(alloc, @intCast(246 + n));
            } else {
                try out.append(alloc, 250);
                try encodeUint32(@intCast(n), alloc, out);
            }
            for (value) |item| try ivt.encodeFn(alloc, item, out);
        }
        pub fn decode(_: @This(), alloc: std.mem.Allocator, input: *[]const u8, keep: bool) anyerror![]const T {
            const wire = try readU8(input);
            if (wire == 0 or wire == 246) return alloc.dupe(T, &.{});
            const n: usize = if (wire == 250)
                @intCast(try decodeNumber(input))
            else
                @intCast(wire - 246);
            const items = try alloc.alloc(T, n);
            errdefer alloc.free(items);
            for (0..n) |i| items[i] = try ivt.decodeFn(alloc, input, keep);
            return items;
        }
        pub fn typeDescriptor(_: @This()) TypeDescriptor {
            const S = struct {
                var inner_td: TypeDescriptor = undefined;
                var ready = false;
            };
            if (!S.ready) {
                S.inner_td = ivt.typeDescriptorFn();
                S.ready = true;
            }
            return TypeDescriptor{ .array = .{ .item_type = &S.inner_td, .key_extractor = "" } };
        }
    };
    return Serializer([]const T).fromAdapter(Adapter);
}

// =============================================================================
// Method
// =============================================================================

/// Metadata for a Skir RPC method.
pub fn Method(comptime Request: type, comptime Response: type) type {
    return struct {
        /// The method name as declared in the .skir file.
        name: []const u8,
        /// The stable numeric identifier of the method.
        number: i32,
        /// The documentation comment from the .skir file.
        doc: []const u8,
        /// Serializer for request values.
        request_serializer: Serializer(Request),
        /// Serializer for response values.
        response_serializer: Serializer(Response),
    };
}

// =============================================================================
// TypeDescriptor
// =============================================================================

/// All primitive Skir types.
pub const PrimitiveType = enum {
    Bool,
    Int32,
    Int64,
    Hash64,
    Float32,
    Float64,
    Timestamp,
    String,
    Bytes,

    pub fn asStr(self: PrimitiveType) []const u8 {
        return switch (self) {
            .Bool => "bool",
            .Int32 => "int32",
            .Int64 => "int64",
            .Hash64 => "hash64",
            .Float32 => "float32",
            .Float64 => "float64",
            .Timestamp => "timestamp",
            .String => "string",
            .Bytes => "bytes",
        };
    }

    fn fromStr(s: []const u8) ?PrimitiveType {
        const map = [_]struct { []const u8, PrimitiveType }{
            .{ "bool", .Bool },
            .{ "int32", .Int32 },
            .{ "int64", .Int64 },
            .{ "hash64", .Hash64 },
            .{ "float32", .Float32 },
            .{ "float64", .Float64 },
            .{ "timestamp", .Timestamp },
            .{ "string", .String },
            .{ "bytes", .Bytes },
        };
        for (map) |entry| {
            if (std.mem.eql(u8, s, entry[0])) return entry[1];
        }
        return null;
    }
};

/// Describes an ordered collection of elements of a single type.
pub const ArrayDescriptor = struct {
    item_type: *const TypeDescriptor,
    key_extractor: []const u8,
};

/// Describes a single field of a Skir struct.
pub const StructField = struct {
    name: []const u8,
    number: i32,
    /// The type of this field. `null` in the simplified compile-time descriptor
    /// produced by generated code; populated after a JSON round-trip.
    field_type: ?*const TypeDescriptor = null,
    doc: []const u8 = "",
};

/// A constant (non-wrapping) enum variant.
pub const EnumConstantVariant = struct {
    name: []const u8,
    number: i32,
    doc: []const u8 = "",
};

/// An enum variant that wraps a value of another type.
pub const EnumWrapperVariant = struct {
    name: []const u8,
    number: i32,
    variant_type: ?*const TypeDescriptor = null,
    doc: []const u8 = "",
};

/// A single variant of a Skir enum — either constant or wrapper.
pub const EnumVariant = union(enum) {
    constant: EnumConstantVariant,
    wrapper: EnumWrapperVariant,

    pub fn name(self: EnumVariant) []const u8 {
        return switch (self) {
            .constant => |v| v.name,
            .wrapper => |v| v.name,
        };
    }
    pub fn number(self: EnumVariant) i32 {
        return switch (self) {
            .constant => |v| v.number,
            .wrapper => |v| v.number,
        };
    }
    pub fn doc(self: EnumVariant) []const u8 {
        return switch (self) {
            .constant => |v| v.doc,
            .wrapper => |v| v.doc,
        };
    }
    pub fn variantType(self: EnumVariant) ?*const TypeDescriptor {
        return switch (self) {
            .constant => null,
            .wrapper => |v| v.variant_type,
        };
    }
};

/// Runtime descriptor for a Skir struct type.
pub const StructDescriptor = struct {
    name: []const u8 = "",
    qualified_name: []const u8 = "",
    module_path: []const u8 = "",
    doc: []const u8 = "",
    fields: []const StructField = &.{},
    removed_numbers: []const i32 = &.{},

    pub fn fieldByName(self: StructDescriptor, field_name: []const u8) ?StructField {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.name, field_name)) return f;
        }
        return null;
    }

    pub fn fieldByNumber(self: StructDescriptor, num: i32) ?StructField {
        for (self.fields) |f| {
            if (f.number == num) return f;
        }
        return null;
    }
};

/// Runtime descriptor for a Skir enum type.
pub const EnumDescriptor = struct {
    name: []const u8 = "",
    qualified_name: []const u8 = "",
    module_path: []const u8 = "",
    doc: []const u8 = "",
    variants: []const EnumVariant = &.{},
    removed_numbers: []const i32 = &.{},

    pub fn variantByName(self: EnumDescriptor, variant_name: []const u8) ?EnumVariant {
        for (self.variants) |v| {
            if (std.mem.eql(u8, v.name(), variant_name)) return v;
        }
        return null;
    }

    pub fn variantByNumber(self: EnumDescriptor, num: i32) ?EnumVariant {
        for (self.variants) |v| {
            if (v.number() == num) return v;
        }
        return null;
    }
};

/// Describes a Skir type at runtime.
pub const TypeDescriptor = union(enum) {
    primitive: PrimitiveType,
    optional: *const TypeDescriptor,
    array: ArrayDescriptor,
    /// Descriptor for a struct type.
    struct_record: StructDescriptor,
    /// Descriptor for an enum type.
    enum_record: EnumDescriptor,
};

// =============================================================================
// TypeDescriptor JSON serialisation
// =============================================================================

/// Serializes a `TypeDescriptor` to a pretty-printed JSON string.
///
/// The returned slice is allocated with `allocator` and must be freed by the
/// caller.  The format is byte-for-byte compatible with the Rust
/// `skir-client` crate's `TypeDescriptor::as_json()` output so that type
/// descriptors can be exchanged between language runtimes.
pub fn typeDescriptorToJson(allocator: std.mem.Allocator, td: TypeDescriptor) ![]const u8 {
    var records_list = std.ArrayList(RecordEntry){};
    defer records_list.deinit(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    try collectRecords(allocator, &td, &records_list, &seen);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root = std.json.ObjectMap.init(a);
    try root.put("type", try typeSignatureToValue(a, td));
    var records_arr = std.json.Array.init(a);
    for (records_list.items) |entry| {
        try records_arr.append(try recordEntryToValue(a, entry));
    }
    try root.put("records", .{ .array = records_arr });

    const root_val = std.json.Value{ .object = root };
    return std.json.Stringify.valueAlloc(allocator, root_val, .{ .whitespace = .indent_2 });
}

const RecordEntry = union(enum) {
    struct_record: *const StructDescriptor,
    enum_record: *const EnumDescriptor,

    fn recordId(self: RecordEntry) []const u8 {
        return switch (self) {
            .struct_record => |s| s.qualified_name,
            .enum_record => |e| e.qualified_name,
        };
    }
};

fn collectRecords(
    allocator: std.mem.Allocator,
    td: *const TypeDescriptor,
    list: *std.ArrayList(RecordEntry),
    seen: *std.StringHashMap(void),
) error{OutOfMemory}!void {
    switch (td.*) {
        .primitive => {},
        .optional => |inner| try collectRecords(allocator, inner, list, seen),
        .array => |arr| try collectRecords(allocator, arr.item_type, list, seen),
        .struct_record => |*s| {
            const rid = s.qualified_name;
            if (seen.contains(rid)) return;
            try seen.put(rid, {});
            try list.append(allocator, .{ .struct_record = s });
            for (s.fields) |f| {
                if (f.field_type) |ft| try collectRecords(allocator, ft, list, seen);
            }
        },
        .enum_record => |*e| {
            const rid = e.qualified_name;
            if (seen.contains(rid)) return;
            try seen.put(rid, {});
            try list.append(allocator, .{ .enum_record = e });
            for (e.variants) |v| {
                if (v.variantType()) |vt| try collectRecords(allocator, vt, list, seen);
            }
        },
    }
}

fn typeSignatureToValue(a: std.mem.Allocator, td: TypeDescriptor) !std.json.Value {
    var obj = std.json.ObjectMap.init(a);
    switch (td) {
        .primitive => |p| {
            try obj.put("kind", .{ .string = "primitive" });
            try obj.put("value", .{ .string = p.asStr() });
        },
        .optional => |inner| {
            try obj.put("kind", .{ .string = "optional" });
            try obj.put("value", try typeSignatureToValue(a, inner.*));
        },
        .array => |arr| {
            try obj.put("kind", .{ .string = "array" });
            var val_obj = std.json.ObjectMap.init(a);
            try val_obj.put("item", try typeSignatureToValue(a, arr.item_type.*));
            if (arr.key_extractor.len > 0) {
                try val_obj.put("key_extractor", .{ .string = arr.key_extractor });
            }
            try obj.put("value", .{ .object = val_obj });
        },
        .struct_record => |s| {
            try obj.put("kind", .{ .string = "record" });
            const rid = try std.fmt.allocPrint(a, "{s}:{s}", .{ s.module_path, s.qualified_name });
            try obj.put("value", .{ .string = rid });
        },
        .enum_record => |e| {
            try obj.put("kind", .{ .string = "record" });
            const rid = try std.fmt.allocPrint(a, "{s}:{s}", .{ e.module_path, e.qualified_name });
            try obj.put("value", .{ .string = rid });
        },
    }
    return .{ .object = obj };
}

fn recordEntryToValue(a: std.mem.Allocator, entry: RecordEntry) !std.json.Value {
    switch (entry) {
        .struct_record => |s| {
            var obj = std.json.ObjectMap.init(a);
            try obj.put("kind", .{ .string = "struct" });
            const record_id = try std.fmt.allocPrint(a, "{s}:{s}", .{ s.module_path, s.qualified_name });
            try obj.put("id", .{ .string = record_id });
            if (s.doc.len > 0) try obj.put("doc", .{ .string = s.doc });
            var fields_arr = std.json.Array.init(a);
            for (s.fields) |f| {
                var fobj = std.json.ObjectMap.init(a);
                try fobj.put("name", .{ .string = f.name });
                try fobj.put("number", .{ .integer = f.number });
                if (f.field_type) |ft| {
                    try fobj.put("type", try typeSignatureToValue(a, ft.*));
                } else {
                    // No type info available (lightweight compile-time descriptor):
                    // emit a stub primitive type so the JSON is well-formed.
                    var stub_type = std.json.ObjectMap.init(a);
                    try stub_type.put("kind", .{ .string = "primitive" });
                    try stub_type.put("value", .{ .string = "bytes" });
                    try fobj.put("type", .{ .object = stub_type });
                }
                if (f.doc.len > 0) try fobj.put("doc", .{ .string = f.doc });
                try fields_arr.append(.{ .object = fobj });
            }
            try obj.put("fields", .{ .array = fields_arr });
            if (s.removed_numbers.len > 0) {
                var rn_arr = std.json.Array.init(a);
                const sorted = try sortedIntegers(a, s.removed_numbers);
                for (sorted) |n| try rn_arr.append(.{ .integer = n });
                try obj.put("removed_numbers", .{ .array = rn_arr });
            }
            return .{ .object = obj };
        },
        .enum_record => |e| {
            var obj = std.json.ObjectMap.init(a);
            try obj.put("kind", .{ .string = "enum" });
            const record_id = try std.fmt.allocPrint(a, "{s}:{s}", .{ e.module_path, e.qualified_name });
            try obj.put("id", .{ .string = record_id });
            if (e.doc.len > 0) try obj.put("doc", .{ .string = e.doc });
            // Variants must be sorted by number in the JSON output.
            const sorted_variants = try a.dupe(EnumVariant, e.variants);
            std.sort.pdq(EnumVariant, sorted_variants, {}, variantLessThan);
            var variants_arr = std.json.Array.init(a);
            for (sorted_variants) |v| {
                var vobj = std.json.ObjectMap.init(a);
                try vobj.put("name", .{ .string = v.name() });
                try vobj.put("number", .{ .integer = v.number() });
                if (v.variantType()) |vt| {
                    try vobj.put("type", try typeSignatureToValue(a, vt.*));
                }
                if (v.doc().len > 0) try vobj.put("doc", .{ .string = v.doc() });
                try variants_arr.append(.{ .object = vobj });
            }
            try obj.put("variants", .{ .array = variants_arr });
            if (e.removed_numbers.len > 0) {
                var rn_arr = std.json.Array.init(a);
                const sorted = try sortedIntegers(a, e.removed_numbers);
                for (sorted) |n| try rn_arr.append(.{ .integer = n });
                try obj.put("removed_numbers", .{ .array = rn_arr });
            }
            return .{ .object = obj };
        },
    }
}

fn variantLessThan(_: void, a: EnumVariant, b: EnumVariant) bool {
    return a.number() < b.number();
}

fn sortedIntegers(allocator: std.mem.Allocator, nums: []const i32) ![]i32 {
    const copy = try allocator.dupe(i32, nums);
    std.sort.pdq(i32, copy, {}, std.sort.asc(i32));
    return copy;
}

// =============================================================================
// TypeDescriptor JSON parsing
// =============================================================================

/// Parses a `TypeDescriptor` from the JSON format produced by
/// `typeDescriptorToJson`.
///
/// All returned memory (strings, slices, nested descriptors) is owned by
/// `allocator` and must be freed by the caller.
pub fn typeDescriptorFromJson(allocator: std.mem.Allocator, json_code: []const u8) !TypeDescriptor {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_code, .{});
    defer parsed.deinit();
    return parseTypeDescriptorFromValue(allocator, parsed.value);
}

fn parseTypeDescriptorFromValue(allocator: std.mem.Allocator, root: std.json.Value) !TypeDescriptor {
    // ── Pass 1: allocate record skeletons ─────────────────────────────────────
    var record_map = std.StringHashMap(ParsedRecord).init(allocator);
    defer {
        var it = record_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        record_map.deinit();
    }

    if (root.object.get("records")) |recs_val| {
        for (recs_val.array.items) |rec| {
            const kind = getJsonStr(rec, "kind");
            const id_str = getJsonStr(rec, "id");
            const doc = try allocator.dupe(u8, getJsonStr(rec, "doc"));
            errdefer allocator.free(doc);
            const colon_idx = std.mem.indexOfScalar(u8, id_str, ':') orelse
                return error.MalformedRecordId;
            const module_path = try allocator.dupe(u8, id_str[0..colon_idx]);
            errdefer allocator.free(module_path);
            const qualified_name = try allocator.dupe(u8, id_str[colon_idx + 1 ..]);
            errdefer allocator.free(qualified_name);
            const short_name_start = if (std.mem.lastIndexOfScalar(u8, qualified_name, '.')) |i| i + 1 else 0;
            const name = try allocator.dupe(u8, qualified_name[short_name_start..]);
            errdefer allocator.free(name);

            const removed_numbers = try parseRemovedNumbers(allocator, rec);
            errdefer allocator.free(removed_numbers);

            const fields_or_variants: ?[]const std.json.Value = blk: {
                if (rec.object.get("fields")) |fv| break :blk fv.array.items;
                if (rec.object.get("variants")) |vv| break :blk vv.array.items;
                break :blk null;
            };

            // Deep-copy the raw variant/field JSON values so we own them.
            var raw_items = std.ArrayList(std.json.Value){};
            errdefer raw_items.deinit(allocator);
            if (fields_or_variants) |items| {
                for (items) |item| try raw_items.append(allocator, item);
            }

            const map_key = try allocator.dupe(u8, id_str);
            errdefer allocator.free(map_key);

            if (std.mem.eql(u8, kind, "struct")) {
                try record_map.put(map_key, ParsedRecord{
                    .kind = .struct_record,
                    .name = name,
                    .qualified_name = qualified_name,
                    .module_path = module_path,
                    .doc = doc,
                    .removed_numbers = removed_numbers,
                    .raw_items = raw_items,
                });
            } else if (std.mem.eql(u8, kind, "enum")) {
                try record_map.put(map_key, ParsedRecord{
                    .kind = .enum_record,
                    .name = name,
                    .qualified_name = qualified_name,
                    .module_path = module_path,
                    .doc = doc,
                    .removed_numbers = removed_numbers,
                    .raw_items = raw_items,
                });
            } else {
                allocator.free(doc);
                allocator.free(module_path);
                allocator.free(qualified_name);
                allocator.free(name);
                allocator.free(removed_numbers);
                raw_items.deinit(allocator);
                allocator.free(map_key);
                return error.UnknownRecordKind;
            }
        }
    }

    // ── Pass 2: fill in fields / variants ─────────────────────────────────────
    //
    // We iterate over keys, clone the raw_items list and descriptor info,
    // then call parseTypeSignature which may look up other entries in record_map.
    // Since parseTypeSignature only reads record_map (never writes it), and
    // we only read raw_items here, this is safe to do in a single pass.
    var field_arena = std.heap.ArenaAllocator.init(allocator);
    defer field_arena.deinit();
    const fa = field_arena.allocator();

    var struct_fields_map = std.StringHashMap([]StructField).init(allocator);
    defer {
        var it = struct_fields_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        struct_fields_map.deinit();
    }
    var enum_variants_map = std.StringHashMap([]EnumVariant).init(allocator);
    defer {
        var it = enum_variants_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        enum_variants_map.deinit();
    }

    var rm_it = record_map.iterator();
    while (rm_it.next()) |entry| {
        const id = entry.key_ptr.*;
        const rec = entry.value_ptr;
        switch (rec.kind) {
            .struct_record => {
                var fields = try allocator.alloc(StructField, rec.raw_items.items.len);
                errdefer allocator.free(fields);
                for (rec.raw_items.items, 0..) |fv, i| {
                    const fname = try allocator.dupe(u8, getJsonStr(fv, "name"));
                    errdefer allocator.free(fname);
                    const fnum = getJsonI32(fv, "number");
                    const fdoc = try allocator.dupe(u8, getJsonStr(fv, "doc"));
                    errdefer allocator.free(fdoc);
                    const type_val = fv.object.get("type") orelse return error.FieldMissingType;
                    const ftype_ptr = try allocator.create(TypeDescriptor);
                    errdefer allocator.destroy(ftype_ptr);
                    ftype_ptr.* = try parseTypeSignature(allocator, fa, type_val, &record_map);
                    fields[i] = StructField{
                        .name = fname,
                        .number = fnum,
                        .field_type = ftype_ptr,
                        .doc = fdoc,
                    };
                }
                const key = try allocator.dupe(u8, id);
                errdefer allocator.free(key);
                try struct_fields_map.put(key, fields);
            },
            .enum_record => {
                var variants = try allocator.alloc(EnumVariant, rec.raw_items.items.len);
                errdefer allocator.free(variants);
                for (rec.raw_items.items, 0..) |vv, i| {
                    const vname = try allocator.dupe(u8, getJsonStr(vv, "name"));
                    errdefer allocator.free(vname);
                    const vnum = getJsonI32(vv, "number");
                    const vdoc = try allocator.dupe(u8, getJsonStr(vv, "doc"));
                    errdefer allocator.free(vdoc);
                    if (vv.object.get("type")) |type_val| {
                        const vtype_ptr = try allocator.create(TypeDescriptor);
                        errdefer allocator.destroy(vtype_ptr);
                        vtype_ptr.* = try parseTypeSignature(allocator, fa, type_val, &record_map);
                        variants[i] = EnumVariant{ .wrapper = .{
                            .name = vname,
                            .number = vnum,
                            .variant_type = vtype_ptr,
                            .doc = vdoc,
                        } };
                    } else {
                        variants[i] = EnumVariant{ .constant = .{
                            .name = vname,
                            .number = vnum,
                            .doc = vdoc,
                        } };
                    }
                }
                const key = try allocator.dupe(u8, id);
                errdefer allocator.free(key);
                try enum_variants_map.put(key, variants);
            },
        }
    }

    // ── Resolve root type ─────────────────────────────────────────────────────
    const type_val = root.object.get("type") orelse return error.MissingTypeKey;
    return parseTypeSignatureResolved(allocator, type_val, &record_map, &struct_fields_map, &enum_variants_map);
}

const RecordKind = enum { struct_record, enum_record };

const ParsedRecord = struct {
    kind: RecordKind,
    name: []const u8,
    qualified_name: []const u8,
    module_path: []const u8,
    doc: []const u8,
    removed_numbers: []const i32,
    raw_items: std.ArrayList(std.json.Value),

    fn deinit(self: *ParsedRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.qualified_name);
        allocator.free(self.module_path);
        allocator.free(self.doc);
        allocator.free(self.removed_numbers);
        self.raw_items.deinit(allocator);
    }
};

fn parseTypeSignature(
    allocator: std.mem.Allocator,
    _: std.mem.Allocator,
    v: std.json.Value,
    record_map: *const std.StringHashMap(ParsedRecord),
) error{ OutOfMemory, UnknownPrimitive, UnknownTypeKind, UnknownRecordId, MissingValue, ArrayMissingItem, MalformedRecordId }!TypeDescriptor {
    const kind = getJsonStr(v, "kind");
    const val = v.object.get("value") orelse return error.MissingValue;

    if (std.mem.eql(u8, kind, "primitive")) {
        const s = val.string;
        const p = PrimitiveType.fromStr(s) orelse return error.UnknownPrimitive;
        return TypeDescriptor{ .primitive = p };
    } else if (std.mem.eql(u8, kind, "optional")) {
        const inner_ptr = try allocator.create(TypeDescriptor);
        inner_ptr.* = try parseTypeSignature(allocator, allocator, val, record_map);
        return TypeDescriptor{ .optional = inner_ptr };
    } else if (std.mem.eql(u8, kind, "array")) {
        const item_val = val.object.get("item") orelse return error.ArrayMissingItem;
        const item_ptr = try allocator.create(TypeDescriptor);
        item_ptr.* = try parseTypeSignature(allocator, allocator, item_val, record_map);
        const key_extractor = blk: {
            if (val.object.get("key_extractor")) |ke| {
                break :blk try allocator.dupe(u8, ke.string);
            }
            break :blk try allocator.dupe(u8, "");
        };
        return TypeDescriptor{ .array = .{ .item_type = item_ptr, .key_extractor = key_extractor } };
    } else if (std.mem.eql(u8, kind, "record")) {
        const record_id = val.string;
        const rec = record_map.get(record_id) orelse return error.UnknownRecordId;
        // Return a minimal struct/enum descriptor without fields — they will be
        // filled in during the "resolved" pass.
        switch (rec.kind) {
            .struct_record => return TypeDescriptor{ .struct_record = .{
                .name = rec.name,
                .qualified_name = rec.qualified_name,
                .module_path = rec.module_path,
                .doc = rec.doc,
                .removed_numbers = rec.removed_numbers,
            } },
            .enum_record => return TypeDescriptor{ .enum_record = .{
                .name = rec.name,
                .qualified_name = rec.qualified_name,
                .module_path = rec.module_path,
                .doc = rec.doc,
                .removed_numbers = rec.removed_numbers,
            } },
        }
    } else {
        return error.UnknownTypeKind;
    }
}

fn parseTypeSignatureResolved(
    allocator: std.mem.Allocator,
    v: std.json.Value,
    record_map: *const std.StringHashMap(ParsedRecord),
    struct_fields_map: *const std.StringHashMap([]StructField),
    enum_variants_map: *const std.StringHashMap([]EnumVariant),
) error{ OutOfMemory, UnknownPrimitive, UnknownTypeKind, UnknownRecordId, MissingValue, ArrayMissingItem, MalformedRecordId, FieldMissingType }!TypeDescriptor {
    const kind = getJsonStr(v, "kind");
    const val = v.object.get("value") orelse return error.MissingValue;

    if (std.mem.eql(u8, kind, "primitive")) {
        const p = PrimitiveType.fromStr(val.string) orelse return error.UnknownPrimitive;
        return TypeDescriptor{ .primitive = p };
    } else if (std.mem.eql(u8, kind, "optional")) {
        const inner_ptr = try allocator.create(TypeDescriptor);
        inner_ptr.* = try parseTypeSignatureResolved(allocator, val, record_map, struct_fields_map, enum_variants_map);
        return TypeDescriptor{ .optional = inner_ptr };
    } else if (std.mem.eql(u8, kind, "array")) {
        const item_val = val.object.get("item") orelse return error.ArrayMissingItem;
        const item_ptr = try allocator.create(TypeDescriptor);
        item_ptr.* = try parseTypeSignatureResolved(allocator, item_val, record_map, struct_fields_map, enum_variants_map);
        const key_extractor = blk: {
            if (val.object.get("key_extractor")) |ke| break :blk try allocator.dupe(u8, ke.string);
            break :blk try allocator.dupe(u8, "");
        };
        return TypeDescriptor{ .array = .{ .item_type = item_ptr, .key_extractor = key_extractor } };
    } else if (std.mem.eql(u8, kind, "record")) {
        const record_id = val.string;
        const rec = record_map.get(record_id) orelse return error.UnknownRecordId;
        switch (rec.kind) {
            .struct_record => {
                const fields = struct_fields_map.get(record_id) orelse &[_]StructField{};
                return TypeDescriptor{ .struct_record = .{
                    .name = rec.name,
                    .qualified_name = rec.qualified_name,
                    .module_path = rec.module_path,
                    .doc = rec.doc,
                    .fields = fields,
                    .removed_numbers = rec.removed_numbers,
                } };
            },
            .enum_record => {
                const variants = enum_variants_map.get(record_id) orelse &[_]EnumVariant{};
                return TypeDescriptor{ .enum_record = .{
                    .name = rec.name,
                    .qualified_name = rec.qualified_name,
                    .module_path = rec.module_path,
                    .doc = rec.doc,
                    .variants = variants,
                    .removed_numbers = rec.removed_numbers,
                } };
            },
        }
    } else {
        return error.UnknownTypeKind;
    }
}

fn parseRemovedNumbers(allocator: std.mem.Allocator, rec: std.json.Value) ![]const i32 {
    if (rec.object.get("removed_numbers")) |rn| {
        const arr = rn.array.items;
        const nums = try allocator.alloc(i32, arr.len);
        for (arr, 0..) |item, i| {
            nums[i] = @intCast(item.integer);
        }
        return nums;
    }
    return &[_]i32{};
}

fn getJsonStr(v: std.json.Value, key: []const u8) []const u8 {
    if (v.object.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return "";
}

fn getJsonI32(v: std.json.Value, key: []const u8) i32 {
    if (v.object.get(key)) |val| {
        if (val == .integer) return @intCast(val.integer);
    }
    return 0;
}

// =============================================================================
// Tests — boolSerializer
// =============================================================================

test "boolSerializer: serialize dense true" {
    const alloc = std.testing.allocator;
    const s = boolSerializer();
    const out = try s.serialize(alloc, true, .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1", out);
}

test "boolSerializer: serialize dense false" {
    const alloc = std.testing.allocator;
    const s = boolSerializer();
    const out = try s.serialize(alloc, false, .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("0", out);
}

test "boolSerializer: serialize readable true" {
    const alloc = std.testing.allocator;
    const s = boolSerializer();
    const out = try s.serialize(alloc, true, .{ .format = .readableJson });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("true", out);
}

test "boolSerializer: serialize readable false" {
    const alloc = std.testing.allocator;
    const s = boolSerializer();
    const out = try s.serialize(alloc, false, .{ .format = .readableJson });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("false", out);
}

test "boolSerializer: deserialize bool literal true" {
    const alloc = std.testing.allocator;
    const s = boolSerializer();
    try std.testing.expect(try s.deserialize(alloc, "true", .{}));
    try std.testing.expect(!try s.deserialize(alloc, "false", .{}));
}

test "boolSerializer: deserialize number 1 and 0" {
    const alloc = std.testing.allocator;
    const s = boolSerializer();
    try std.testing.expect(try s.deserialize(alloc, "1", .{}));
    try std.testing.expect(!try s.deserialize(alloc, "0", .{}));
}

test "boolSerializer: deserialize nonzero number is true" {
    const alloc = std.testing.allocator;
    const s = boolSerializer();
    try std.testing.expect(try s.deserialize(alloc, "42", .{}));
}

test "boolSerializer: deserialize float zero is false" {
    const alloc = std.testing.allocator;
    const s = boolSerializer();
    try std.testing.expect(!try s.deserialize(alloc, "0.0", .{}));
}

test "boolSerializer: deserialize string zero is false" {
    // The string "0" is the only falsy string value.
    const alloc = std.testing.allocator;
    const s = boolSerializer();
    try std.testing.expect(!try s.deserialize(alloc, "\"0\"", .{}));
}

test "boolSerializer: deserialize string nonzero is true" {
    const alloc = std.testing.allocator;
    const s = boolSerializer();
    try std.testing.expect(try s.deserialize(alloc, "\"1\"", .{}));
    try std.testing.expect(try s.deserialize(alloc, "\"true\"", .{}));
}

test "boolSerializer: deserialize null is false" {
    const alloc = std.testing.allocator;
    const s = boolSerializer();
    try std.testing.expect(!try s.deserialize(alloc, "null", .{}));
}

test "boolSerializer: binary round-trip true" {
    const alloc = std.testing.allocator;
    const s = boolSerializer();
    const bytes = try s.serialize(alloc, true, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expect(try s.deserialize(alloc, bytes, .{}));
}

test "boolSerializer: binary round-trip false" {
    const alloc = std.testing.allocator;
    const s = boolSerializer();
    const bytes = try s.serialize(alloc, false, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expect(!try s.deserialize(alloc, bytes, .{}));
}

test "boolSerializer: binary encoding true is skir then 0x01" {
    const alloc = std.testing.allocator;
    const bytes = try boolSerializer().serialize(alloc, true, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, "skir\x01", bytes);
}

test "boolSerializer: binary encoding false is skir then 0x00" {
    const alloc = std.testing.allocator;
    const bytes = try boolSerializer().serialize(alloc, false, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, "skir\x00", bytes);
}

test "boolSerializer: typeDescriptor is primitive bool" {
    const td = boolSerializer().typeDescriptor();
    try std.testing.expect(td == .primitive);
    try std.testing.expectEqual(PrimitiveType.Bool, td.primitive);
}

// =============================================================================
// Tests — int32Serializer
// =============================================================================

test "int32Serializer: serialize zero" {
    const alloc = std.testing.allocator;
    const out = try int32Serializer().serialize(alloc, 0, .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("0", out);
}

test "int32Serializer: serialize positive" {
    const alloc = std.testing.allocator;
    const out = try int32Serializer().serialize(alloc, 42, .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("42", out);
}

test "int32Serializer: serialize negative" {
    const alloc = std.testing.allocator;
    const out = try int32Serializer().serialize(alloc, -1, .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("-1", out);
}

test "int32Serializer: serialize same in readable mode" {
    const alloc = std.testing.allocator;
    const dense = try int32Serializer().serialize(alloc, 12345, .{});
    defer alloc.free(dense);
    const readable = try int32Serializer().serialize(alloc, 12345, .{ .format = .readableJson });
    defer alloc.free(readable);
    try std.testing.expectEqualStrings(dense, readable);
}

test "int32Serializer: deserialize integer" {
    const alloc = std.testing.allocator;
    const s = int32Serializer();
    try std.testing.expectEqual(@as(i32, 42), try s.deserialize(alloc, "42", .{}));
    try std.testing.expectEqual(@as(i32, -1), try s.deserialize(alloc, "-1", .{}));
    try std.testing.expectEqual(@as(i32, 0), try s.deserialize(alloc, "0", .{}));
}

test "int32Serializer: deserialize float truncates" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(i32, 3), try int32Serializer().deserialize(alloc, "3.9", .{}));
    try std.testing.expectEqual(@as(i32, -1), try int32Serializer().deserialize(alloc, "-1.5", .{}));
}

test "int32Serializer: deserialize string" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(i32, 7), try int32Serializer().deserialize(alloc, "\"7\"", .{}));
}

test "int32Serializer: deserialize unparseable string is zero" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(i32, 0), try int32Serializer().deserialize(alloc, "\"abc\"", .{}));
}

test "int32Serializer: deserialize null is zero" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(i32, 0), try int32Serializer().deserialize(alloc, "null", .{}));
}

test "int32Serializer: binary small positive is single byte" {
    const alloc = std.testing.allocator;
    const s = int32Serializer();
    const b0 = try s.serialize(alloc, 0, .{ .format = .binary });
    defer alloc.free(b0);
    try std.testing.expectEqualSlices(u8, "skir\x00", b0);
    const b1 = try s.serialize(alloc, 1, .{ .format = .binary });
    defer alloc.free(b1);
    try std.testing.expectEqualSlices(u8, "skir\x01", b1);
    const b231 = try s.serialize(alloc, 231, .{ .format = .binary });
    defer alloc.free(b231);
    try std.testing.expectEqualSlices(u8, "skir\xe7", b231);
}

test "int32Serializer: binary u16 range" {
    // 232..=65535 → wire 232 + u16 LE
    const alloc = std.testing.allocator;
    const bytes = try int32Serializer().serialize(alloc, 1000, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 232, 232, 3 }, bytes[4..]); // 1000 = 0x03E8 LE
}

test "int32Serializer: binary u32 range" {
    // >= 65536 → wire 233 + u32 LE
    const alloc = std.testing.allocator;
    const bytes = try int32Serializer().serialize(alloc, 65536, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 233, 0, 0, 1, 0 }, bytes[4..]);
}

test "int32Serializer: binary small negative" {
    // -256..=-1 → wire 235 + u8(v+256)
    const alloc = std.testing.allocator;
    const bytes = try int32Serializer().serialize(alloc, -1, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 235, 255 }, bytes[4..]);
}

test "int32Serializer: binary medium negative" {
    // -65536..=-257 → wire 236 + u16 LE
    const alloc = std.testing.allocator;
    const bytes = try int32Serializer().serialize(alloc, -300, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 236, 212, 254 }, bytes[4..]); // -300+65536=65236=0xFED4 LE
}

test "int32Serializer: binary large negative" {
    // < -65536 → wire 237 + i32 LE
    const alloc = std.testing.allocator;
    const bytes = try int32Serializer().serialize(alloc, -100_000, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 237, 96, 121, 254, 255 }, bytes[4..]);
}

test "int32Serializer: binary round-trip" {
    const alloc = std.testing.allocator;
    const s = int32Serializer();
    for ([_]i32{ 0, 1, 42, 231, 232, 300, 65535, 65536, std.math.maxInt(i32), -1, -255, -256, -65536, std.math.minInt(i32) }) |v| {
        const bytes = try s.serialize(alloc, v, .{ .format = .binary });
        defer alloc.free(bytes);
        const decoded = try s.deserialize(alloc, bytes, .{});
        try std.testing.expectEqual(v, decoded);
    }
}

test "int32Serializer: typeDescriptor is primitive int32" {
    const td = int32Serializer().typeDescriptor();
    try std.testing.expect(td == .primitive);
    try std.testing.expectEqual(PrimitiveType.Int32, td.primitive);
}

// =============================================================================
// Tests — int64Serializer
// =============================================================================

test "int64Serializer: serialize safe integer range" {
    const alloc = std.testing.allocator;
    const s = int64Serializer();
    const b0 = try s.serialize(alloc, 0, .{});
    defer alloc.free(b0);
    try std.testing.expectEqualStrings("0", b0);
    const bmax = try s.serialize(alloc, 9_007_199_254_740_991, .{});
    defer alloc.free(bmax);
    try std.testing.expectEqualStrings("9007199254740991", bmax);
    const bmin = try s.serialize(alloc, -9_007_199_254_740_991, .{});
    defer alloc.free(bmin);
    try std.testing.expectEqualStrings("-9007199254740991", bmin);
}

test "int64Serializer: serialize large value is quoted" {
    const alloc = std.testing.allocator;
    const s = int64Serializer();
    const b = try s.serialize(alloc, 9_007_199_254_740_992, .{});
    defer alloc.free(b);
    try std.testing.expectEqualStrings("\"9007199254740992\"", b);
    const bmax = try s.serialize(alloc, std.math.maxInt(i64), .{});
    defer alloc.free(bmax);
    try std.testing.expectEqualStrings("\"9223372036854775807\"", bmax);
}

test "int64Serializer: deserialize integer" {
    const alloc = std.testing.allocator;
    const s = int64Serializer();
    try std.testing.expectEqual(@as(i64, 42), try s.deserialize(alloc, "42", .{}));
    try std.testing.expectEqual(@as(i64, -1), try s.deserialize(alloc, "-1", .{}));
}

test "int64Serializer: deserialize quoted large" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(
        @as(i64, 9_007_199_254_740_992),
        try int64Serializer().deserialize(alloc, "\"9007199254740992\"", .{}),
    );
}

test "int64Serializer: deserialize null is zero" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(i64, 0), try int64Serializer().deserialize(alloc, "null", .{}));
}

test "int64Serializer: binary fits i32 reuses i32 encoding" {
    const alloc = std.testing.allocator;
    const b0 = try int64Serializer().serialize(alloc, 0, .{ .format = .binary });
    defer alloc.free(b0);
    try std.testing.expectEqualSlices(u8, "skir\x00", b0);
    const b42 = try int64Serializer().serialize(alloc, 42, .{ .format = .binary });
    defer alloc.free(b42);
    try std.testing.expectEqualSlices(u8, "skir\x2a", b42);
}

test "int64Serializer: binary wire 238 for large values" {
    const alloc = std.testing.allocator;
    const v: i64 = @as(i64, std.math.maxInt(i32)) + 1;
    const bytes = try int64Serializer().serialize(alloc, v, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqual(@as(u8, 238), bytes[4]);
    try std.testing.expectEqualSlices(u8, &std.mem.toBytes(std.mem.nativeToLittle(i64, v)), bytes[5..]);
}

test "int64Serializer: binary round-trip" {
    const alloc = std.testing.allocator;
    const s = int64Serializer();
    for ([_]i64{ 0, 1, 231, 232, 65536, std.math.maxInt(i32), @as(i64, std.math.maxInt(i32)) + 1, std.math.maxInt(i64), -1, std.math.minInt(i32), std.math.minInt(i64) }) |v| {
        const bytes = try s.serialize(alloc, v, .{ .format = .binary });
        defer alloc.free(bytes);
        const decoded = try s.deserialize(alloc, bytes, .{});
        try std.testing.expectEqual(v, decoded);
    }
}

test "int64Serializer: typeDescriptor is primitive int64" {
    const td = int64Serializer().typeDescriptor();
    try std.testing.expect(td == .primitive);
    try std.testing.expectEqual(PrimitiveType.Int64, td.primitive);
}

// =============================================================================
// Tests — hash64Serializer
// =============================================================================

test "hash64Serializer: serialize safe integer range" {
    const alloc = std.testing.allocator;
    const s = hash64Serializer();
    const b0 = try s.serialize(alloc, 0, .{});
    defer alloc.free(b0);
    try std.testing.expectEqualStrings("0", b0);
    const bmax = try s.serialize(alloc, 9_007_199_254_740_991, .{});
    defer alloc.free(bmax);
    try std.testing.expectEqualStrings("9007199254740991", bmax);
}

test "hash64Serializer: serialize large value is quoted" {
    const alloc = std.testing.allocator;
    const s = hash64Serializer();
    const b = try s.serialize(alloc, 9_007_199_254_740_992, .{});
    defer alloc.free(b);
    try std.testing.expectEqualStrings("\"9007199254740992\"", b);
    const bmax = try s.serialize(alloc, std.math.maxInt(u64), .{});
    defer alloc.free(bmax);
    try std.testing.expectEqualStrings("\"18446744073709551615\"", bmax);
}

test "hash64Serializer: deserialize integer" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(u64, 42), try hash64Serializer().deserialize(alloc, "42", .{}));
}

test "hash64Serializer: deserialize negative number is zero" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(u64, 0), try hash64Serializer().deserialize(alloc, "-1.0", .{}));
}

test "hash64Serializer: deserialize quoted large" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(
        @as(u64, 9_007_199_254_740_992),
        try hash64Serializer().deserialize(alloc, "\"9007199254740992\"", .{}),
    );
}

test "hash64Serializer: deserialize null is zero" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(u64, 0), try hash64Serializer().deserialize(alloc, "null", .{}));
}

test "hash64Serializer: binary single byte range" {
    const alloc = std.testing.allocator;
    const s = hash64Serializer();
    const b0 = try s.serialize(alloc, 0, .{ .format = .binary });
    defer alloc.free(b0);
    try std.testing.expectEqualSlices(u8, "skir\x00", b0);
    const b231 = try s.serialize(alloc, 231, .{ .format = .binary });
    defer alloc.free(b231);
    try std.testing.expectEqualSlices(u8, "skir\xe7", b231);
}

test "hash64Serializer: binary u16 range" {
    // 232..=65535 → wire 232 + u16 LE
    const alloc = std.testing.allocator;
    const bytes = try hash64Serializer().serialize(alloc, 1000, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 232, 232, 3 }, bytes[4..]);
}

test "hash64Serializer: binary u32 range" {
    // 65536..=4294967295 → wire 233 + u32 LE
    const alloc = std.testing.allocator;
    const bytes = try hash64Serializer().serialize(alloc, 65536, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 233, 0, 0, 1, 0 }, bytes[4..]);
}

test "hash64Serializer: binary u64 range" {
    // >= 2^32 → wire 234 + u64 LE
    const alloc = std.testing.allocator;
    const v: u64 = 4_294_967_296;
    const bytes = try hash64Serializer().serialize(alloc, v, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqual(@as(u8, 234), bytes[4]);
    try std.testing.expectEqualSlices(u8, &std.mem.toBytes(std.mem.nativeToLittle(u64, v)), bytes[5..]);
}

test "hash64Serializer: binary round-trip" {
    const alloc = std.testing.allocator;
    const s = hash64Serializer();
    for ([_]u64{ 0, 1, 231, 232, 65535, 65536, 4_294_967_295, 4_294_967_296, std.math.maxInt(u64) }) |v| {
        const bytes = try s.serialize(alloc, v, .{ .format = .binary });
        defer alloc.free(bytes);
        const decoded = try s.deserialize(alloc, bytes, .{});
        try std.testing.expectEqual(v, decoded);
    }
}

test "hash64Serializer: typeDescriptor is primitive hash64" {
    const td = hash64Serializer().typeDescriptor();
    try std.testing.expect(td == .primitive);
    try std.testing.expectEqual(PrimitiveType.Hash64, td.primitive);
}

// =============================================================================
// Tests — millisToIso8601
// =============================================================================

test "millisToIso8601: epoch" {
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", &millisToIso8601(0));
}

test "millisToIso8601: known date" {
    try std.testing.expectEqualStrings("2009-02-13T23:31:30.000Z", &millisToIso8601(1_234_567_890_000));
}

test "millisToIso8601: milliseconds" {
    try std.testing.expectEqualStrings("2009-02-13T23:31:30.123Z", &millisToIso8601(1_234_567_890_123));
}

test "millisToIso8601: negative millis" {
    try std.testing.expectEqualStrings("1969-12-31T23:59:59.000Z", &millisToIso8601(-1000));
}

// =============================================================================
// Tests — timestampSerializer
// =============================================================================

test "timestampSerializer: serialize dense epoch" {
    const alloc = std.testing.allocator;
    const out = try timestampSerializer().serialize(alloc, Timestamp.epoch, .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("0", out);
}

test "timestampSerializer: serialize dense nonzero" {
    const alloc = std.testing.allocator;
    const ts = Timestamp{ .unix_millis = 1_234_567_890_000 };
    const out = try timestampSerializer().serialize(alloc, ts, .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("1234567890000", out);
}

test "timestampSerializer: serialize readable" {
    const alloc = std.testing.allocator;
    const ts = Timestamp{ .unix_millis = 1_234_567_890_000 };
    const out = try timestampSerializer().serialize(alloc, ts, .{ .format = .readableJson });
    defer alloc.free(out);
    const expected = "{\n  \"unix_millis\": 1234567890000,\n  \"formatted\": \"2009-02-13T23:31:30.000Z\"\n}";
    try std.testing.expectEqualStrings(expected, out);
}

test "timestampSerializer: deserialize number" {
    const alloc = std.testing.allocator;
    const ts = try timestampSerializer().deserialize(alloc, "1234567890000", .{});
    try std.testing.expectEqual(@as(i64, 1_234_567_890_000), ts.unix_millis);
}

test "timestampSerializer: deserialize string" {
    const alloc = std.testing.allocator;
    const ts = try timestampSerializer().deserialize(alloc, "\"1234567890000\"", .{});
    try std.testing.expectEqual(@as(i64, 1_234_567_890_000), ts.unix_millis);
}

test "timestampSerializer: deserialize readable object" {
    const alloc = std.testing.allocator;
    const json = "{\"unix_millis\": 1234567890000, \"formatted\": \"2009-02-13T23:31:30.000Z\"}";
    const ts = try timestampSerializer().deserialize(alloc, json, .{});
    try std.testing.expectEqual(@as(i64, 1_234_567_890_000), ts.unix_millis);
}

test "timestampSerializer: deserialize null is epoch" {
    const alloc = std.testing.allocator;
    const ts = try timestampSerializer().deserialize(alloc, "null", .{});
    try std.testing.expectEqual(@as(i64, 0), ts.unix_millis);
}

test "timestampSerializer: binary epoch is single byte zero" {
    const alloc = std.testing.allocator;
    const bytes = try timestampSerializer().serialize(alloc, Timestamp.epoch, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, "skir\x00", bytes);
}

test "timestampSerializer: binary nonzero is wire 239 + i64 LE" {
    const alloc = std.testing.allocator;
    const ts = Timestamp{ .unix_millis = 1_234_567_890_000 };
    const bytes = try timestampSerializer().serialize(alloc, ts, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqual(@as(u8, 239), bytes[4]);
    try std.testing.expectEqualSlices(u8, &std.mem.toBytes(std.mem.nativeToLittle(i64, 1_234_567_890_000)), bytes[5..]);
}

test "timestampSerializer: binary round-trip" {
    const alloc = std.testing.allocator;
    const s = timestampSerializer();
    for ([_]i64{ 0, 1, 1_234_567_890_000, -1000 }) |ms| {
        const ts = Timestamp{ .unix_millis = ms };
        const bytes = try s.serialize(alloc, ts, .{ .format = .binary });
        defer alloc.free(bytes);
        const decoded = try s.deserialize(alloc, bytes, .{});
        try std.testing.expectEqual(ms, decoded.unix_millis);
    }
}

test "timestampSerializer: typeDescriptor is primitive timestamp" {
    const td = timestampSerializer().typeDescriptor();
    try std.testing.expect(td == .primitive);
    try std.testing.expectEqual(PrimitiveType.Timestamp, td.primitive);
}

// =============================================================================
// Tests — optionalSerializer
// =============================================================================

test "optionalSerializer: serialize dense none is null" {
    const alloc = std.testing.allocator;
    const out = try optionalSerializer(i32, int32Serializer()).serialize(alloc, null, .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("null", out);
}

test "optionalSerializer: serialize dense some delegates" {
    const alloc = std.testing.allocator;
    const out = try optionalSerializer(i32, int32Serializer()).serialize(alloc, @as(?i32, 42), .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("42", out);
}

test "optionalSerializer: serialize readable none is null" {
    const alloc = std.testing.allocator;
    const out = try optionalSerializer(i32, int32Serializer()).serialize(alloc, null, .{ .format = .readableJson });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("null", out);
}

test "optionalSerializer: serialize readable some delegates" {
    const alloc = std.testing.allocator;
    const out = try optionalSerializer(i32, int32Serializer()).serialize(alloc, @as(?i32, 42), .{ .format = .readableJson });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("42", out);
}

test "optionalSerializer: deserialize null is none" {
    const alloc = std.testing.allocator;
    const v = try optionalSerializer(i32, int32Serializer()).deserialize(alloc, "null", .{});
    try std.testing.expectEqual(@as(?i32, null), v);
}

test "optionalSerializer: deserialize value is some" {
    const alloc = std.testing.allocator;
    const v = try optionalSerializer(i32, int32Serializer()).deserialize(alloc, "7", .{});
    try std.testing.expectEqual(@as(?i32, 7), v);
}

test "optionalSerializer: binary none is wire 255" {
    const alloc = std.testing.allocator;
    const bytes = try optionalSerializer(i32, int32Serializer()).serialize(alloc, null, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, "skir\xff", bytes);
}

test "optionalSerializer: binary some delegates" {
    const alloc = std.testing.allocator;
    const bytes = try optionalSerializer(i32, int32Serializer()).serialize(alloc, @as(?i32, 5), .{ .format = .binary });
    defer alloc.free(bytes);
    // Some(5): int32 encodes 5 as a single wire byte 5.
    try std.testing.expectEqualSlices(u8, "skir\x05", bytes);
}

test "optionalSerializer: binary round-trip" {
    const alloc = std.testing.allocator;
    const s = optionalSerializer(i32, int32Serializer());
    for ([_]?i32{ null, 0, 42, -1 }) |v| {
        const bytes = try s.serialize(alloc, v, .{ .format = .binary });
        defer alloc.free(bytes);
        const got = try s.deserialize(alloc, bytes, .{});
        try std.testing.expectEqual(v, got);
    }
}

test "optionalSerializer: typeDescriptor is optional of int32" {
    const td = optionalSerializer(i32, int32Serializer()).typeDescriptor();
    try std.testing.expect(td == .optional);
    try std.testing.expectEqual(PrimitiveType.Int32, td.optional.primitive);
}

// =============================================================================
// Tests — arraySerializer
// =============================================================================

test "arraySerializer: serialize dense empty" {
    const alloc = std.testing.allocator;
    const out = try arraySerializer(i32, int32Serializer()).serialize(alloc, &.{}, .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("[]", out);
}

test "arraySerializer: serialize dense nonempty" {
    const alloc = std.testing.allocator;
    const items = [_]i32{ 1, 2, 3 };
    const out = try arraySerializer(i32, int32Serializer()).serialize(alloc, &items, .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("[1,2,3]", out);
}

test "arraySerializer: serialize readable empty" {
    const alloc = std.testing.allocator;
    const out = try arraySerializer(i32, int32Serializer()).serialize(alloc, &.{}, .{ .format = .readableJson });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("[]", out);
}

test "arraySerializer: serialize readable nonempty" {
    const alloc = std.testing.allocator;
    const items = [_]i32{ 1, 2 };
    const out = try arraySerializer(i32, int32Serializer()).serialize(alloc, &items, .{ .format = .readableJson });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("[\n  1,\n  2\n]", out);
}

test "arraySerializer: deserialize array" {
    const alloc = std.testing.allocator;
    const result = try arraySerializer(i32, int32Serializer()).deserialize(alloc, "[10,20,30]", .{});
    defer alloc.free(result);
    try std.testing.expectEqualSlices(i32, &.{ 10, 20, 30 }, result);
}

test "arraySerializer: deserialize null is empty" {
    const alloc = std.testing.allocator;
    const result = try arraySerializer(i32, int32Serializer()).deserialize(alloc, "null", .{});
    defer alloc.free(result);
    try std.testing.expectEqualSlices(i32, &.{}, result);
}

test "arraySerializer: binary empty is wire 246" {
    const alloc = std.testing.allocator;
    const bytes = try arraySerializer(i32, int32Serializer()).serialize(alloc, &.{}, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, "skir\xf6", bytes);
}

test "arraySerializer: binary nonempty wire byte" {
    const alloc = std.testing.allocator;
    const items = [_]i32{ 1, 2, 3 };
    const bytes = try arraySerializer(i32, int32Serializer()).serialize(alloc, &items, .{ .format = .binary });
    defer alloc.free(bytes);
    // 3 items → wire 249 (246 + 3), then each int32 as single byte
    try std.testing.expectEqualSlices(u8, "skir\xf9\x01\x02\x03", bytes);
}

test "arraySerializer: binary round-trip" {
    const alloc = std.testing.allocator;
    const s = arraySerializer(i32, int32Serializer());
    const cases = [_][]const i32{ &.{}, &.{0}, &.{ 1, 2, 3 }, &.{ -1, 0, 1 } };
    for (cases) |v| {
        const bytes = try s.serialize(alloc, v, .{ .format = .binary });
        defer alloc.free(bytes);
        const got = try s.deserialize(alloc, bytes, .{});
        defer alloc.free(got);
        try std.testing.expectEqualSlices(i32, v, got);
    }
}

test "arraySerializer: typeDescriptor is array of int32" {
    const td = arraySerializer(i32, int32Serializer()).typeDescriptor();
    try std.testing.expect(td == .array);
    try std.testing.expectEqual(PrimitiveType.Int32, td.array.item_type.primitive);
}

// =============================================================================
// Tests — bytesSerializer
// =============================================================================

test "bytesSerializer: serialize dense base64" {
    const alloc = std.testing.allocator;
    const out = try bytesSerializer().serialize(alloc, "hello", .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("\"aGVsbG8=\"", out);
}

test "bytesSerializer: serialize readable hex" {
    const alloc = std.testing.allocator;
    const out = try bytesSerializer().serialize(alloc, "hello", .{ .format = .readableJson });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("\"hex:68656c6c6f\"", out);
}

test "bytesSerializer: serialize dense empty" {
    const alloc = std.testing.allocator;
    const out = try bytesSerializer().serialize(alloc, "", .{});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("\"\"", out);
}

test "bytesSerializer: deserialize base64" {
    const alloc = std.testing.allocator;
    const result = try bytesSerializer().deserialize(alloc, "\"aGVsbG8=\"", .{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "bytesSerializer: deserialize hex" {
    const alloc = std.testing.allocator;
    const result = try bytesSerializer().deserialize(alloc, "\"hex:68656c6c6f\"", .{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "bytesSerializer: deserialize number is empty" {
    const alloc = std.testing.allocator;
    const result = try bytesSerializer().deserialize(alloc, "0", .{});
    defer alloc.free(result);
    try std.testing.expectEqualSlices(u8, &.{}, result);
}

test "bytesSerializer: deserialize null is empty" {
    const alloc = std.testing.allocator;
    const result = try bytesSerializer().deserialize(alloc, "null", .{});
    defer alloc.free(result);
    try std.testing.expectEqualSlices(u8, &.{}, result);
}

test "bytesSerializer: binary empty is wire 244" {
    const alloc = std.testing.allocator;
    const bytes = try bytesSerializer().serialize(alloc, "", .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, "skir\xf4", bytes);
}

test "bytesSerializer: binary nonempty" {
    const alloc = std.testing.allocator;
    const bytes = try bytesSerializer().serialize(alloc, &.{ 1, 2, 3 }, .{ .format = .binary });
    defer alloc.free(bytes);
    // wire 245 + length 3 (single byte) + raw bytes
    try std.testing.expectEqualSlices(u8, "skir\xf5\x03\x01\x02\x03", bytes);
}

test "bytesSerializer: binary round-trip" {
    const alloc = std.testing.allocator;
    const s = bytesSerializer();
    const cases = [_][]const u8{ &.{}, &.{0}, "hello", &([_]u8{0xFF} ** 300) };
    for (cases) |data| {
        const bytes = try s.serialize(alloc, data, .{ .format = .binary });
        defer alloc.free(bytes);
        const got = try s.deserialize(alloc, bytes, .{});
        defer alloc.free(got);
        try std.testing.expectEqualSlices(u8, data, got);
    }
}

test "bytesSerializer: typeDescriptor is primitive bytes" {
    const td = bytesSerializer().typeDescriptor();
    try std.testing.expect(td == .primitive);
    try std.testing.expectEqual(PrimitiveType.Bytes, td.primitive);
}

// =============================================================================
// float32Serializer tests
// =============================================================================

test "float32Serializer: serialize zero" {
    const alloc = std.testing.allocator;
    const s = try float32Serializer().serialize(alloc, 0.0, .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("0", s);
}

test "float32Serializer: serialize finite" {
    const alloc = std.testing.allocator;
    const s = try float32Serializer().serialize(alloc, 1.5, .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("1.5", s);
}

test "float32Serializer: serialize NaN" {
    const alloc = std.testing.allocator;
    const s = try float32Serializer().serialize(alloc, std.math.nan(f32), .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"NaN\"", s);
}

test "float32Serializer: serialize Infinity" {
    const alloc = std.testing.allocator;
    const s = try float32Serializer().serialize(alloc, std.math.inf(f32), .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"Infinity\"", s);
}

test "float32Serializer: serialize -Infinity" {
    const alloc = std.testing.allocator;
    const s = try float32Serializer().serialize(alloc, -std.math.inf(f32), .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"-Infinity\"", s);
}

test "float32Serializer: deserialize number" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(f32, 1.5), try float32Serializer().deserialize(alloc, "1.5", .{}));
}

test "float32Serializer: deserialize string NaN" {
    const alloc = std.testing.allocator;
    const v = try float32Serializer().deserialize(alloc, "\"NaN\"", .{});
    try std.testing.expect(std.math.isNan(v));
}

test "float32Serializer: deserialize string Infinity" {
    const alloc = std.testing.allocator;
    const v = try float32Serializer().deserialize(alloc, "\"Infinity\"", .{});
    try std.testing.expectEqual(std.math.inf(f32), v);
}

test "float32Serializer: deserialize null is zero" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(f32, 0.0), try float32Serializer().deserialize(alloc, "null", .{}));
}

test "float32Serializer: binary zero is wire 0" {
    const alloc = std.testing.allocator;
    const bytes = try float32Serializer().serialize(alloc, 0.0, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, "skir\x00", bytes);
}

test "float32Serializer: binary nonzero is wire 240 + LE bits" {
    const alloc = std.testing.allocator;
    const bytes = try float32Serializer().serialize(alloc, 1.5, .{ .format = .binary });
    defer alloc.free(bytes);
    // 1.5f32 bits = 0x3FC00000, little-endian = 00 00 c0 3f
    try std.testing.expectEqualSlices(u8, "skir\xf0\x00\x00\xc0\x3f", bytes);
}

test "float32Serializer: binary round-trip" {
    const alloc = std.testing.allocator;
    const s = float32Serializer();
    const cases = [_]f32{ 0.0, 1.0, -1.0, 1.5, 3.14, std.math.inf(f32), -std.math.inf(f32) };
    for (cases) |v| {
        const bytes = try s.serialize(alloc, v, .{ .format = .binary });
        defer alloc.free(bytes);
        const got = try s.deserialize(alloc, bytes, .{});
        try std.testing.expectEqual(v, got);
    }
}

test "float32Serializer: typeDescriptor is primitive float32" {
    const td = float32Serializer().typeDescriptor();
    try std.testing.expect(td == .primitive);
    try std.testing.expectEqual(PrimitiveType.Float32, td.primitive);
}

// =============================================================================
// float64Serializer tests
// =============================================================================

test "float64Serializer: serialize zero" {
    const alloc = std.testing.allocator;
    const s = try float64Serializer().serialize(alloc, 0.0, .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("0", s);
}

test "float64Serializer: serialize finite" {
    const alloc = std.testing.allocator;
    const s = try float64Serializer().serialize(alloc, 1.5, .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("1.5", s);
}

test "float64Serializer: serialize NaN" {
    const alloc = std.testing.allocator;
    const s = try float64Serializer().serialize(alloc, std.math.nan(f64), .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"NaN\"", s);
}

test "float64Serializer: serialize Infinity" {
    const alloc = std.testing.allocator;
    const s = try float64Serializer().serialize(alloc, std.math.inf(f64), .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"Infinity\"", s);
}

test "float64Serializer: serialize -Infinity" {
    const alloc = std.testing.allocator;
    const s = try float64Serializer().serialize(alloc, -std.math.inf(f64), .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"-Infinity\"", s);
}

test "float64Serializer: deserialize number" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(f64, 1.5), try float64Serializer().deserialize(alloc, "1.5", .{}));
}

test "float64Serializer: deserialize string NaN" {
    const alloc = std.testing.allocator;
    const v = try float64Serializer().deserialize(alloc, "\"NaN\"", .{});
    try std.testing.expect(std.math.isNan(v));
}

test "float64Serializer: deserialize string Infinity" {
    const alloc = std.testing.allocator;
    const v = try float64Serializer().deserialize(alloc, "\"Infinity\"", .{});
    try std.testing.expectEqual(std.math.inf(f64), v);
}

test "float64Serializer: deserialize null is zero" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(f64, 0.0), try float64Serializer().deserialize(alloc, "null", .{}));
}

test "float64Serializer: binary zero is wire 0" {
    const alloc = std.testing.allocator;
    const bytes = try float64Serializer().serialize(alloc, 0.0, .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, "skir\x00", bytes);
}

test "float64Serializer: binary nonzero is wire 241 + LE bits" {
    const alloc = std.testing.allocator;
    const bytes = try float64Serializer().serialize(alloc, 1.5, .{ .format = .binary });
    defer alloc.free(bytes);
    // 1.5f64 bits = 0x3FF8000000000000, little-endian = 00 00 00 00 00 00 f8 3f
    try std.testing.expectEqualSlices(u8, "skir\xf1\x00\x00\x00\x00\x00\x00\xf8\x3f", bytes);
}

test "float64Serializer: binary round-trip" {
    const alloc = std.testing.allocator;
    const s = float64Serializer();
    const cases = [_]f64{ 0.0, 1.0, -1.0, 1.5, 3.14, std.math.inf(f64), -std.math.inf(f64) };
    for (cases) |v| {
        const bytes = try s.serialize(alloc, v, .{ .format = .binary });
        defer alloc.free(bytes);
        const got = try s.deserialize(alloc, bytes, .{});
        try std.testing.expectEqual(v, got);
    }
}

test "float64Serializer: typeDescriptor is primitive float64" {
    const td = float64Serializer().typeDescriptor();
    try std.testing.expect(td == .primitive);
    try std.testing.expectEqual(PrimitiveType.Float64, td.primitive);
}

// =============================================================================
// stringSerializer tests
// =============================================================================

test "stringSerializer: serialize plain string" {
    const alloc = std.testing.allocator;
    const s = try stringSerializer().serialize(alloc, "hello", .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"hello\"", s);
}

test "stringSerializer: serialize empty" {
    const alloc = std.testing.allocator;
    const s = try stringSerializer().serialize(alloc, "", .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"\"", s);
}

test "stringSerializer: serialize readable is same as dense" {
    const alloc = std.testing.allocator;
    const dense = try stringSerializer().serialize(alloc, "hello", .{ .format = .denseJson });
    defer alloc.free(dense);
    const readable = try stringSerializer().serialize(alloc, "hello", .{ .format = .readableJson });
    defer alloc.free(readable);
    try std.testing.expectEqualStrings(dense, readable);
}

test "stringSerializer: serialize escapes quote and backslash" {
    const alloc = std.testing.allocator;
    const s = try stringSerializer().serialize(alloc, "say \"hi\" \\n", .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"say \\\"hi\\\" \\\\n\"", s);
}

test "stringSerializer: serialize escapes control characters" {
    const alloc = std.testing.allocator;
    const s = try stringSerializer().serialize(alloc, "\x00\n\r\t\x08\x0C\x1B", .{});
    defer alloc.free(s);
    try std.testing.expectEqualStrings("\"\\u0000\\n\\r\\t\\b\\f\\u001b\"", s);
}

test "stringSerializer: deserialize string" {
    const alloc = std.testing.allocator;
    const result = try stringSerializer().deserialize(alloc, "\"hello\"", .{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "stringSerializer: deserialize number is empty" {
    const alloc = std.testing.allocator;
    const result = try stringSerializer().deserialize(alloc, "42", .{});
    defer alloc.free(result);
    try std.testing.expectEqualSlices(u8, &.{}, result);
}

test "stringSerializer: deserialize null is empty" {
    const alloc = std.testing.allocator;
    const result = try stringSerializer().deserialize(alloc, "null", .{});
    defer alloc.free(result);
    try std.testing.expectEqualSlices(u8, &.{}, result);
}

test "stringSerializer: binary empty is wire 242" {
    const alloc = std.testing.allocator;
    const bytes = try stringSerializer().serialize(alloc, "", .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, "skir\xf2", bytes);
}

test "stringSerializer: binary nonempty is wire 243 + length + utf8" {
    const alloc = std.testing.allocator;
    const bytes = try stringSerializer().serialize(alloc, "hello", .{ .format = .binary });
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, "skir\xf3\x05hello", bytes);
}

test "stringSerializer: binary round-trip" {
    const alloc = std.testing.allocator;
    const s = stringSerializer();
    const cases = [_][]const u8{ "", "hello", "Unicode: \xe2\x9c\x93", "a" ** 300 };
    for (cases) |str| {
        const bytes = try s.serialize(alloc, str, .{ .format = .binary });
        defer alloc.free(bytes);
        const got = try s.deserialize(alloc, bytes, .{});
        defer alloc.free(got);
        try std.testing.expectEqualStrings(str, got);
    }
}

test "stringSerializer: decode invalid utf8 replaced with U+FFFD" {
    const alloc = std.testing.allocator;
    // Manually craft a binary payload with invalid UTF-8 byte 0xFF
    const payload = "skir\xf3\x01\xff";
    const result = try stringSerializer().deserialize(alloc, payload, .{});
    defer alloc.free(result);
    // 0xFF is not valid UTF-8; should be replaced with U+FFFD = EF BF BD
    try std.testing.expectEqualSlices(u8, "\xef\xbf\xbd", result);
}

test "stringSerializer: typeDescriptor is primitive string" {
    const td = stringSerializer().typeDescriptor();
    try std.testing.expect(td == .primitive);
    try std.testing.expectEqual(PrimitiveType.String, td.primitive);
}

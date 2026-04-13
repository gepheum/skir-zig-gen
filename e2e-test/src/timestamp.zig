const std = @import("std");
const ser = @import("serializer.zig");

const Serializer = ser.Serializer;
const TypeDescriptor = ser.TypeDescriptor;
const PrimitiveType = ser.PrimitiveType;
const decodeNumber = ser.decodeNumber;

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
// Factory function
// =============================================================================

pub fn timestampSerializer() Serializer(Timestamp) {
    return Serializer(Timestamp).fromAdapter(TimestampAdapter);
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

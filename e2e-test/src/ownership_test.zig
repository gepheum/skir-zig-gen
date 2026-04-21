const std = @import("std");
const ownership = @import("skirout/ownership.zig");
const skir_client = @import("skir_client.zig");

fn expectBarsPattern(foo: ownership.Foo) !void {
    try std.testing.expectEqual(@as(usize, 3), foo.bars.len);

    try std.testing.expectEqual(@as(usize, 2), foo.bars[0].len);
    try std.testing.expect(foo.bars[0][0] == null);
    try std.testing.expect(foo.bars[0][1] != null);

    try std.testing.expectEqual(@as(usize, 1), foo.bars[1].len);
    try std.testing.expect(foo.bars[1][0] != null);

    try std.testing.expectEqual(@as(usize, 0), foo.bars[2].len);
}

fn freeFoo(allocator: std.mem.Allocator, foo: ownership.Foo) void {
    for (foo.bars) |row| allocator.free(row);
    allocator.free(foo.bars);
}

test "ownership: Foo dense roundtrip with [][]?Bar" {
    const allocator = std.testing.allocator;

    const bar = ownership.Bar.default;
    const row0 = [_]?ownership.Bar{ null, bar };
    const row1 = [_]?ownership.Bar{bar};
    const row2 = [_]?ownership.Bar{};
    const bars = [_][]const ?ownership.Bar{ row0[0..], row1[0..], row2[0..] };
    const input = ownership.Foo{ .bars = bars[0..], ._unrecognized = null };

    const serializer = ownership.Foo.serializer();
    const encoded = try serializer.serialize(allocator, input, .{ .format = .denseJson });
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("[[[null,[]],[[]],[]]]", encoded);

    const decoded = try serializer.deserialize(allocator, encoded, .{});
    defer freeFoo(allocator, decoded);

    try expectBarsPattern(decoded);
}

test "ownership: Foo binary roundtrip with [][]?Bar" {
    const allocator = std.testing.allocator;

    const bar = ownership.Bar.default;
    const row0 = [_]?ownership.Bar{ null, bar };
    const row1 = [_]?ownership.Bar{bar};
    const row2 = [_]?ownership.Bar{};
    const bars = [_][]const ?ownership.Bar{ row0[0..], row1[0..], row2[0..] };
    const input = ownership.Foo{ .bars = bars[0..], ._unrecognized = null };

    const serializer = ownership.Foo.serializer();
    const encoded = try serializer.serialize(allocator, input, .{ .format = .binary });
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.eql(u8, encoded[0..4], "skir"));

    const decoded = try serializer.deserialize(allocator, encoded, .{});
    defer freeFoo(allocator, decoded);

    try expectBarsPattern(decoded);
}

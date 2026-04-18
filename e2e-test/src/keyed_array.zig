const std = @import("std");

pub fn KeyedArray(comptime Spec: type) type {
    const T = Spec.Value;
    const K = Spec.Key;

    return struct {
        const Self = @This();

        pub const Value = T;
        pub const Key = K;

        // Exposed directly for callers that need full slice-level access.
        values: []T,
        allocator: std.mem.Allocator,

        key_index: ?std.AutoHashMap(K, *T) = null,
        mutex: std.Thread.Mutex = .{},

        pub fn init(allocator: std.mem.Allocator, values: []T) Self {
            return .{
                .values = values,
                .allocator = allocator,
            };
        }

        pub fn empty() Self {
            return .{
                .values = @constCast(&[_]T{}),
                .allocator = std.heap.page_allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.key_index) |*map| {
                map.deinit();
                self.key_index = null;
            }
        }

        fn ensureIndexed(self: *Self) !void {
            if (self.key_index != null) return;

            var map = std.AutoHashMap(K, *T).init(self.allocator);
            errdefer map.deinit();

            for (self.values) |*value| {
                try map.put(Spec.getGet(value.*), value);
            }

            self.key_index = map;
        }

        pub fn findByKey(self: *Self, key: K) !?*T {
            self.mutex.lock();
            defer self.mutex.unlock();

            try self.ensureIndexed();
            return self.key_index.?.get(key);
        }

        pub fn findByKeyOrDefault(self: *Self, key: K) !*T {
            if (try self.findByKey(key)) |value| return value;
            return Spec.defaultValue();
        }
    };
}

test "KeyedArray indexes lazily and returns defaults" {
    const Entry = struct {
        id: i32,
        value: i32,
    };

    const EntrySpec = struct {
        pub const Value = Entry;
        pub const Key = i32;

        pub fn getGet(entry: Entry) i32 {
            return entry.id;
        }

        var fallback: Entry = .{ .id = -1, .value = 0 };

        pub fn defaultValue() *Entry {
            return &fallback;
        }
    };

    var values = [_]Entry{
        .{ .id = 1, .value = 10 },
        .{ .id = 2, .value = 20 },
    };

    var keyed = KeyedArray(EntrySpec).init(std.testing.allocator, values[0..]);
    defer keyed.deinit();

    const found = (try keyed.findByKey(2)).?;
    try std.testing.expectEqual(@as(i32, 20), found.value);

    const missing = try keyed.findByKey(99);
    try std.testing.expect(missing == null);

    const fallback = try keyed.findByKeyOrDefault(42);
    try std.testing.expectEqual(@as(i32, -1), fallback.id);
    try std.testing.expectEqual(@as(i32, 0), fallback.value);
}

test "KeyedArray empty creates an empty container" {
    const Entry = struct {
        id: i32,
    };

    const EntrySpec = struct {
        pub const Value = Entry;
        pub const Key = i32;

        pub fn getGet(entry: Entry) i32 {
            return entry.id;
        }

        var fallback: Entry = .{ .id = -1 };

        pub fn defaultValue() *Entry {
            return &fallback;
        }
    };

    const keyed = KeyedArray(EntrySpec).empty();
    try std.testing.expectEqual(@as(usize, 0), keyed.values.len);
}

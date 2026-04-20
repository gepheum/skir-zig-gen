const std = @import("std");
const s = @import("serializer.zig");
const decode_utils = @import("decode_utils.zig");
const unrecognized = @import("unrecognized.zig");
const skipValue = decode_utils.skipValue;
const writeJsonEscapedString = decode_utils.writeJsonEscapedString;
const readU8 = decode_utils.readU8;
const readU16Le = decode_utils.readU16Le;
const readU32Le = decode_utils.readU32Le;
const readU64Le = decode_utils.readU64Le;
const decodeNumberBody = decode_utils.decodeNumberBody;
const decodeNumber = decode_utils.decodeNumber;
const encodeUint32 = decode_utils.encodeUint32;

/// Type-erased struct adapter modeled after skir-rust-client StructAdapter.
///
/// Note: the current Zig Serializer in serializer.zig stores only function
/// pointers and no runtime context pointer, so this adapter is standalone and
/// is meant to be called directly by generated code (or by a future serializer
/// runtime that can carry adapter instance state).
pub fn StructAdapter(comptime T: type) type {
    return struct {
        const Self = @This();

        const FieldEntry = struct {
            name: []const u8,
            number: i32,
            doc: []const u8,
            ctx: *anyopaque,
            free_ctx_fn: *const fn (std.mem.Allocator, *anyopaque) void,
            is_default_fn: *const fn (*const anyopaque, *const T) bool,
            to_json_fn: *const fn (*const anyopaque, std.mem.Allocator, *const T, ?[]const u8, *std.ArrayList(u8)) anyerror!void,
            set_from_json_fn: *const fn (*const anyopaque, std.mem.Allocator, *T, std.json.Value, bool) anyerror!void,
            encode_fn: *const fn (*const anyopaque, std.mem.Allocator, *const T, *std.ArrayList(u8)) anyerror!void,
            decode_into_fn: *const fn (*const anyopaque, std.mem.Allocator, *T, *[]const u8, bool) anyerror!void,
            field_type_fn: *const fn (*const anyopaque) s.TypeDescriptor,
        };

        allocator: std.mem.Allocator,
        module_path: []const u8,
        qualified_name: []const u8,
        doc: []const u8,
        get_unrecognized: *const fn (*const T) ?unrecognized.UnrecognizedFields,
        set_unrecognized: *const fn (*T, ?unrecognized.UnrecognizedFields) void,

        ordered_entries: std.ArrayList(FieldEntry),
        name_to_index: std.StringHashMap(usize),
        slot_to_index: std.ArrayList(?usize),
        removed_numbers: std.ArrayList(i32),
        max_number: i32,

        pub fn init(
            allocator: std.mem.Allocator,
            module_path: []const u8,
            qualified_name: []const u8,
            doc: []const u8,
            get_unrecognized: *const fn (*const T) ?unrecognized.UnrecognizedFields,
            set_unrecognized: *const fn (*T, ?unrecognized.UnrecognizedFields) void,
        ) !Self {
            return .{
                .allocator = allocator,
                .module_path = try allocator.dupe(u8, module_path),
                .qualified_name = try allocator.dupe(u8, qualified_name),
                .doc = try allocator.dupe(u8, doc),
                .get_unrecognized = get_unrecognized,
                .set_unrecognized = set_unrecognized,
                .ordered_entries = .empty,
                .name_to_index = std.StringHashMap(usize).init(allocator),
                .slot_to_index = .empty,
                .removed_numbers = .empty,
                .max_number = -1,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.ordered_entries.items) |entry| {
                entry.free_ctx_fn(self.allocator, entry.ctx);
                self.allocator.free(entry.name);
                self.allocator.free(entry.doc);
            }
            self.ordered_entries.deinit(self.allocator);

            var it = self.name_to_index.iterator();
            while (it.next()) |kv| {
                self.allocator.free(kv.key_ptr.*);
            }
            self.name_to_index.deinit();

            self.slot_to_index.deinit(self.allocator);
            self.removed_numbers.deinit(self.allocator);

            self.allocator.free(self.module_path);
            self.allocator.free(self.qualified_name);
            self.allocator.free(self.doc);
        }

        pub fn addField(
            self: *Self,
            comptime V: type,
            name: []const u8,
            number: i32,
            ser: s.Serializer(V),
            doc: []const u8,
            getter: *const fn (*const T) V,
            setter: *const fn (*T, V) void,
        ) !void {
            const Ctx = struct {
                ser: s.Serializer(V),
                getter: *const fn (*const T) V,
                setter: *const fn (*T, V) void,
            };
            const Ops = struct {
                fn freeCtx(alloc: std.mem.Allocator, ctx_ptr: *anyopaque) void {
                    const p: *Ctx = @ptrCast(@alignCast(ctx_ptr));
                    alloc.destroy(p);
                }

                fn isDefault(ctx_ptr: *const anyopaque, value: *const T) bool {
                    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    return ctx.ser.isDefault(ctx.getter(value));
                }

                fn toJson(ctx_ptr: *const anyopaque, alloc: std.mem.Allocator, value: *const T, eol_indent: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
                    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    return ctx.ser._vtable.toJsonFn(alloc, ctx.getter(value), eol_indent, out);
                }

                fn setFromJson(ctx_ptr: *const anyopaque, alloc: std.mem.Allocator, value: *T, json: std.json.Value, keep_unrecognized: bool) anyerror!void {
                    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    const v = try ctx.ser._vtable.fromJsonFn(alloc, json, keep_unrecognized);
                    ctx.setter(value, v);
                }

                fn encode(ctx_ptr: *const anyopaque, alloc: std.mem.Allocator, value: *const T, out: *std.ArrayList(u8)) anyerror!void {
                    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    return ctx.ser._vtable.encodeFn(alloc, ctx.getter(value), out);
                }

                fn decodeInto(ctx_ptr: *const anyopaque, alloc: std.mem.Allocator, value: *T, input: *[]const u8, keep_unrecognized: bool) anyerror!void {
                    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    const v = try ctx.ser._vtable.decodeFn(alloc, input, keep_unrecognized);
                    ctx.setter(value, v);
                }

                fn fieldType(ctx_ptr: *const anyopaque) s.TypeDescriptor {
                    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    return ctx.ser._vtable.typeDescriptorFn();
                }
            };

            const ctx = try self.allocator.create(Ctx);
            ctx.* = .{
                .ser = ser,
                .getter = getter,
                .setter = setter,
            };

            const entry: FieldEntry = .{
                .name = try self.allocator.dupe(u8, name),
                .number = number,
                .doc = try self.allocator.dupe(u8, doc),
                .ctx = ctx,
                .free_ctx_fn = Ops.freeCtx,
                .is_default_fn = Ops.isDefault,
                .to_json_fn = Ops.toJson,
                .set_from_json_fn = Ops.setFromJson,
                .encode_fn = Ops.encode,
                .decode_into_fn = Ops.decodeInto,
                .field_type_fn = Ops.fieldType,
            };

            const idx = self.ordered_entries.items.len;
            try self.ordered_entries.append(self.allocator, entry);

            const map_key = try self.allocator.dupe(u8, name);
            try self.name_to_index.put(map_key, idx);

            if (number > self.max_number) self.max_number = number;
        }

        pub fn addRemovedNumber(self: *Self, number: i32) !void {
            try self.removed_numbers.append(self.allocator, number);
            if (number > self.max_number) self.max_number = number;
        }

        pub fn finalize(self: *Self) !void {
            std.sort.pdq(FieldEntry, self.ordered_entries.items, {}, struct {
                fn lessThan(_: void, a: FieldEntry, b: FieldEntry) bool {
                    return a.number < b.number;
                }
            }.lessThan);

            self.name_to_index.clearRetainingCapacity();
            for (self.ordered_entries.items, 0..) |entry, idx| {
                const k = try self.allocator.dupe(u8, entry.name);
                try self.name_to_index.put(k, idx);
            }

            self.slot_to_index.clearRetainingCapacity();
            if (self.max_number >= 0) {
                try self.slot_to_index.resize(self.allocator, @intCast(self.max_number + 1));
                for (self.slot_to_index.items) |*slot| slot.* = null;
                for (self.ordered_entries.items, 0..) |entry, idx| {
                    self.slot_to_index.items[@intCast(entry.number)] = idx;
                }
            }
        }

        pub fn descriptor(self: *const Self) !s.StructDescriptor {
            const short_name = shortName(self.qualified_name);

            const fields = try self.allocator.alloc(s.StructField, self.ordered_entries.items.len);
            for (self.ordered_entries.items, 0..) |entry, idx| {
                fields[idx] = .{
                    .name = entry.name,
                    .number = entry.number,
                    .field_type = null,
                    .doc = entry.doc,
                };
            }

            const removed = try self.allocator.dupe(i32, self.removed_numbers.items);

            return .{
                .name = short_name,
                .qualified_name = self.qualified_name,
                .module_path = self.module_path,
                .doc = self.doc,
                .fields = fields,
                .removed_numbers = removed,
            };
        }

        pub fn isDefault(self: *const Self, input: *const T) bool {
            if (self.get_unrecognized(input) != null) return false;
            for (self.ordered_entries.items) |entry| {
                if (!entry.is_default_fn(entry.ctx, input)) return false;
            }
            return true;
        }

        pub fn toJson(self: *const Self, allocator: std.mem.Allocator, input: *const T, eol_indent: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
            if (eol_indent) |indent| {
                return self.toReadableJson(allocator, input, indent, out);
            }
            return self.toDenseJson(allocator, input, out);
        }

        fn toDenseJson(self: *const Self, allocator: std.mem.Allocator, input: *const T, out: *std.ArrayList(u8)) anyerror!void {
            try out.append(allocator, '[');
            const slot_count = self.getSlotCount(input);
            for (0..slot_count) |slot| {
                if (slot > 0) try out.append(allocator, ',');
                if (slot < self.slot_to_index.items.len and self.slot_to_index.items[slot]) |idx| {
                    const e = self.ordered_entries.items[idx];
                    try e.to_json_fn(e.ctx, allocator, input, null, out);
                } else {
                    try out.append(allocator, '0');
                }
            }
            try out.append(allocator, ']');
        }

        fn toReadableJson(self: *const Self, allocator: std.mem.Allocator, input: *const T, eol_indent: []const u8, out: *std.ArrayList(u8)) anyerror!void {
            try out.append(allocator, '{');

            var child_buf: [256]u8 = undefined;
            const child_len = @min(eol_indent.len + 2, child_buf.len);
            @memcpy(child_buf[0..eol_indent.len], eol_indent);
            child_buf[eol_indent.len] = ' ';
            if (eol_indent.len + 1 < child_buf.len) child_buf[eol_indent.len + 1] = ' ';
            const child_eol = child_buf[0..child_len];

            var first = true;
            for (self.ordered_entries.items) |entry| {
                if (entry.is_default_fn(entry.ctx, input)) continue;
                if (!first) try out.append(allocator, ',');
                first = false;
                try out.appendSlice(allocator, child_eol);
                try writeJsonEscapedString(entry.name, allocator, out);
                try out.appendSlice(allocator, ": ");
                try entry.to_json_fn(entry.ctx, allocator, input, child_eol, out);
            }

            if (!first) try out.appendSlice(allocator, eol_indent);
            try out.append(allocator, '}');
        }

        fn getSlotCount(self: *const Self, input: *const T) usize {
            var i = self.ordered_entries.items.len;
            while (i > 0) {
                i -= 1;
                const e = self.ordered_entries.items[i];
                if (!e.is_default_fn(e.ctx, input)) {
                    return @intCast(e.number + 1);
                }
            }
            return 0;
        }

        pub fn fromJson(self: *const Self, allocator: std.mem.Allocator, json: std.json.Value, keep_unrecognized: bool) anyerror!T {
            return switch (json) {
                .integer, .float => T.default,
                .array => |arr| self.fromDenseJson(allocator, arr.items, keep_unrecognized),
                .object => |obj| self.fromReadableJson(allocator, obj, keep_unrecognized),
                else => T.default,
            };
        }

        fn fromDenseJson(self: *const Self, allocator: std.mem.Allocator, items: []const std.json.Value, keep_unrecognized: bool) anyerror!T {
            var t = T.default;
            const recognized_count = self.slot_to_index.items.len;
            var n = items.len;

            if (n > recognized_count) {
                if (keep_unrecognized) {
                    self.set_unrecognized(&t, .{});
                }
                n = recognized_count;
            }

            for (self.ordered_entries.items) |entry| {
                const slot: usize = @intCast(entry.number);
                if (slot >= n) break;
                try entry.set_from_json_fn(entry.ctx, allocator, &t, items[slot], keep_unrecognized);
            }

            return t;
        }

        fn fromReadableJson(self: *const Self, allocator: std.mem.Allocator, obj: std.json.ObjectMap, keep_unrecognized: bool) anyerror!T {
            var t = T.default;
            var it = obj.iterator();
            while (it.next()) |kv| {
                const key = kv.key_ptr.*;
                const value = kv.value_ptr.*;
                if (self.name_to_index.get(key)) |idx| {
                    const e = self.ordered_entries.items[idx];
                    try e.set_from_json_fn(e.ctx, allocator, &t, value, keep_unrecognized);
                }
            }
            return t;
        }

        pub fn encode(self: *const Self, allocator: std.mem.Allocator, input: *const T, out: *std.ArrayList(u8)) anyerror!void {
            const slot_count = self.getSlotCount(input);
            if (slot_count <= 3) {
                try out.append(allocator, @intCast(246 + slot_count));
            } else {
                try out.append(allocator, 250);
                try encodeUint32(@intCast(slot_count), allocator, out);
            }

            for (0..slot_count) |slot| {
                if (slot < self.slot_to_index.items.len and self.slot_to_index.items[slot]) |idx| {
                    const e = self.ordered_entries.items[idx];
                    try e.encode_fn(e.ctx, allocator, input, out);
                } else {
                    try out.append(allocator, 0);
                }
            }
        }

        pub fn decode(self: *const Self, allocator: std.mem.Allocator, input: *[]const u8, keep_unrecognized: bool) anyerror!T {
            const wire = try readU8(input);
            if (wire == 0 or wire == 246) return T.default;

            const encoded_slot_count: usize = if (wire == 250)
                @intCast(try decodeNumber(input))
            else if (wire >= 247 and wire <= 249)
                @intCast(wire - 246)
            else
                return T.default;

            var t = T.default;
            const recognized_count = self.slot_to_index.items.len;
            const slots_to_fill = @min(encoded_slot_count, recognized_count);

            var i: usize = 0;
            while (i < slots_to_fill) : (i += 1) {
                if (self.slot_to_index.items[i]) |idx| {
                    const e = self.ordered_entries.items[idx];
                    try e.decode_into_fn(e.ctx, allocator, &t, input, keep_unrecognized);
                } else {
                    try skipValue(input);
                }
            }

            if (encoded_slot_count > recognized_count) {
                if (keep_unrecognized) {
                    self.set_unrecognized(&t, .{});
                }
                var j: usize = recognized_count;
                while (j < encoded_slot_count) : (j += 1) {
                    try skipValue(input);
                }
            }

            return t;
        }

        pub fn typeDescriptor(self: *const Self) anyerror!s.TypeDescriptor {
            return .{ .struct_record = try self.descriptor() };
        }

        fn shortName(qualified_name: []const u8) []const u8 {
            if (std.mem.lastIndexOfScalar(u8, qualified_name, '.')) |idx| {
                return qualified_name[idx + 1 ..];
            }
            return qualified_name;
        }
    };
}

pub fn structSerializerFromStatic(comptime T: type, comptime get_adapter: *const fn () *StructAdapter(T)) s.Serializer(T) {
    const Impl = struct {
        pub fn isDefault(_: @This(), input: T) bool {
            return get_adapter().isDefault(&input);
        }

        pub fn toJson(_: @This(), allocator: std.mem.Allocator, input: T, eol_indent: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
            return get_adapter().toJson(allocator, &input, eol_indent, out);
        }

        pub fn fromJson(_: @This(), allocator: std.mem.Allocator, json: std.json.Value, keep_unrecognized: bool) anyerror!T {
            return get_adapter().fromJson(allocator, json, keep_unrecognized);
        }

        pub fn encode(_: @This(), allocator: std.mem.Allocator, input: T, out: *std.ArrayList(u8)) anyerror!void {
            return get_adapter().encode(allocator, &input, out);
        }

        pub fn decode(_: @This(), allocator: std.mem.Allocator, input: *[]const u8, keep_unrecognized: bool) anyerror!T {
            return get_adapter().decode(allocator, input, keep_unrecognized);
        }

        pub fn typeDescriptor(_: @This()) s.TypeDescriptor {
            return get_adapter().typeDescriptor() catch unreachable;
        }
    };

    return s.Serializer(T).fromAdapter(Impl);
}

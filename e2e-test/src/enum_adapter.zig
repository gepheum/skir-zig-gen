const std = @import("std");
const s = @import("serializer.zig");
const unrecognized = @import("unrecognized.zig");
const struct_adapter = @import("struct_adapter.zig");

/// Type-erased enum adapter modeled after skir-rust-client EnumAdapter.
///
/// Note: like StructAdapter, this is currently standalone because Serializer
/// in serializer.zig cannot hold a runtime adapter context pointer.
pub fn EnumAdapter(comptime T: type) type {
    return struct {
        const Self = @This();

        const AnyEntry = union(enum) {
            removed,
            constant: usize,
            wrapper: usize,
        };

        const VariantEntry = struct {
            name: []const u8,
            number: i32,
            kind_ordinal: usize,
            doc: []const u8,
            ctx: *anyopaque,
            free_ctx_fn: *const fn (std.mem.Allocator, *anyopaque) void,
            is_constant_fn: *const fn (*const anyopaque) bool,
            constant_fn: *const fn (*const anyopaque) T,
            to_json_fn: *const fn (*const anyopaque, std.mem.Allocator, *const T, ?[]const u8, *std.ArrayList(u8)) anyerror!void,
            wrap_from_json_fn: *const fn (*const anyopaque, std.mem.Allocator, std.json.Value, bool) anyerror!T,
            encode_value_fn: *const fn (*const anyopaque, std.mem.Allocator, *const T, *std.ArrayList(u8)) anyerror!void,
            wrap_decode_fn: *const fn (*const anyopaque, std.mem.Allocator, *[]const u8, bool) anyerror!T,
            wrap_default_fn: *const fn (*const anyopaque) ?T,
            variant_type_fn: *const fn (*const anyopaque) ?s.TypeDescriptor,
        };

        allocator: std.mem.Allocator,
        module_path: []const u8,
        qualified_name: []const u8,
        doc: []const u8,

        get_kind_ordinal: *const fn (*const T) usize,
        wrap_unrecognized: *const fn (unrecognized.UnrecognizedVariant) T,
        get_unrecognized: *const fn (*const T) ?unrecognized.UnrecognizedVariant,

        number_to_entry: std.AutoHashMap(i32, AnyEntry),
        removed_numbers: std.ArrayList(i32),
        name_to_kind_ordinal: std.StringHashMap(usize),
        kind_ordinal_to_entry: std.ArrayList(?VariantEntry),
        desc_variants: std.ArrayList(s.EnumVariant),

        pub fn init(
            allocator: std.mem.Allocator,
            module_path: []const u8,
            qualified_name: []const u8,
            doc: []const u8,
            get_kind_ordinal: *const fn (*const T) usize,
            wrap_unrecognized: *const fn (unrecognized.UnrecognizedVariant) T,
            get_unrecognized: *const fn (*const T) ?unrecognized.UnrecognizedVariant,
        ) !Self {
            var kind_entries: std.ArrayList(?VariantEntry) = .empty;
            try kind_entries.append(allocator, null); // kind ordinal 0 = UNKNOWN pseudo-entry

            return .{
                .allocator = allocator,
                .module_path = try allocator.dupe(u8, module_path),
                .qualified_name = try allocator.dupe(u8, qualified_name),
                .doc = try allocator.dupe(u8, doc),
                .get_kind_ordinal = get_kind_ordinal,
                .wrap_unrecognized = wrap_unrecognized,
                .get_unrecognized = get_unrecognized,
                .number_to_entry = std.AutoHashMap(i32, AnyEntry).init(allocator),
                .removed_numbers = .empty,
                .name_to_kind_ordinal = std.StringHashMap(usize).init(allocator),
                .kind_ordinal_to_entry = kind_entries,
                .desc_variants = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.number_to_entry.deinit();
            self.removed_numbers.deinit(self.allocator);

            var name_it = self.name_to_kind_ordinal.iterator();
            while (name_it.next()) |kv| {
                self.allocator.free(kv.key_ptr.*);
            }
            self.name_to_kind_ordinal.deinit();

            for (self.kind_ordinal_to_entry.items) |entry_opt| {
                if (entry_opt) |entry| {
                    entry.free_ctx_fn(self.allocator, entry.ctx);
                    self.allocator.free(entry.name);
                    self.allocator.free(entry.doc);
                }
            }
            self.kind_ordinal_to_entry.deinit(self.allocator);

            for (self.desc_variants.items) |variant| {
                switch (variant) {
                    .constant => |v| {
                        self.allocator.free(v.name);
                        self.allocator.free(v.doc);
                    },
                    .wrapper => |v| {
                        self.allocator.free(v.name);
                        self.allocator.free(v.doc);
                    },
                }
            }
            self.desc_variants.deinit(self.allocator);

            self.allocator.free(self.module_path);
            self.allocator.free(self.qualified_name);
            self.allocator.free(self.doc);
        }

        pub fn addRemovedNumber(self: *Self, number: i32) !void {
            try self.number_to_entry.put(number, .removed);
            try self.removed_numbers.append(self.allocator, number);
        }

        pub fn addConstantVariant(
            self: *Self,
            name: []const u8,
            number: i32,
            kind_ordinal: usize,
            doc: []const u8,
            instance: T,
        ) !void {
            const Ctx = struct {
                instance: T,
            };
            const Ops = struct {
                fn freeCtx(alloc: std.mem.Allocator, ctx_ptr: *anyopaque) void {
                    const p: *Ctx = @ptrCast(@alignCast(ctx_ptr));
                    alloc.destroy(p);
                }

                fn isConstant(_: *const anyopaque) bool {
                    return true;
                }

                fn constant(ctx_ptr: *const anyopaque) T {
                    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    return ctx.instance;
                }

                fn toJson(ctx_ptr: *const anyopaque, allocator: std.mem.Allocator, _: *const T, eol_indent: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
                    const _ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    _ = _ctx;
                    if (eol_indent != null) {
                        try writeJsonEscapedString(name, allocator, out);
                    } else {
                        var buf: [32]u8 = undefined;
                        const n_str = std.fmt.bufPrint(&buf, "{d}", .{number}) catch unreachable;
                        try out.appendSlice(allocator, n_str);
                    }
                }

                fn wrapFromJson(_: *const anyopaque, _: std.mem.Allocator, _: std.json.Value, _: bool) anyerror!T {
                    return error.ExpectedConstantVariant;
                }

                fn encodeValue(_: *const anyopaque, allocator: std.mem.Allocator, _: *const T, out: *std.ArrayList(u8)) anyerror!void {
                    try encodeUint32(@intCast(number), allocator, out);
                }

                fn wrapDecode(_: *const anyopaque, _: std.mem.Allocator, _: *[]const u8, _: bool) anyerror!T {
                    return error.ExpectedConstantVariant;
                }

                fn wrapDefault(ctx_ptr: *const anyopaque) ?T {
                    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    return ctx.instance;
                }

                fn variantType(_: *const anyopaque) ?s.TypeDescriptor {
                    return null;
                }
            };

            const ctx = try self.allocator.create(Ctx);
            ctx.* = .{ .instance = instance };

            const entry = VariantEntry{
                .name = try self.allocator.dupe(u8, name),
                .number = number,
                .kind_ordinal = kind_ordinal,
                .doc = try self.allocator.dupe(u8, doc),
                .ctx = ctx,
                .free_ctx_fn = Ops.freeCtx,
                .is_constant_fn = Ops.isConstant,
                .constant_fn = Ops.constant,
                .to_json_fn = Ops.toJson,
                .wrap_from_json_fn = Ops.wrapFromJson,
                .encode_value_fn = Ops.encodeValue,
                .wrap_decode_fn = Ops.wrapDecode,
                .wrap_default_fn = Ops.wrapDefault,
                .variant_type_fn = Ops.variantType,
            };

            try self.installVariantEntry(entry);
            try self.number_to_entry.put(number, .{ .constant = kind_ordinal });
            try self.insertNameAlias(name, kind_ordinal);

            try self.desc_variants.append(self.allocator, .{ .constant = .{
                .name = try self.allocator.dupe(u8, name),
                .number = number,
                .doc = try self.allocator.dupe(u8, doc),
            } });
        }

        pub fn addWrapperVariant(
            self: *Self,
            comptime V: type,
            name: []const u8,
            number: i32,
            kind_ordinal: usize,
            ser: s.Serializer(V),
            doc: []const u8,
            wrap: *const fn (V) T,
            get_value: *const fn (*const T) V,
        ) !void {
            const Ctx = struct {
                ser: s.Serializer(V),
                wrap: *const fn (V) T,
                get_value: *const fn (*const T) V,
            };
            const Ops = struct {
                fn freeCtx(alloc: std.mem.Allocator, ctx_ptr: *anyopaque) void {
                    const p: *Ctx = @ptrCast(@alignCast(ctx_ptr));
                    alloc.destroy(p);
                }

                fn isConstant(_: *const anyopaque) bool {
                    return false;
                }

                fn constant(_: *const anyopaque) T {
                    return T.default;
                }

                fn toJson(ctx_ptr: *const anyopaque, allocator: std.mem.Allocator, input: *const T, eol_indent: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
                    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    const v = ctx.get_value(input);

                    if (eol_indent) |indent| {
                        var child_buf: [256]u8 = undefined;
                        const child_len = @min(indent.len + 2, child_buf.len);
                        @memcpy(child_buf[0..indent.len], indent);
                        child_buf[indent.len] = ' ';
                        if (indent.len + 1 < child_buf.len) child_buf[indent.len + 1] = ' ';
                        const child = child_buf[0..child_len];

                        try out.append(allocator, '{');
                        try out.appendSlice(allocator, child);
                        try out.appendSlice(allocator, "\"kind\": ");
                        try writeJsonEscapedString(name, allocator, out);
                        try out.append(allocator, ',');
                        try out.appendSlice(allocator, child);
                        try out.appendSlice(allocator, "\"value\": ");
                        try ctx.ser._vtable.toJsonFn(allocator, v, child, out);
                        try out.appendSlice(allocator, indent);
                        try out.append(allocator, '}');
                    } else {
                        try out.append(allocator, '[');
                        var num_buf: [32]u8 = undefined;
                        const n_str = std.fmt.bufPrint(&num_buf, "{d}", .{number}) catch unreachable;
                        try out.appendSlice(allocator, n_str);
                        try out.append(allocator, ',');
                        try ctx.ser._vtable.toJsonFn(allocator, v, null, out);
                        try out.append(allocator, ']');
                    }
                }

                fn wrapFromJson(ctx_ptr: *const anyopaque, allocator: std.mem.Allocator, json: std.json.Value, keep_unrecognized: bool) anyerror!T {
                    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    const inner = try ctx.ser._vtable.fromJsonFn(allocator, json, keep_unrecognized);
                    return ctx.wrap(inner);
                }

                fn encodeValue(ctx_ptr: *const anyopaque, allocator: std.mem.Allocator, input: *const T, out: *std.ArrayList(u8)) anyerror!void {
                    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    return ctx.ser._vtable.encodeFn(allocator, ctx.get_value(input), out);
                }

                fn wrapDecode(ctx_ptr: *const anyopaque, allocator: std.mem.Allocator, input: *[]const u8, keep_unrecognized: bool) anyerror!T {
                    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    const inner = try ctx.ser._vtable.decodeFn(allocator, input, keep_unrecognized);
                    return ctx.wrap(inner);
                }

                fn wrapDefault(_: *const anyopaque) ?T {
                    return null;
                }

                fn variantType(ctx_ptr: *const anyopaque) ?s.TypeDescriptor {
                    const ctx: *const Ctx = @ptrCast(@alignCast(ctx_ptr));
                    return ctx.ser._vtable.typeDescriptorFn();
                }
            };

            const ctx = try self.allocator.create(Ctx);
            ctx.* = .{
                .ser = ser,
                .wrap = wrap,
                .get_value = get_value,
            };

            const entry = VariantEntry{
                .name = try self.allocator.dupe(u8, name),
                .number = number,
                .kind_ordinal = kind_ordinal,
                .doc = try self.allocator.dupe(u8, doc),
                .ctx = ctx,
                .free_ctx_fn = Ops.freeCtx,
                .is_constant_fn = Ops.isConstant,
                .constant_fn = Ops.constant,
                .to_json_fn = Ops.toJson,
                .wrap_from_json_fn = Ops.wrapFromJson,
                .encode_value_fn = Ops.encodeValue,
                .wrap_decode_fn = Ops.wrapDecode,
                .wrap_default_fn = Ops.wrapDefault,
                .variant_type_fn = Ops.variantType,
            };

            try self.installVariantEntry(entry);
            try self.number_to_entry.put(number, .{ .wrapper = kind_ordinal });
            try self.insertNameAlias(name, kind_ordinal);

            try self.desc_variants.append(self.allocator, .{ .wrapper = .{
                .name = try self.allocator.dupe(u8, name),
                .number = number,
                .variant_type = null,
                .doc = try self.allocator.dupe(u8, doc),
            } });
        }

        fn installVariantEntry(self: *Self, entry: VariantEntry) !void {
            if (entry.kind_ordinal >= self.kind_ordinal_to_entry.items.len) {
                const new_len = entry.kind_ordinal + 1;
                const old_len = self.kind_ordinal_to_entry.items.len;
                try self.kind_ordinal_to_entry.resize(self.allocator, new_len);
                for (old_len..new_len) |idx| self.kind_ordinal_to_entry.items[idx] = null;
            }
            self.kind_ordinal_to_entry.items[entry.kind_ordinal] = entry;
        }

        fn insertNameAlias(self: *Self, name: []const u8, kind_ordinal: usize) !void {
            const key = try self.allocator.dupe(u8, name);
            try self.name_to_kind_ordinal.put(key, kind_ordinal);

            const upper = try std.ascii.allocUpperString(self.allocator, name);
            if (!std.mem.eql(u8, upper, name)) {
                try self.name_to_kind_ordinal.put(upper, kind_ordinal);
            } else {
                self.allocator.free(upper);
            }

            const lower = try std.ascii.allocLowerString(self.allocator, name);
            if (!std.mem.eql(u8, lower, name)) {
                try self.name_to_kind_ordinal.put(lower, kind_ordinal);
            } else {
                self.allocator.free(lower);
            }
        }

        pub fn finalize(self: *Self) !void {
            std.sort.pdq(s.EnumVariant, self.desc_variants.items, {}, struct {
                fn lessThan(_: void, a: s.EnumVariant, b: s.EnumVariant) bool {
                    return a.number() < b.number();
                }
            }.lessThan);
        }

        pub fn descriptor(self: *const Self) !s.EnumDescriptor {
            const variants = try self.allocator.alloc(s.EnumVariant, self.desc_variants.items.len);
            for (self.desc_variants.items, 0..) |v, idx| {
                variants[idx] = v;
            }
            const removed = try self.allocator.dupe(i32, self.removed_numbers.items);
            return .{
                .name = shortName(self.qualified_name),
                .qualified_name = self.qualified_name,
                .module_path = self.module_path,
                .doc = self.doc,
                .variants = variants,
                .removed_numbers = removed,
            };
        }

        pub fn isDefault(self: *const Self, input: *const T) bool {
            return self.get_kind_ordinal(input) == 0;
        }

        pub fn toJson(self: *const Self, allocator: std.mem.Allocator, input: *const T, eol_indent: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
            const ko = self.get_kind_ordinal(input);
            if (ko == 0) {
                return self.unknownToJson(allocator, input, eol_indent, out);
            }

            if (ko < self.kind_ordinal_to_entry.items.len and self.kind_ordinal_to_entry.items[ko]) |entry| {
                return entry.to_json_fn(entry.ctx, allocator, input, eol_indent, out);
            }

            if (eol_indent != null) {
                try out.appendSlice(allocator, "\"UNKNOWN\"");
            } else {
                try out.append(allocator, '0');
            }
        }

        fn unknownToJson(self: *const Self, allocator: std.mem.Allocator, input: *const T, eol_indent: ?[]const u8, out: *std.ArrayList(u8)) anyerror!void {
            _ = self;
            _ = input;
            if (eol_indent != null) {
                try out.appendSlice(allocator, "\"UNKNOWN\"");
            } else {
                try out.append(allocator, '0');
            }
        }

        pub fn fromJson(self: *const Self, allocator: std.mem.Allocator, json: std.json.Value, keep_unrecognized: bool) anyerror!T {
            return switch (json) {
                .integer => |n| self.resolveConstantLookup(@intCast(n), keep_unrecognized),
                .float => |f| self.resolveConstantLookup(@intFromFloat(@round(f)), keep_unrecognized),
                .bool => |b| self.resolveConstantLookup(if (b) 1 else 0, keep_unrecognized),
                .string => |str| blk: {
                    if (self.name_to_kind_ordinal.get(str)) |ko| {
                        if (ko < self.kind_ordinal_to_entry.items.len and self.kind_ordinal_to_entry.items[ko]) |entry| {
                            if (entry.is_constant_fn(entry.ctx)) {
                                break :blk entry.constant_fn(entry.ctx);
                            }
                            if (entry.wrap_default_fn(entry.ctx)) |v| break :blk v;
                        }
                    }
                    break :blk T.default;
                },
                .array => |arr| blk: {
                    if (arr.items.len != 2) break :blk T.default;
                    const number: i32 = switch (arr.items[0]) {
                        .integer => |n| @intCast(n),
                        .float => |f| @intFromFloat(@round(f)),
                        else => 0,
                    };
                    break :blk try self.fromNumberAndPayload(allocator, number, arr.items[1], keep_unrecognized);
                },
                .object => |obj| blk: {
                    const kind_val = obj.get("kind") orelse break :blk T.default;
                    const payload = obj.get("value") orelse std.json.Value{ .null = {} };
                    const kind_name = switch (kind_val) {
                        .string => |s_name| s_name,
                        else => break :blk T.default,
                    };
                    if (self.name_to_kind_ordinal.get(kind_name)) |ko| {
                        if (ko < self.kind_ordinal_to_entry.items.len and self.kind_ordinal_to_entry.items[ko]) |entry| {
                            if (entry.is_constant_fn(entry.ctx)) {
                                break :blk entry.constant_fn(entry.ctx);
                            }
                            break :blk try entry.wrap_from_json_fn(entry.ctx, allocator, payload, keep_unrecognized);
                        }
                    }
                    break :blk T.default;
                },
                else => T.default,
            };
        }

        fn fromNumberAndPayload(self: *const Self, allocator: std.mem.Allocator, number: i32, payload: std.json.Value, keep_unrecognized: bool) anyerror!T {
            if (self.number_to_entry.get(number)) |any| {
                return switch (any) {
                    .removed => T.default,
                    .constant => |ko| blk: {
                        if (ko < self.kind_ordinal_to_entry.items.len and self.kind_ordinal_to_entry.items[ko]) |entry| {
                            break :blk entry.constant_fn(entry.ctx);
                        }
                        break :blk T.default;
                    },
                    .wrapper => |ko| blk: {
                        if (ko < self.kind_ordinal_to_entry.items.len and self.kind_ordinal_to_entry.items[ko]) |entry| {
                            break :blk try entry.wrap_from_json_fn(entry.ctx, allocator, payload, keep_unrecognized);
                        }
                        break :blk T.default;
                    },
                };
            }

            if (keep_unrecognized) {
                return self.wrap_unrecognized(.{});
            }
            return T.default;
        }

        fn resolveConstantLookup(self: *const Self, number: i32, keep_unrecognized: bool) T {
            if (self.number_to_entry.get(number)) |any| {
                return switch (any) {
                    .removed => T.default,
                    .constant => |ko| blk: {
                        if (ko < self.kind_ordinal_to_entry.items.len and self.kind_ordinal_to_entry.items[ko]) |entry| {
                            break :blk entry.constant_fn(entry.ctx);
                        }
                        break :blk T.default;
                    },
                    .wrapper => |ko| blk: {
                        if (ko < self.kind_ordinal_to_entry.items.len and self.kind_ordinal_to_entry.items[ko]) |entry| {
                            if (entry.wrap_default_fn(entry.ctx)) |v| break :blk v;
                        }
                        break :blk T.default;
                    },
                };
            }

            if (keep_unrecognized) {
                return self.wrap_unrecognized(.{});
            }
            return T.default;
        }

        pub fn encode(self: *const Self, allocator: std.mem.Allocator, input: *const T, out: *std.ArrayList(u8)) anyerror!void {
            const ko = self.get_kind_ordinal(input);
            if (ko == 0) {
                try out.append(allocator, 0);
                return;
            }

            if (ko < self.kind_ordinal_to_entry.items.len and self.kind_ordinal_to_entry.items[ko]) |entry| {
                if (entry.is_constant_fn(entry.ctx)) {
                    return entry.encode_value_fn(entry.ctx, allocator, input, out);
                }

                const n = entry.number;
                if (n >= 1 and n <= 4) {
                    try out.append(allocator, @intCast(250 + n));
                } else {
                    try out.append(allocator, 248);
                    try encodeUint32(@intCast(n), allocator, out);
                }
                return entry.encode_value_fn(entry.ctx, allocator, input, out);
            }

            try out.append(allocator, 0);
        }

        pub fn decode(self: *const Self, allocator: std.mem.Allocator, input: *[]const u8, keep_unrecognized: bool) anyerror!T {
            const wire = try readU8(input);

            if (wire < 242) {
                const n: i32 = @intCast(try decodeNumberBody(wire, input));
                return self.resolveConstantLookup(n, keep_unrecognized);
            }

            const wrapper_number: i32 = if (wire == 248)
                @intCast(try decodeNumber(input))
            else if (wire >= 251 and wire <= 254)
                @as(i32, wire) - 250
            else
                return T.default;

            if (self.number_to_entry.get(wrapper_number)) |any| {
                return switch (any) {
                    .wrapper => |ko| blk: {
                        if (ko < self.kind_ordinal_to_entry.items.len and self.kind_ordinal_to_entry.items[ko]) |entry| {
                            break :blk try entry.wrap_decode_fn(entry.ctx, allocator, input, keep_unrecognized);
                        }
                        try struct_adapter.skipValue(input);
                        break :blk T.default;
                    },
                    .removed => blk: {
                        try struct_adapter.skipValue(input);
                        break :blk T.default;
                    },
                    .constant => |ko| blk: {
                        try struct_adapter.skipValue(input);
                        if (ko < self.kind_ordinal_to_entry.items.len and self.kind_ordinal_to_entry.items[ko]) |entry| {
                            break :blk entry.constant_fn(entry.ctx);
                        }
                        break :blk T.default;
                    },
                };
            }

            try struct_adapter.skipValue(input);
            if (keep_unrecognized) {
                return self.wrap_unrecognized(.{});
            }
            return T.default;
        }

        pub fn typeDescriptor(self: *const Self) anyerror!s.TypeDescriptor {
            return .{ .enum_record = try self.descriptor() };
        }

        fn shortName(qualified_name: []const u8) []const u8 {
            if (std.mem.lastIndexOfScalar(u8, qualified_name, '.')) |idx| {
                return qualified_name[idx + 1 ..];
            }
            return qualified_name;
        }
    };
}

pub fn enumSerializerFromStatic(comptime T: type, _: *const EnumAdapter(T)) s.Serializer(T) {
    @compileError("enumSerializerFromStatic cannot be implemented with current Serializer VTable because it has no adapter context pointer");
}

fn writeJsonEscapedString(s_input: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) anyerror!void {
    try out.append(allocator, '"');
    for (s_input) |c| {
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

fn readU8(input: *[]const u8) error{UnexpectedEndOfInput}!u8 {
    if (input.*.len == 0) return error.UnexpectedEndOfInput;
    const b = input.*[0];
    input.* = input.*[1..];
    return b;
}

fn readU16Le(input: *[]const u8) error{UnexpectedEndOfInput}!u16 {
    if (input.*.len < 2) return error.UnexpectedEndOfInput;
    const v = std.mem.readInt(u16, input.*[0..2], .little);
    input.* = input.*[2..];
    return v;
}

fn readU32Le(input: *[]const u8) error{UnexpectedEndOfInput}!u32 {
    if (input.*.len < 4) return error.UnexpectedEndOfInput;
    const v = std.mem.readInt(u32, input.*[0..4], .little);
    input.* = input.*[4..];
    return v;
}

fn readU64Le(input: *[]const u8) error{UnexpectedEndOfInput}!u64 {
    if (input.*.len < 8) return error.UnexpectedEndOfInput;
    const v = std.mem.readInt(u64, input.*[0..8], .little);
    input.* = input.*[8..];
    return v;
}

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

fn decodeNumber(input: *[]const u8) error{UnexpectedEndOfInput}!i64 {
    const wire = try readU8(input);
    return decodeNumberBody(wire, input);
}

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

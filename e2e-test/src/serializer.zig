const std = @import("std");
const type_descriptor = @import("type_descriptor.zig");

const TypeDescriptor = type_descriptor.TypeDescriptor;
const TypeDescriptorMap = type_descriptor.TypeDescriptorMap;

// =============================================================================
// SerializeFormat
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

/// Internal generic vtable type used by `Serializer(T)`.
pub fn _SerializerVTable(comptime T: type) type {
    return struct {
        isDefaultFn: *const fn (T) bool,
        toJsonFn: *const fn (std.mem.Allocator, T, ?[]const u8, *std.ArrayList(u8)) anyerror!void,
        fromJsonFn: *const fn (std.mem.Allocator, std.json.Value, bool) anyerror!T,
        encodeFn: *const fn (std.mem.Allocator, T, *std.ArrayList(u8)) anyerror!void,
        decodeFn: *const fn (std.mem.Allocator, *[]const u8, bool) anyerror!T,
        typeDescriptorFn: *const fn (std.mem.Allocator, *TypeDescriptorMap) anyerror!*TypeDescriptor,
    };
}

// =============================================================================
// Serializer
// =============================================================================

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
        pub const Value = T;

        const VTable = _SerializerVTable(T);

        fn vtableFor(comptime Impl: type) *const VTable {
            return &struct {
                fn doIsDefault(value: T) bool {
                    const impl: Impl = .{};
                    return impl.isDefault(value);
                }

                fn doTypeDescriptor(allocator: std.mem.Allocator, descriptors: *TypeDescriptorMap) anyerror!*TypeDescriptor {
                    const impl: Impl = .{};
                    return impl.typeDescriptor(allocator, descriptors);
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
                    .isDefaultFn = doIsDefault,
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
            pub fn isDefault(_: @This(), _: T) bool {
                return false;
            }
            pub fn toJson(_: @This(), _: std.mem.Allocator, _: T, _: ?[]const u8, _: *std.ArrayList(u8)) anyerror!void {}
            pub fn fromJson(_: @This(), _: std.mem.Allocator, _: std.json.Value, _: bool) anyerror!T {
                return error.Stub;
            }
            pub fn encode(_: @This(), _: std.mem.Allocator, _: T, _: *std.ArrayList(u8)) anyerror!void {}
            pub fn decode(_: @This(), _: std.mem.Allocator, _: *[]const u8, _: bool) anyerror!T {
                return error.Stub;
            }
            pub fn typeDescriptor(_: @This(), _: std.mem.Allocator, _: *TypeDescriptorMap) anyerror!*TypeDescriptor {
                const static: TypeDescriptor = .{ .primitive = .Bool };
                return @constCast(&static);
            }
        };

        _vtable: *const VTable = vtableFor(StubImpl),

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
        pub fn typeDescriptor(self: Self, allocator: std.mem.Allocator) !TypeDescriptor {
            var descriptors = TypeDescriptorMap.init(allocator);
            defer descriptors.deinit();
            const ptr = try self._vtable.typeDescriptorFn(allocator, &descriptors);
            return ptr.*;
        }
    };
}

/// Internal helper that constructs a `Serializer(T)` backed by `Impl`.
pub fn _serializerFromAdapter(comptime T: type, comptime Impl: type) Serializer(T) {
    return .{ ._vtable = Serializer(T).vtableFor(Impl) };
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

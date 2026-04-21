const s = @import("serializers.zig");
const core = @import("serializer.zig");
const type_descriptor = @import("type_descriptor.zig");
const timestamp = @import("timestamp.zig");
const unrecognized = @import("unrecognized.zig");
const recursive = @import("recursive.zig");
const struct_adapter = @import("struct_adapter.zig");
const enum_adapter = @import("enum_adapter.zig");

// Core runtime types
pub const KeyedArray = @import("keyed_array.zig").KeyedArray;
pub const Method = core.Method;
pub const Recursive = recursive.Recursive;
pub const SerializeFormat = core.SerializeFormat;
pub const Serializer = core.Serializer;
pub const Timestamp = timestamp.Timestamp;
pub const UnrecognizedFields = unrecognized.UnrecognizedFields;
pub const UnrecognizedVariant = unrecognized.UnrecognizedVariant;

// Serializer factories
pub const arraySerializer = s.arraySerializer;
pub const boolSerializer = s.boolSerializer;
pub const bytesSerializer = s.bytesSerializer;
pub const float32Serializer = s.float32Serializer;
pub const float64Serializer = s.float64Serializer;
pub const hash64Serializer = s.hash64Serializer;
pub const int32Serializer = s.int32Serializer;
pub const int64Serializer = s.int64Serializer;
pub const keyedArraySerializer = s.keyedArraySerializer;
pub const optionalSerializer = s.optionalSerializer;
pub const pointerSerializer = s.pointerSerializer;
pub const recursiveSerializer = s.recursiveSerializer;
pub const stringSerializer = s.stringSerializer;
pub const timestampSerializer = s.timestampSerializer;

// Type descriptors
pub const ArrayDescriptor = type_descriptor.ArrayDescriptor;
pub const EnumConstantVariant = type_descriptor.EnumConstantVariant;
pub const EnumVariant = type_descriptor.EnumVariant;
pub const EnumDescriptor = type_descriptor.EnumDescriptor;
pub const EnumWrapperVariant = type_descriptor.EnumWrapperVariant;
pub const PrimitiveType = type_descriptor.PrimitiveType;
pub const StructDescriptor = type_descriptor.StructDescriptor;
pub const StructField = type_descriptor.StructField;
pub const TypeDescriptor = type_descriptor.TypeDescriptor;
pub const typeDescriptorFromJson = type_descriptor.typeDescriptorFromJson;
pub const typeDescriptorToJson = type_descriptor.typeDescriptorToJson;

// Internal hooks (generated/runtime internals)
pub const _EnumAdapter = enum_adapter.EnumAdapter;
pub const _enumSerializerFromStatic = enum_adapter.enumSerializerFromStatic;
pub const _StructAdapter = struct_adapter.StructAdapter;
pub const _SerializerVTable = core._SerializerVTable;
pub const _serializerFromAdapter = core._serializerFromAdapter;
pub const _structSerializerFromStatic = struct_adapter.structSerializerFromStatic;

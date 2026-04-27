[![npm](https://img.shields.io/npm/v/skir-zig-gen)](https://www.npmjs.com/package/skir-zig-gen)
[![build](https://github.com/gepheum/skir-zig-gen/workflows/Build/badge.svg)](https://github.com/gepheum/skir-zig-gen/actions)

# Skir's Zig code generator

Official plugin for generating Zig code from [.skir](https://github.com/gepheum/skir) files.

## Set up

In your `skir.yml` file, add the following snippet under `generators`:
```yaml
  - mod: skir-zig-gen
    outDir: ./src/skirout
    config: {}
```

The generated Zig code has a runtime dependency on `skir_client`. Add it to your `build.zig.zon`:

```zig
.dependencies = .{
    .skir_client = .{
        .url = "https://github.com/gepheum/skir-zig-client/archive/refs/heads/main.tar.gz",
        .hash = "<hash printed by zig fetch>",
    },
},
```

Then fetch the archive once to get the hash:

```sh
zig fetch https://github.com/gepheum/skir-zig-client/archive/refs/heads/main.tar.gz
```

For more information, see this Zig project [example](https://github.com/gepheum/skir-zig-example).

## Zig generated code guide

The examples below are for the code generated from [this](https://github.com/gepheum/skir-zig-example/blob/main/skir-src/user.skir) .skir file.

### Referring to generated symbols

```zig
// Import the Zig module generated from "user.skir".
const user_mod = @import("skirout/user.zig");
const skir = @import("skir_client.zig");

// Now you can use: user_mod.User, user_mod.UserRegistry,
// user_mod.SubscriptionStatus, user_mod.tarzan_const, etc.
```

### Struct types

Skir generates a plain Zig struct for every struct in the .skir file. All fields are value types; the struct is not heap-allocated by the generator.

```zig
// Construct a User by providing all fields.
const john: user_mod.User = .{
    .user_id = 42,
    .name = "John Doe",
    .quote = "Coffee is just a socially acceptable form of rage.",
    .pets = &.{.{
        .name = "Dumbo",
        .height_in_meters = 1.0,
        .picture = "🐘",
        ._unrecognized = null,
    }},
    .subscription_status = .Free,
    ._unrecognized = null,
};

std.debug.print("{s}\n", .{john.name}); // John Doe
```

#### Default value

```zig
// User.default is an instance with all fields set to their zero values.
const jane = user_mod.User.default;
std.debug.print("{s}\n", .{jane.name}); // (empty string)
std.debug.print("{d}\n", .{jane.user_id}); // 0
```

#### Creating modified copies

```zig
// Zig structs have value semantics: assigning a struct copies it.
// Modify the copy's fields to produce a derived value.
var evil_john = john;
evil_john.name = "Evil John";
evil_john.quote = "I solemnly swear I am up to no good.";

std.debug.print("{s}\n", .{evil_john.name}); // Evil John
std.debug.print("{d}\n", .{evil_john.user_id}); // 42
```

### Enum types

Skir generates a tagged union for every enum in the .skir file.

The definition of the `SubscriptionStatus` enum in the .skir file is:
```rust
enum SubscriptionStatus {
  FREE;
  trial: Trial;
  PREMIUM;
}
```

#### Making enum values

```zig
const trial_payload: user_mod.SubscriptionStatus.Trial_ = .{
    .start_time = .{ .unix_millis = 1_744_974_198_000 },
    ._unrecognized = null,
};

const some_statuses = [_]user_mod.SubscriptionStatus{
    // The .Unknown variant is present in all Skir enums even if it is not
    // declared in the .skir file.
    user_mod.SubscriptionStatus.unknown,
    .Free,
    .Premium,
    // Wrapper variants carry a value.
    .{ .Trial = &trial_payload },
};
```

### Enum matching

```zig
fn subscriptionInfoText(status: user_mod.SubscriptionStatus) []const u8 {
    return switch (status) {
        .Unknown => "Unknown subscription status",
        .Free => "Free user",
        .Trial => |trial| blk: {
            _ = trial;
            break :blk "On trial since (some timestamp)";
        },
        .Premium => "Premium user",
    };
}

std.debug.print("{s}\n", .{subscriptionInfoText(john.subscription_status)}); // Free user
std.debug.print("{s}\n", .{subscriptionInfoText(user_mod.SubscriptionStatus.unknown)});
// Unknown subscription status
std.debug.print("{s}\n", .{subscriptionInfoText(.{ .Trial = &trial_payload })});
// On trial since (some timestamp)
```

### Serialization

`User.serializer()` returns a serializer which can serialize and deserialize instances of `User`.

```zig
const user_serializer = user_mod.User.serializer();

// Serialize to dense JSON (field-number-based; the default mode).
// Use this when you plan to deserialize the value later. Because field
// names are not included, renaming a field remains backward-compatible.
const john_dense_json = try user_serializer.serialize(allocator, john, .{ .format = .denseJson });
defer allocator.free(john_dense_json);
std.debug.print("{s}\n", .{john_dense_json});
// [42,"John Doe",...]

// Serialize to readable (name-based, indented) JSON.
// Use this mainly for debugging.
const john_readable_json = try user_serializer.serialize(allocator, john, .{ .format = .readableJson });
defer allocator.free(john_readable_json);
std.debug.print("{s}\n", .{john_readable_json});
// {
//   "user_id": 42,
//   "name": "John Doe",
//   "quote": "Coffee is just a socially acceptable form of rage.",
//   "pets": [
//     {
//       "name": "Dumbo",
//       "height_in_meters": 1.0,
//       "picture": "🐘"
//     }
//   ],
//   "subscription_status": "FREE"
// }

// Serialize to binary format (more compact than JSON; useful when
// performance matters, though the difference is rarely significant).
const john_binary = try user_serializer.serialize(allocator, john, .{ .format = .binary });
defer allocator.free(john_binary);
```

### Deserialization

```zig
// Use .deserialize() to deserialize from JSON (both dense and readable
// formats are accepted) or binary.
const reserialized_john = try user_serializer.deserialize(allocator, john_dense_json, .{});
std.debug.print("{s}\n", .{reserialized_john.name}); // John Doe
```

### Primitive serializers

```zig
// skir.boolSerializer(), skir.int32Serializer(), etc. return serializers
// for Zig primitive types.
try printSerialized("bool", skir.boolSerializer(), true);
// bool: 1
try printSerialized("int32", skir.int32Serializer(), @as(i32, 3));
// int32: 3
try printSerialized("int64", skir.int64Serializer(), @as(i64, 9_223_372_036_854_775_807));
// int64: "9223372036854775807"
try printSerialized("hash64", skir.hash64Serializer(), @as(u64, 18_446_744_073_709_551_615));
// hash64: "18446744073709551615"
try printSerialized("timestamp", skir.timestampSerializer(), skir.Timestamp{ .unix_millis = 1_743_682_787_000 });
// timestamp: 1743682787000
try printSerialized("float32", skir.float32Serializer(), @as(f32, 3.14));
// float32: 3.14
try printSerialized("float64", skir.float64Serializer(), @as(f64, 3.14));
// float64: 3.14
try printSerialized("string", skir.stringSerializer(), "Foo");
// string: "Foo"
try printSerialized("bytes", skir.bytesSerializer(), @as([]const u8, &.{ 1, 2, 3 }));
// bytes: "AQID"
```

Where `printSerialized` is defined as:

```zig
fn printSerialized(label: []const u8, serializer: anytype, value: @TypeOf(serializer).Value) !void {
    const allocator = std.heap.page_allocator;
    const dense = try serializer.serialize(allocator, value, .{ .format = .denseJson });
    defer allocator.free(dense);
    std.debug.print("{s}: {s}\n", .{ label, dense });
}
```

### Composite serializers

```zig
const opt_string_ser = skir.optionalSerializer(skir.stringSerializer());
try printSerialized("optional some", opt_string_ser, @as(?[]const u8, "foo"));
// optional some: "foo"
try printSerialized("optional none", opt_string_ser, @as(?[]const u8, null));
// optional none: null

const bool_array_ser = skir.arraySerializer(skir.boolSerializer());
try printSerialized("bool array", bool_array_ser, @as([]const bool, &.{ true, false }));
// bool array: [1,0]
```

### Constants

```zig
// Constants declared with 'const' in the .skir file are available as
// module-level values in the generated Zig file.
const tarzan = user_mod.tarzan_const;
std.debug.print("{s}\n", .{tarzan.name}); // Tarzan

const tarzan_json = try user_serializer.serialize(allocator, tarzan, .{ .format = .readableJson });
defer allocator.free(tarzan_json);
std.debug.print("{s}\n", .{tarzan_json});
// {
//   "user_id": 123,
//   "name": "Tarzan",
//   "quote": "AAAAaAaAaAyAAAAaAaAaAyAAAAaAaAaA",
//   "pets": [
//     {
//       "name": "Cheeta",
//       "height_in_meters": 1.67,
//       "picture": "🐒"
//     }
//   ],
//   "subscription_status": {
//     "kind": "trial",
//     "value": {
//       "start_time": 1743592409000
//     }
//   }
// }
```

### Keyed arrays

```zig
// In the .skir file:
//   struct UserRegistry {
//     users: [User|user_id];
//   }
// The '|user_id' part tells Skir to generate a search keyed by user_id.

var users = [_]user_mod.User{ john, jane, evil_john, tarzan };
var registry = user_mod.UserRegistry{
    .users = skir.KeyedArray(user_mod.User.By_UserId).init(allocator, users[0..]),
    ._unrecognized = null,
};
defer registry.users.deinit();

// findByKey returns !?*T.
// The first lookup runs in O(n); subsequent lookups run in O(1).
const found_43 = try registry.users.findByKey(43);
std.debug.print("{}\n", .{found_43 == null}); // true

// If multiple elements share the same key, the last one wins.
const found_42 = try registry.users.findByKey(42);
if (found_42) |u| {
    std.debug.print("{s}\n", .{u.name}); // Evil John
}

const maybe_missing = try registry.users.findByKey(999);
const fallback = maybe_missing orelse &user_mod.User.default;
std.debug.print("{d}\n", .{fallback.user_id}); // 0
```

### SkirRPC services

#### Starting a SkirRPC service on an HTTP server

Full example [here](https://github.com/gepheum/skir-zig-example/blob/main/src/start_service.zig).

#### Sending RPCs to a SkirRPC service

Full example [here](https://github.com/gepheum/skir-zig-example/blob/main/src/call_service.zig).

### Reflection

Reflection allows you to inspect a Skir type at runtime.

```zig
const type_descriptor = user_serializer.typeDescriptor();
switch (type_descriptor) {
    .struct_record => |sd| {
        std.debug.print("{s} has {d} fields\n", .{ sd.name, sd.fields.len });
        // User has 5 fields
        if (sd.fieldByName("name")) |f| {
            std.debug.print("field 'name' number={d}\n", .{f.number});
        }
    },
    else => {},
}

const enum_type_descriptor = user_mod.SubscriptionStatus.serializer().typeDescriptor();
switch (enum_type_descriptor) {
    .enum_record => |ed| {
        std.debug.print("{s} has {d} variants\n", .{ ed.name, ed.variants.len });
        // SubscriptionStatus has 4 variants
        if (ed.variantByName("trial")) |variant| {
            std.debug.print("variant trial number={d}\n", .{variant.number()});
        }
    },
    else => {},
}
```

#### RPC method descriptors

```zig
const get_user = service_mod.get_user_method();
std.debug.print("{s}\n", .{get_user.name}); // GetUser
std.debug.print("{d}\n", .{get_user.number}); // 12345
std.debug.print("{s}\n", .{get_user.doc});

const add_user = service_mod.add_user_method();
std.debug.print("{s}\n", .{add_user.name}); // AddUser
```

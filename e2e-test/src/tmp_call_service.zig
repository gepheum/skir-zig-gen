// TEMPORARY SCRIPT: calls the local SkirRPC service.
//
// Run with:
//   zig run src/tmp_call_service.zig
//
// Make sure tmp_start_service.zig is running first.
// Remove this file (and tmp_start_service.zig) when no longer needed.

const std = @import("std");
const skir_client = @import("skir_client.zig");
const service_mod = @import("skirout/service.zig");
const service_user_mod = @import("skirout/service_user.zig");

const User = service_user_mod.User;
const GetUserRequest = service_mod.GetUserRequest;
const GetUserResponse = service_mod.GetUserResponse;
const AddUserRequest = service_mod.AddUserRequest;
const AddUserResponse = service_mod.AddUserResponse;
const SubscriptionStatus = service_user_mod.SubscriptionStatus;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var client = try skir_client.ServiceClient.init(allocator, "http://127.0.0.1:18787/myapi");
    defer client.deinit();

    // Add two users
    for ([_]User{
        .{
            .user_id = 42,
            .name = "John Doe",
            .quote = "Coffee is just a socially acceptable form of rage.",
            .pets = &.{},
            .subscription_status = .Free,
            ._unrecognized = null,
        },
        service_user_mod.tarzan_const,
    }) |user| {
        const result = try client.invokeRemote(
            AddUserRequest,
            AddUserResponse,
            &service_mod.add_user_method(),
            &AddUserRequest{
                .user = user,
                ._unrecognized = null,
            },
            &.{},
        );
        const name = user.name;
        const id = user.user_id;
        switch (result) {
            .ok => {
                std.debug.print("Added user \"{s}\" (id={d})\n", .{ name, id });
            },
            .err => |rpc_err| {
                defer allocator.free(rpc_err.message);
                std.debug.print("RPC error {d}: {s}\n", .{ rpc_err.status_code, rpc_err.message });
                return;
            },
        }
    }

    // Retrieve Tarzan
    const tarzan = service_user_mod.tarzan_const;
    const got = try client.invokeRemote(
        GetUserRequest,
        GetUserResponse,
        &service_mod.get_user_method(),
        &GetUserRequest{
            .user_id = tarzan.user_id,
            ._unrecognized = null,
        },
        &.{},
    );
    switch (got) {
        .ok => |response| {
            if (response.user) |u| {
                const json = try User.serializer().serialize(allocator, u, .{ .format = .readableJson });
                defer allocator.free(json);
                std.debug.print("Got user: {s}\n", .{json});
            } else {
                std.debug.print("User not found\n", .{});
            }
        },
        .err => |rpc_err| {
            defer allocator.free(rpc_err.message);
            std.debug.print("RPC error {d}: {s}\n", .{ rpc_err.status_code, rpc_err.message });
        },
    }
}

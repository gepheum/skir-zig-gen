// Root module for the e2e test build. Imports generated skirout files to
// verify that the generated code compiles successfully.
pub const skirout_constants = @import("skirout/constants.zig");
pub const skirout_enums = @import("skirout/enums.zig");
pub const skirout_full_name = @import("skirout/full_name.zig");
pub const skirout_methods = @import("skirout/methods.zig");
pub const skirout_ownership = @import("skirout/ownership.zig");
pub const skirout_quest_collection = @import("skirout/quest_collection.zig");
pub const skirout_reflection = @import("skirout/reflection.zig");
pub const skirout_schema_change = @import("skirout/schema_change.zig");
pub const skirout_service_user = @import("skirout/service_user.zig");
pub const skirout_service = @import("skirout/service.zig");
pub const skirout_shapes = @import("skirout/shapes.zig");
pub const skirout_structs = @import("skirout/structs.zig");
pub const skirout_user = @import("skirout/user.zig");
pub const skirout_vehicles_car = @import("skirout/vehicles/car.zig");
pub const skirout_external_fantasy_game =
    @import("skirout/external/gepheum/skir_fantasy_game_example/fantasy_game.zig");
pub const skirout_external_fantasy_game_items_loot =
    @import("skirout/external/gepheum/skir_fantasy_game_example/items/loot.zig");
pub const skirout_external_goldens =
    @import("skirout/external/gepheum/skir_golden_tests/goldens.zig");
pub const skir_client = @import("skir_client");

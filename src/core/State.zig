const std = @import("std");
const ray = @import("../raylib.zig");
const Entity = @import("Entity.zig");
const Input = @import("Input.zig");

// Player movement constants
pub const PLAYER_MOVE_SPEED: f32 = 50.0; // Base movement speed

// Flocking behavior constants
pub const CLOSE_DISTANCE: f32 = 31.0; // Minimum desired distance between objects
pub const PLAYER_AVOID_MULTIPLIER: f32 = 10.0; // How much further objects stay from player vs other objects
pub const PLAYER_AVOID_FORCE: f32 = 30.0; // How strongly objects avoid the player
pub const BASE_MOVE_SPEED: f32 = 100.0; // Base movement speed for all behaviors
pub const AVOIDANCE_WEIGHT: f32 = 0.5; // How strongly avoidance forces are applied
pub const ATTRACTION_WEIGHT: f32 = 0.005; // How strongly objects are attracted to player
pub const MIN_DISTANCE: f32 = 0.001; // Minimum distance to prevent division by zero

pub const GameState = struct {
    entity_manager: Entity.EntityManager,
    input_manager: Input.InputManager,
    player_id: usize,
    last_spawn_time: f64,
    last_delete_time: f64,
    last_mark_delete_time: f64,
    zoom: f32,
    is_spawning: bool,
    is_deleting: bool,
    is_marking_delete: bool,
    allocator: std.mem.Allocator,
    is_client_mode: bool,

    pub fn init(allocator: std.mem.Allocator, create_player: bool) !GameState {
        var state = GameState{
            .entity_manager = Entity.EntityManager.init(allocator),
            .input_manager = Input.InputManager.init(),
            .player_id = 0,
            .last_spawn_time = 0,
            .last_delete_time = 0,
            .last_mark_delete_time = 0,
            .zoom = 1.0,
            .is_spawning = false,
            .is_deleting = false,
            .is_marking_delete = false,
            .allocator = allocator,
            .is_client_mode = false,
        };

        if (create_player) {
            const window_width = ray.getScreenWidth();
            const window_height = ray.getScreenHeight();

            // Create player entity
            const player_entity = Entity.Entity{
                .position = .{ .x = @divTrunc(@as(f32, @floatFromInt(window_width)), 2), .y = @divTrunc(@as(f32, @floatFromInt(window_height)), 2) },
                .scale = 1.0,
                .deleteable = 0,
                .entity_type = .player,
            };
            state.player_id = try state.entity_manager.createEntity(player_entity, null);
        }

        return state;
    }

    pub fn deinit(self: *GameState) void {
        self.input_manager.deinit();
        self.entity_manager.deinit();
    }

    pub fn update(self: *GameState, delta_time: f32, current_game_time: f64) !void {
        // Reset flags at the start of the update
        // Wait for input to re-set them if they are still valid
        self.is_spawning = false;
        self.is_deleting = false;
        self.is_marking_delete = false;

        // Poll for new input events
        try self.input_manager.pollLocalInput();

        // Process all queued input events
        const events = self.input_manager.processEvents();
        if (events.len > 0) {
            std.debug.print("Processing {} input events\n", .{events.len});
        }

        for (events) |event| {
            switch (event.data) {
                .movement => |mov| {
                    // Only log non-zero movement events
                    if (mov.x != 0 or mov.y != 0) {
                        std.debug.print("Processing movement event: ({d:.2}, {d:.2}), source: {}, player: {}\n", .{ mov.x, mov.y, event.source, event.source_player_id });
                    }
                    // Update player position
                    const speed: f32 = PLAYER_MOVE_SPEED; // Base movement speed
                    const target_player_id = if (event.source == .local) self.player_id else event.source_player_id;
                    if (target_player_id >= self.entity_manager.entities.len) {
                        std.debug.print("Warning: Invalid player_id {}, entities length {}\n", .{ target_player_id, self.entity_manager.entities.len });
                        continue;
                    }

                    // Only apply movement on server or in singleplayer mode
                    // In multiplayer client mode, movement comes from server state updates
                    if (!self.is_client_mode) {
                        // Apply movement with normalized direction if moving
                        if (mov.x != 0 or mov.y != 0) {
                            // Clamp delta time to avoid huge jumps
                            const clamped_delta = @min(delta_time, 0.032); // Max 32ms frame time

                            const old_pos = self.entity_manager.entities.items(.position)[target_player_id];
                            self.entity_manager.entities.items(.position)[target_player_id].x += mov.x * speed * clamped_delta;
                            self.entity_manager.entities.items(.position)[target_player_id].y += mov.y * speed * clamped_delta;
                            const new_pos = self.entity_manager.entities.items(.position)[target_player_id];

                            // Only log significant position changes
                            if (@abs(new_pos.x - old_pos.x) > 0.01 or @abs(new_pos.y - old_pos.y) > 0.01) {
                                std.debug.print("Server moving player {}: ({d:.2}, {d:.2}) -> ({d:.2}, {d:.2})\n", .{ target_player_id, old_pos.x, old_pos.y, new_pos.x, new_pos.y });
                            }
                        }
                    }
                },
                .spawn => |is_spawning| {
                    if (is_spawning) {
                        self.is_spawning = true;
                        const spawn_cooldown: f32 = 1.0 / 10.0;
                        const current_time = event.timestamp;
                        if (current_time - self.last_spawn_time > spawn_cooldown) {
                            self.last_spawn_time = current_time;
                            const target_player_id = if (event.source == .local) self.player_id else event.source_player_id;
                            try self.spawnChildren(current_time, target_player_id);
                        }
                    } else {
                        self.is_spawning = false;
                    }
                },
                .marking_delete => |is_marking_delete| {
                    self.is_marking_delete = is_marking_delete;
                    const target_player_id = if (event.source == .local) self.player_id else event.source_player_id;
                    if (is_marking_delete) {
                        const mark_delete_cooldown: f32 = 1.0 / 50.0;
                        const current_time = event.timestamp;
                        if (current_time - self.last_mark_delete_time > mark_delete_cooldown) {
                            self.last_mark_delete_time = current_time;
                            // Mark first valid child as deleteable
                            var next_index: usize = 0;
                            while (next_index < self.entity_manager.relationships.items[target_player_id].children.items.len) {
                                const child_id = self.entity_manager.relationships.items[target_player_id].children.items[next_index];
                                if (self.entity_manager.entities.items(.deleteable)[child_id] == 0) {
                                    self.entity_manager.entities.items(.deleteable)[child_id] = current_time;
                                    break;
                                }
                                next_index += 1;
                            }
                        }
                    }
                },
            }
        }

        // Clear processed events
        self.input_manager.clearEvents();

        var some_deleteable = false;

        // get active deleteable entities
        const slice = self.entity_manager.entities.slice();
        for (slice.items(.active), slice.items(.deleteable)) |active, deleteable| {
            if (active and deleteable > 0) {
                some_deleteable = true;
                break;
            }
        }

        if (!self.is_marking_delete and some_deleteable) {
            self.is_deleting = true;
        } else {
            self.is_deleting = false;
        }

        // Process deletions when there is any deleteable entity
        // And marking delete is not active
        const delete_cooldown: f32 = 1.0 / 20.0;
        const can_delete = current_game_time - self.last_delete_time > delete_cooldown;
        if (self.is_deleting and can_delete) {
            self.last_delete_time = current_game_time;
            const entities = self.entity_manager.entities.slice();
            for (entities.items(.active), entities.items(.deleteable), 0..) |active, deleteable, id| {
                if (active and deleteable > 0) {
                    const delta = current_game_time - self.entity_manager.entities.items(.deleteable)[id];
                    std.debug.print("Entity {}: active: {}, deleteable: {}, delta: {}\n", .{ id, active, deleteable, delta });
                    if (delta > delete_cooldown) {
                        self.entity_manager.deleteEntity(id);
                    }
                }
            }
        }

        // Update entity positions
        self.updateEntities(delta_time);
    }

    pub fn spawnChildren(self: *GameState, time: f64, parent_id: usize) !void {
        const spawn_count: usize = 5;
        if (self.entity_manager.getActiveEntity(parent_id)) |player| {
            const spawn_radius: f32 = 10.0;
            const angle_increment = 2 * std.math.pi / @as(f32, @floatFromInt(spawn_count));
            const angle_offset = 10.0 * @as(f32, @floatCast(time));

            for (0..spawn_count) |i| {
                const angle = angle_increment * @as(f32, @floatFromInt(i)) + angle_offset;
                const new_position = ray.Vector2{
                    .x = player.position.x + spawn_radius * std.math.cos(angle),
                    .y = player.position.y + spawn_radius * std.math.sin(angle),
                };
                const new_entity = Entity.Entity{
                    .position = new_position,
                    .scale = 1.0 / 6.0,
                    .deleteable = 0,
                    .entity_type = .child,
                };
                _ = try self.entity_manager.createEntity(new_entity, parent_id);
            }
        }
    }

    pub fn updateEntities(self: *GameState, delta_time: f32) void {
        // for all player entities, update their children
        for (self.entity_manager.entities.items(.entity_type), 0..self.entity_manager.entities.len) |entity_type, id| {
            if (entity_type == .player) {
                const player_entity = self.entity_manager.getActiveEntity(id);
                if (player_entity) |player| {
                    const active_children = self.entity_manager.getActiveChildren(id);

                    // Update children positions
                    for (active_children) |child_id| {
                        var child_pos = &self.entity_manager.entities.items(.position)[child_id];
                        var avoidance = ray.Vector2{ .x = 0, .y = 0 };
                        var count: f32 = 0.0;

                        // Separation: Avoid other children
                        for (active_children) |other_id| {
                            if (child_id == other_id) continue;
                            const other = self.entity_manager.entities.items(.position)[other_id];
                            const dx = child_pos.x - other.x;
                            const dy = child_pos.y - other.y;
                            const dist = @sqrt(dx * dx + dy * dy);
                            if (dist > MIN_DISTANCE and dist < CLOSE_DISTANCE) {
                                const force = 1.0 - (dist / CLOSE_DISTANCE);
                                avoidance.x += (dx / dist) * force;
                                avoidance.y += (dy / dist) * force;
                                count += 1.0;
                            }
                        }

                        // Strong separation from player
                        const dx = child_pos.x - player.position.x;
                        const dy = child_pos.y - player.position.y;
                        const dist = @sqrt(dx * dx + dy * dy);
                        const player_avoid_dist = CLOSE_DISTANCE * PLAYER_AVOID_MULTIPLIER;
                        if (dist > MIN_DISTANCE and dist < player_avoid_dist) {
                            const force = 1.0 - (dist / player_avoid_dist);
                            avoidance.x += (dx / dist) * force * PLAYER_AVOID_FORCE;
                            avoidance.y += (dy / dist) * force * PLAYER_AVOID_FORCE;
                            count += 1.0;
                        }

                        // Apply avoidance forces
                        const move_speed = BASE_MOVE_SPEED * delta_time;
                        if (count > 0.0) {
                            child_pos.x += (avoidance.x / count * AVOIDANCE_WEIGHT) * move_speed;
                            child_pos.y += (avoidance.y / count * AVOIDANCE_WEIGHT) * move_speed;
                        }

                        // Weak attraction to player
                        const to_player_x = player.position.x - child_pos.x;
                        const to_player_y = player.position.y - child_pos.y;
                        const attract_speed = move_speed * ATTRACTION_WEIGHT;
                        child_pos.x += to_player_x * attract_speed;
                        child_pos.y += to_player_y * attract_speed;
                    }
                }
            }
        }
    }

    pub fn createPlayerEntity(self: *GameState) !usize {
        // Create a new entity for the player
        const window_width = ray.getScreenWidth();
        const window_height = ray.getScreenHeight();
        const center_x = @divTrunc(@as(f32, @floatFromInt(window_width)), 2);
        const center_y = @divTrunc(@as(f32, @floatFromInt(window_height)), 2);

        // Generate random angle and radius for position within circle
        const random_angle = @as(f32, @floatFromInt(ray.getRandomValue(0, 360))) * std.math.pi / 180.0;
        const random_radius = @as(f32, @floatFromInt(ray.getRandomValue(0, 10)));

        const player_entity = Entity.Entity{
            .position = .{
                .x = center_x + random_radius * @cos(random_angle),
                .y = center_y + random_radius * @sin(random_angle),
            },
            .scale = 1.0,
            .deleteable = 0,
            .entity_type = .player,
        };

        return try self.entity_manager.createEntity(player_entity, null);
    }

    fn handleInputEvent(self: *GameState, event: Input.InputEvent) !void {
        // Handle input events
        _ = self;
        _ = event;
    }
};

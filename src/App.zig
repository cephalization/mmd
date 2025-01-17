const std = @import("std");
const ray = @import("raylib.zig");

const App = @This();

// Entity component storage
pub const Entity = struct {
    position: ray.Vector2,
    scale: f32,
    // time marked for deletion or 0 if not marked
    deleteable: f64,
};

pub const EntityList = std.MultiArrayList(Entity);

// Relationship storage for parent-child connections
pub const Relationships = struct {
    parent_id: ?usize,
    children: std.ArrayList(usize),

    pub fn init(parent: ?usize) Relationships {
        return .{
            .parent_id = parent,
            .children = std.ArrayList(usize).init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *Relationships) void {
        self.children.deinit();
    }
};

// Global state
entities: EntityList,
relationships: std.ArrayList(Relationships),
free_slots: std.ArrayList(usize),
player_id: usize,
direction: ray.Vector2 = .{ .x = 0, .y = 0 },
spawning: bool = false,
deleting: bool = false,
last_spawn_time: f64 = 0,
last_delete_time: f64 = 0,
last_mark_delete_time: f64 = 0,
zoom: f32 = 1.0,

// Flocking behavior constants
const CLOSE_DISTANCE: f32 = 60.0; // Minimum desired distance between objects
const PLAYER_AVOID_MULTIPLIER: f32 = 4.0; // How much further objects stay from player vs other objects
const PLAYER_AVOID_FORCE: f32 = 40.0; // How strongly objects avoid the player
const BASE_MOVE_SPEED: f32 = 100.0; // Base movement speed for all behaviors
const AVOIDANCE_WEIGHT: f32 = 0.9; // How strongly avoidance forces are applied
const ATTRACTION_WEIGHT: f32 = 0.005; // How strongly objects are attracted to player
const MIN_DISTANCE: f32 = 0.001; // Minimum distance to prevent division by zero

pub fn init() !App {
    var app = App{
        .entities = EntityList{},
        .relationships = std.ArrayList(Relationships).init(std.heap.page_allocator),
        .free_slots = std.ArrayList(usize).init(std.heap.page_allocator),
        .player_id = 0,
        .direction = .{ .x = 0, .y = 0 },
        .spawning = false,
        .deleting = false,
        .last_spawn_time = 0,
        .last_delete_time = 0,
        .last_mark_delete_time = 0,
        .zoom = 1.0,
    };

    // Create player entity
    const player_entity = Entity{
        .position = .{ .x = 960, .y = 540 },
        .scale = 1.0,
        .deleteable = 0,
    };
    try app.entities.append(std.heap.page_allocator, player_entity);
    try app.relationships.append(Relationships.init(null));
    app.player_id = 0;

    return app;
}

pub fn deinit(self: *App) void {
    for (self.relationships.items) |*rel| {
        rel.deinit();
    }
    self.relationships.deinit();
    self.free_slots.deinit();
    self.entities.deinit(std.heap.page_allocator);
}

fn createEntity(self: *App, entity: Entity, parent_id: ?usize) !usize {
    var entity_id: usize = undefined;

    // Reuse a free slot if available
    if (self.free_slots.items.len > 0) {
        entity_id = self.free_slots.pop();
        self.entities.set(entity_id, entity);
        self.relationships.items[entity_id] = Relationships.init(parent_id);
    } else {
        try self.entities.append(std.heap.page_allocator, entity);
        try self.relationships.append(Relationships.init(parent_id));
        entity_id = self.entities.len - 1;
    }

    // Add to parent's children if parent exists
    if (parent_id) |pid| {
        try self.relationships.items[pid].children.append(entity_id);
    }

    return entity_id;
}

fn deleteEntity(self: *App, entity_id: usize) void {
    var rel = &self.relationships.items[entity_id];

    // Remove from parent's children list
    if (rel.parent_id) |pid| {
        for (self.relationships.items[pid].children.items, 0..) |child, i| {
            if (child == entity_id) {
                _ = self.relationships.items[pid].children.orderedRemove(i);
                break;
            }
        }
    }

    // Clean up relationships
    rel.deinit();
    rel.* = Relationships.init(null);

    // Mark slot as free
    self.free_slots.append(entity_id) catch unreachable;
}

// Update your spawn logic:
fn spawnChildren(self: *App, time: f64) !void {
    const spawn_count: usize = 5;
    const player_pos = self.entities.get(self.player_id).position;

    const spawn_radius: f32 = 10.0;
    // use time, as f32, to modulate the angle increment
    const angle_increment = 2 * std.math.pi / @as(f32, @floatFromInt(spawn_count));
    const angle_offset = 10.0 * @as(f32, @floatCast(time));

    for (0..spawn_count) |i| {
        const angle = angle_increment * @as(f32, @floatFromInt(i)) + angle_offset;
        const new_position = ray.Vector2{
            .x = player_pos.x + spawn_radius * std.math.cos(angle),
            .y = player_pos.y + spawn_radius * std.math.sin(angle),
        };
        const new_entity = Entity{
            .position = new_position,
            .scale = 1.0 / 6.0,
            .deleteable = 0,
        };
        _ = try self.createEntity(new_entity, self.player_id);
    }
}

pub fn run(self: *App) !void {
    ray.init(1920, 1080, "mmd");
    ray.setTargetFPS(60);

    while (!ray.shouldClose()) {
        try self.update();
        self.render();
    }

    ray.close();
}

fn update(self: *App) !void {
    // Handle input
    var direction = self.direction;
    var spawning = self.spawning;
    var deleting = self.deleting;

    // apply friction to player velocity
    const friction = 0.79;
    direction.x *= friction;
    direction.y *= friction;

    if (ray.isKeyDown(ray.KeyboardKey.KEY_LEFT)) direction.x -= 1;
    if (ray.isKeyDown(ray.KeyboardKey.KEY_RIGHT)) direction.x += 1;
    if (ray.isKeyDown(ray.KeyboardKey.KEY_UP)) direction.y -= 1;
    if (ray.isKeyDown(ray.KeyboardKey.KEY_DOWN)) direction.y += 1;
    if (ray.isKeyDown(ray.KeyboardKey.KEY_SPACE)) spawning = true;
    if (ray.isKeyUp(ray.KeyboardKey.KEY_SPACE)) spawning = false;
    if (ray.isKeyPressed(ray.KeyboardKey.KEY_R)) {
        deleting = true;
    }
    if (ray.isKeyUp(ray.KeyboardKey.KEY_R)) {
        deleting = false;
    }

    self.direction = direction;
    self.spawning = spawning;
    self.deleting = deleting;
    // Update player position
    const delta_time = ray.getFrameTime();
    const speed: f32 = 100.0;
    self.entities.items(.position)[self.player_id].x += direction.x * speed * delta_time;
    self.entities.items(.position)[self.player_id].y += direction.y * speed * delta_time;

    // Spawn new objects
    const spawn_cooldown: f32 = 1.0 / 10.0; // Spawn up to 10 groups per second
    const current_time = ray.getTime();
    if (spawning and current_time - self.last_spawn_time > spawn_cooldown) {
        self.last_spawn_time = current_time;
        try spawnChildren(self, current_time);
    }

    // Mark one child at a time as deleteable if deleting is true
    const mark_delete_cooldown: f32 = 1.0 / 10.0;
    if (deleting and current_time - self.last_mark_delete_time > mark_delete_cooldown) {
        self.last_mark_delete_time = current_time;
        // iterate over children and mark the first one valid as deleteable
        var next_index: usize = 0;
        while (next_index < self.relationships.items[self.player_id].children.items.len) {
            const child_id = self.relationships.items[self.player_id].children.items[next_index];
            if (self.entities.items(.deleteable)[child_id] == 0) {
                self.entities.items(.deleteable)[child_id] = current_time;
                break;
            }
            next_index += 1;
        }
    }

    // Delete marked objects on a cooldown
    const delete_cooldown: f32 = 1.0 / 20.0;
    if (!deleting and current_time - self.last_delete_time > delete_cooldown) {
        self.last_delete_time = current_time;
        if (self.relationships.items[self.player_id].children.items.len > 0) {
            const child_id = self.relationships.items[self.player_id].children.items[0];
            if (self.entities.items(.deleteable)[child_id] > 0) {
                const delta = current_time - self.entities.items(.deleteable)[child_id];
                // delete if the object has been marked for deletion for more than the cooldown
                if (delta > delete_cooldown) {
                    deleteEntity(self, child_id);
                }
            }
        }
    }

    // Update children positions
    for (self.relationships.items[self.player_id].children.items) |child_id| {
        var child_pos = &self.entities.items(.position)[child_id];
        var avoidance = ray.Vector2{ .x = 0, .y = 0 };
        var count: f32 = 0.0;

        // Separation: Avoid other children
        for (self.relationships.items[self.player_id].children.items) |other_id| {
            if (child_id == other_id) continue;
            const other = self.entities.items(.position)[other_id];
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
        const player_pos = self.entities.items(.position)[self.player_id];
        const dx = child_pos.x - player_pos.x;
        const dy = child_pos.y - player_pos.y;
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
        const to_player_x = player_pos.x - child_pos.x;
        const to_player_y = player_pos.y - child_pos.y;
        const attract_speed = move_speed * ATTRACTION_WEIGHT;
        child_pos.x += to_player_x * attract_speed;
        child_pos.y += to_player_y * attract_speed;
    }
}

fn render(self: *App) void {
    ray.beginDrawing();
    defer ray.endDrawing();

    ray.clearBackground(ray.BLACK);

    // Draw player
    const player = self.entities.get(self.player_id);
    ray.drawCircle(
        @as(i32, @intFromFloat(player.position.x)),
        @as(i32, @intFromFloat(player.position.y)),
        20 * player.scale,
        ray.WHITE,
    );

    // Draw children
    for (self.relationships.items[self.player_id].children.items) |child_id| {
        const child = self.entities.items(.position)[child_id];
        const color = if (self.entities.items(.deleteable)[child_id] > 0) ray.RED else ray.BLUE;
        ray.drawCircle(
            @as(i32, @intFromFloat(child.x)),
            @as(i32, @intFromFloat(child.y)),
            18 * self.entities.items(.scale)[child_id],
            color,
        );
    }

    const player_coords = std.fmt.allocPrint(std.heap.page_allocator, "player: ({}, {})", .{ player.position.x, player.position.y }) catch unreachable;
    const spawn_text = std.fmt.allocPrint(std.heap.page_allocator, "spawning: {}", .{self.spawning}) catch unreachable;
    const children_text = std.fmt.allocPrint(std.heap.page_allocator, "children: {}", .{self.relationships.items[self.player_id].children.items.len}) catch unreachable;

    ray.drawFPS(10, 10);
    ray.drawText(player_coords.ptr, 10, 70, 20, ray.WHITE);
    ray.drawText(spawn_text.ptr, 10, 30, 20, ray.WHITE);
    ray.drawText(children_text.ptr, 10, 50, 20, ray.WHITE);
}

const std = @import("std");
const ray = @import("../raylib.zig");

pub const InputSource = enum {
    local,
    remote,
};

pub const InputEvent = struct {
    source: InputSource,
    timestamp: f64,
    source_player_id: usize = 0,
    data: union(enum) {
        movement: struct {
            x: f32,
            y: f32,
        },
        spawn: bool,
        marking_delete: bool,
    },
};

pub const InputState = struct {
    direction: ray.Vector2,
    spawning: bool,
    marking_delete: bool,
};

pub const InputManager = struct {
    state: InputState,
    event_queue: std.ArrayList(InputEvent),
    player_id: usize,

    pub fn init() InputManager {
        return .{
            .state = .{
                .direction = .{ .x = 0, .y = 0 },
                .spawning = false,
                .marking_delete = false,
            },
            .event_queue = std.ArrayList(InputEvent).init(std.heap.page_allocator),
            .player_id = 0,
        };
    }

    pub fn deinit(self: *InputManager) void {
        self.event_queue.deinit();
    }

    pub fn pollLocalInput(self: *InputManager) !void {
        const current_time = ray.getTime();

        // Handle movement input
        var new_direction = ray.Vector2{ .x = 0, .y = 0 };

        // Get current key states
        const left = ray.isKeyDown(ray.KeyboardKey.KEY_LEFT);
        const right = ray.isKeyDown(ray.KeyboardKey.KEY_RIGHT);
        const up = ray.isKeyDown(ray.KeyboardKey.KEY_UP);
        const down = ray.isKeyDown(ray.KeyboardKey.KEY_DOWN);

        // Update direction based on keys
        if (left) new_direction.x -= 1;
        if (right) new_direction.x += 1;
        if (up) new_direction.y -= 1;
        if (down) new_direction.y += 1;

        // Normalize diagonal movement
        if (new_direction.x != 0 and new_direction.y != 0) {
            const length = @sqrt(2.0); // Length of (1,1) vector
            new_direction.x /= length;
            new_direction.y /= length;
        }

        // Send movement event if we're moving or if we just stopped moving
        const was_moving = self.state.direction.x != 0 or self.state.direction.y != 0;
        const is_moving = new_direction.x != 0 or new_direction.y != 0;

        if (is_moving or was_moving) {
            try self.event_queue.append(.{
                .source = .local,
                .timestamp = current_time,
                .source_player_id = self.player_id,
                .data = .{
                    .movement = .{
                        .x = new_direction.x,
                        .y = new_direction.y,
                    },
                },
            });
        }

        self.state.direction = new_direction;

        // Handle spawn input
        const spawn_state = ray.isKeyDown(ray.KeyboardKey.KEY_SPACE);
        self.state.spawning = spawn_state;
        if (spawn_state) {
            try self.event_queue.append(.{
                .source = .local,
                .timestamp = current_time,
                .source_player_id = self.player_id,
                .data = .{ .spawn = spawn_state },
            });
        }

        // Handle delete input
        var delete_state = self.state.marking_delete;
        if (ray.isKeyDown(ray.KeyboardKey.KEY_R)) {
            delete_state = true;
        }
        if (ray.isKeyUp(ray.KeyboardKey.KEY_R)) {
            delete_state = false;
        }
        self.state.marking_delete = delete_state;
        if (delete_state) {
            try self.event_queue.append(.{
                .source = .local,
                .timestamp = current_time,
                .source_player_id = self.player_id,
                .data = .{ .marking_delete = delete_state },
            });
        }
    }

    pub fn addRemoteInput(self: *InputManager, event: InputEvent) !void {
        std.debug.assert(event.source == .remote);
        try self.event_queue.append(event);
    }

    pub fn getState(self: *const InputManager) InputState {
        return self.state;
    }

    pub fn processEvents(self: *InputManager) []const InputEvent {
        return self.event_queue.items;
    }

    pub fn clearEvents(self: *InputManager) void {
        self.event_queue.clearRetainingCapacity();
    }
};

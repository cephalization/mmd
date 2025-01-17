const std = @import("std");
const ray = @import("../raylib.zig");

pub const InputSource = enum {
    local,
    remote,
};

pub const InputEvent = struct {
    source: InputSource,
    timestamp: f64,
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

    pub fn init() InputManager {
        return .{
            .state = .{
                .direction = .{ .x = 0, .y = 0 },
                .spawning = false,
                .marking_delete = false,
            },
            .event_queue = std.ArrayList(InputEvent).init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *InputManager) void {
        self.event_queue.deinit();
    }

    pub fn pollLocalInput(self: *InputManager) !void {
        const current_time = ray.getTime();

        // Handle movement input with friction
        var new_direction = self.state.direction;
        const friction = 0.79;
        new_direction.x *= friction;
        new_direction.y *= friction;

        var movement_changed = false;
        if (ray.isKeyDown(ray.KeyboardKey.KEY_LEFT)) {
            new_direction.x -= 1;
            movement_changed = true;
        }
        if (ray.isKeyDown(ray.KeyboardKey.KEY_RIGHT)) {
            new_direction.x += 1;
            movement_changed = true;
        }
        if (ray.isKeyDown(ray.KeyboardKey.KEY_UP)) {
            new_direction.y -= 1;
            movement_changed = true;
        }
        if (ray.isKeyDown(ray.KeyboardKey.KEY_DOWN)) {
            new_direction.y += 1;
            movement_changed = true;
        }

        // Only create movement event if there's actual change
        if (movement_changed or
            (new_direction.x != 0 or new_direction.y != 0))
        {
            try self.event_queue.append(.{
                .source = .local,
                .timestamp = current_time,
                .data = .{
                    .movement = .{
                        .x = new_direction.x,
                        .y = new_direction.y,
                    },
                },
            });
            self.state.direction = new_direction;
        }

        // Handle spawn input
        const spawn_state = ray.isKeyDown(ray.KeyboardKey.KEY_SPACE);
        self.state.spawning = spawn_state;
        if (spawn_state) {
            try self.event_queue.append(.{
                .source = .local,
                .timestamp = current_time,
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

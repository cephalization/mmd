const std = @import("std");
const ray = @import("../raylib.zig");
const Entity = @import("Entity.zig");

fn lerp(start: f32, end: f32, t: f32) f32 {
    return start + (end - start) * t;
}

fn lerpVector2(start: ray.Vector2, end: ray.Vector2, t: f32) ray.Vector2 {
    return .{
        .x = lerp(start.x, end.x, t),
        .y = lerp(start.y, end.y, t),
    };
}

pub const Camera = struct {
    // Camera position in world coordinates
    position: ray.Vector2,
    // Target position for smooth movement
    target_position: ray.Vector2,
    // Camera zoom level
    zoom: f32,
    // Target entity ID to follow (null if free camera)
    target: ?usize,
    // Camera viewport dimensions
    viewport_width: f32,
    viewport_height: f32,
    // Smoothing factor for camera movement (0 = instant, 1 = no movement)
    smoothing: f32,

    pub fn init(viewport_width: f32, viewport_height: f32) Camera {
        const initial_pos = ray.Vector2{ .x = 0, .y = 0 };
        return .{
            .position = initial_pos,
            .target_position = initial_pos,
            .zoom = 1.0,
            .target = null,
            .viewport_width = viewport_width,
            .viewport_height = viewport_height,
            .smoothing = 0.85,
        };
    }

    pub fn setTarget(self: *Camera, entity_id: ?usize) void {
        self.target = entity_id;
    }

    pub fn update(self: *Camera, entity_manager: *Entity.EntityManager) void {
        if (self.target) |target_id| {
            if (entity_manager.getActiveEntity(target_id)) |target| {
                // Calculate target position (center of screen)
                self.target_position = .{
                    .x = target.position.x - self.viewport_width / (2 * self.zoom),
                    .y = target.position.y - self.viewport_height / (2 * self.zoom),
                };

                // Smoothly interpolate camera position
                const lerp_factor = 1.0 - std.math.pow(f32, self.smoothing, 60.0 * ray.getFrameTime());
                self.position = lerpVector2(self.position, self.target_position, lerp_factor);
            }
        }
    }

    pub fn worldToScreen(self: *const Camera, world_pos: ray.Vector2) ray.Vector2 {
        return .{
            .x = (world_pos.x - self.position.x) * self.zoom,
            .y = (world_pos.y - self.position.y) * self.zoom,
        };
    }

    pub fn screenToWorld(self: *const Camera, screen_pos: ray.Vector2) ray.Vector2 {
        return .{
            .x = screen_pos.x / self.zoom + self.position.x,
            .y = screen_pos.y / self.zoom + self.position.y,
        };
    }

    pub fn isInView(self: *const Camera, position: ray.Vector2, radius: f32) bool {
        const screen_pos = self.worldToScreen(position);
        const scaled_radius = radius * self.zoom;

        return screen_pos.x + scaled_radius >= 0 and
            screen_pos.x - scaled_radius <= self.viewport_width and
            screen_pos.y + scaled_radius >= 0 and
            screen_pos.y - scaled_radius <= self.viewport_height;
    }
};

const std = @import("std");
const ray = @import("../raylib.zig");
const perlin = @import("perlin");
const Camera = @import("Camera.zig");

pub const GRID_SIZE: f32 = 100.0; // Size of each grid cell
pub const GRID_COLOR = ray.Color{ .r = 40, .g = 40, .b = 40, .a = 255 }; // Dark gray grid
pub const BASE_NOISE_SCALE: f32 = 0.001; // Base scale factor for noise coordinates
pub const NOISE_THRESHOLD: f32 = 0.0; // Threshold for filling squares
pub const FILL_COLOR = ray.Color{ .r = 30, .g = 30, .b = 50, .a = 255 }; // Dark blue-ish fill

// Standard fBm parameters
const OCTAVES: u32 = 3;
const LACUNARITY: f32 = 1.0;
const PERSISTENCE: f32 = 0.5;

fn fbm(x: f32, y: f32, z: f32) f32 {
    var total: f32 = 0.0;
    var frequency: f32 = 1.0;
    var amplitude: f32 = 1.0;
    var max_value: f32 = 0.0;

    var i: u32 = 0;
    while (i < OCTAVES) : (i += 1) {
        total += perlin.noise(f32, .{
            .x = x * frequency,
            .y = y * frequency,
            .z = z * frequency,
        }) * amplitude;

        max_value += amplitude;
        frequency *= LACUNARITY;
        amplitude *= PERSISTENCE;
    }

    return total / max_value; // Normalize to [-1, 1]
}

pub const World = struct {
    noise_offset: ray.Vector2,
    grid_lines_visible: bool,

    pub fn init() World {
        return .{
            .noise_offset = .{ .x = 0, .y = 0 },
            .grid_lines_visible = false,
        };
    }

    pub fn update(_: *World) void {}

    pub fn toggleGridLines(self: *World) void {
        self.grid_lines_visible = !self.grid_lines_visible;
    }

    pub fn draw(self: *const World, camera: *const Camera.Camera, window_width: i32, window_height: i32) void {
        // Calculate visible grid bounds based on camera view
        const top_left = camera.screenToWorld(.{ .x = 0, .y = 0 });
        const bottom_right = camera.screenToWorld(.{ .x = @floatFromInt(window_width), .y = @floatFromInt(window_height) });

        // Calculate grid start and end points
        const start_x = @floor(top_left.x / GRID_SIZE) * GRID_SIZE;
        const end_x = @ceil(bottom_right.x / GRID_SIZE) * GRID_SIZE;
        const start_y = @floor(top_left.y / GRID_SIZE) * GRID_SIZE;
        const end_y = @ceil(bottom_right.y / GRID_SIZE) * GRID_SIZE;

        // Scale noise based on zoom level
        const noise_scale = BASE_NOISE_SCALE * (1.0 / camera.zoom);

        // Draw grid squares with noise
        var y = start_y;
        while (y <= end_y) : (y += GRID_SIZE) {
            var x = start_x;
            while (x <= end_x) : (x += GRID_SIZE) {
                // Get noise value for this grid cell
                const center_x = x + GRID_SIZE * 0.5;
                const center_y = y + GRID_SIZE * 0.5;

                // Apply noise scale to both the coordinates and the offset together
                const scaled_x = (center_x + self.noise_offset.x) * noise_scale;
                const scaled_y = (center_y + self.noise_offset.y) * noise_scale;
                const noise = fbm(scaled_x, scaled_y, 0);

                // If noise is above threshold, fill the square
                if (noise > NOISE_THRESHOLD) {
                    const top_left_screen = camera.worldToScreen(.{ .x = x, .y = y });
                    const bottom_right_screen = camera.worldToScreen(.{ .x = x + GRID_SIZE, .y = y + GRID_SIZE });

                    // Use noise value to determine color intensity
                    const intensity = @as(u8, @intFromFloat(noise * 255));
                    const color = ray.Color{
                        .r = 30,
                        .g = 30,
                        .b = intensity,
                        .a = 255,
                    };

                    ray.drawRectangle(
                        @as(i32, @intFromFloat(top_left_screen.x)),
                        @as(i32, @intFromFloat(top_left_screen.y)),
                        @as(i32, @intFromFloat(bottom_right_screen.x - top_left_screen.x)),
                        @as(i32, @intFromFloat(bottom_right_screen.y - top_left_screen.y)),
                        color,
                    );
                }

                // Draw grid lines if enabled
                if (self.grid_lines_visible) {
                    const start_pos_v = camera.worldToScreen(.{ .x = x, .y = y });
                    const end_pos_v = camera.worldToScreen(.{ .x = x, .y = y + GRID_SIZE });
                    ray.drawLineEx(.{ .x = start_pos_v.x, .y = start_pos_v.y }, .{ .x = end_pos_v.x, .y = end_pos_v.y }, 1.0, GRID_COLOR);
                }
            }

            // Draw horizontal lines if enabled
            if (self.grid_lines_visible) {
                const start_pos_h = camera.worldToScreen(.{ .x = start_x, .y = y });
                const end_pos_h = camera.worldToScreen(.{ .x = end_x, .y = y });
                ray.drawLineEx(.{ .x = start_pos_h.x, .y = start_pos_h.y }, .{ .x = end_pos_h.x, .y = end_pos_h.y }, 1.0, GRID_COLOR);
            }
        }

        // Draw final vertical lines if enabled
        if (self.grid_lines_visible) {
            var x = start_x;
            while (x <= end_x) : (x += GRID_SIZE) {
                const start_pos = camera.worldToScreen(.{ .x = x, .y = start_y });
                const end_pos = camera.worldToScreen(.{ .x = x, .y = end_y });
                ray.drawLineEx(.{ .x = start_pos.x, .y = start_pos.y }, .{ .x = end_pos.x, .y = end_pos.y }, 1.0, GRID_COLOR);
            }
        }
    }
};

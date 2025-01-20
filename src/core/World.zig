const std = @import("std");
const ray = @import("../raylib.zig");
const perlin = @import("perlin");
const Camera = @import("Camera.zig");

pub const GRID_SIZE: f32 = 100.0; // Size of each grid cell for rendering
pub const PHYSICS_GRID_SIZE: f32 = 25.0; // Fixed size grid cell for physics (smaller for more precise collisions)
pub const GRID_COLOR = ray.Color{ .r = 40, .g = 40, .b = 40, .a = 255 }; // Dark gray grid
pub const BASE_NOISE_SCALE: f32 = 0.001; // Base scale factor for noise coordinates
pub const NOISE_THRESHOLD: f32 = 0.0; // Threshold for filling squares
pub const WALL_THRESHOLD: f32 = 0.3; // Threshold for wall collision
pub const FILL_COLOR = ray.Color{ .r = 30, .g = 30, .b = 50, .a = 255 }; // Dark blue-ish fill

pub const TerrainType = enum {
    Empty,
    Ground,
    Wall,
};

pub const GridCell = struct {
    x: i32,
    y: i32,
};

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

    pub fn update(self: *World) void {
        // Slowly move noise pattern
        self.noise_offset.x += 0.1 * ray.getFrameTime();
        self.noise_offset.y += 0.05 * ray.getFrameTime();
    }

    pub fn toggleGridLines(self: *World) void {
        self.grid_lines_visible = !self.grid_lines_visible;
    }

    // Get the grid cell coordinates for any world position
    pub fn getGridCell(point: ray.Vector2) GridCell {
        return .{
            .x = @as(i32, @intFromFloat(@floor(point.x / GRID_SIZE))),
            .y = @as(i32, @intFromFloat(@floor(point.y / GRID_SIZE))),
        };
    }

    // Get the center point of a grid cell
    pub fn getGridCellCenter(cell: GridCell) ray.Vector2 {
        return .{
            .x = @as(f32, @floatFromInt(cell.x)) * GRID_SIZE + GRID_SIZE * 0.5,
            .y = @as(f32, @floatFromInt(cell.y)) * GRID_SIZE + GRID_SIZE * 0.5,
        };
    }

    fn getNoise(self: *const World, point: ray.Vector2) f32 {
        // Get the grid cell for this point
        const cell = getGridCell(point);
        const center = getGridCellCenter(cell);

        // Scale for noise using the cell center
        const scaled_x = (center.x + self.noise_offset.x) * BASE_NOISE_SCALE;
        const scaled_y = (center.y + self.noise_offset.y) * BASE_NOISE_SCALE;
        return fbm(scaled_x, scaled_y, 0);
    }

    pub fn queryPoint(self: *const World, point: ray.Vector2) TerrainType {
        // Get noise value for this point
        const noise = self.getNoise(point);

        // Determine terrain type based on noise value
        if (noise > WALL_THRESHOLD) {
            return .Wall;
        } else if (noise > NOISE_THRESHOLD) {
            return .Ground;
        } else {
            return .Empty;
        }
    }

    pub fn queryLine(self: *const World, start: ray.Vector2, end: ray.Vector2, radius: f32, steps: u32) TerrainType {
        // Calculate movement direction
        const dx = end.x - start.x;
        const dy = end.y - start.y;
        const length = @sqrt(dx * dx + dy * dy);

        // If no movement, just check the circle at the current position
        if (length < 0.0001) {
            // Check points around the circle
            const check_points: u32 = 8; // Number of points to check around the circle
            for (0..check_points) |i| {
                const angle = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(check_points))) * std.math.tau;
                const check_point = ray.Vector2{
                    .x = start.x + radius * @cos(angle),
                    .y = start.y + radius * @sin(angle),
                };
                const terrain = self.queryPoint(check_point);
                if (terrain == .Wall) {
                    return .Wall;
                }
            }
            return .Empty;
        }

        // Normalize direction
        const dir_x = dx / length;
        const dir_y = dy / length;

        // Calculate perpendicular vector for radius checks
        const perp_x = -dir_y;
        const perp_y = dir_x;

        // Sample points along the line
        const step_size = length / @as(f32, @floatFromInt(steps));
        var highest_terrain: TerrainType = .Empty;

        var i: u32 = 0;
        while (i <= steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) * step_size;
            const center = ray.Vector2{
                .x = start.x + dir_x * t,
                .y = start.y + dir_y * t,
            };

            // Check center point
            const center_terrain = self.queryPoint(center);
            if (center_terrain == .Wall) {
                return .Wall;
            }

            // Check points on either side of the movement path at the entity's radius
            const left = ray.Vector2{
                .x = center.x + perp_x * radius,
                .y = center.y + perp_y * radius,
            };
            const right = ray.Vector2{
                .x = center.x - perp_x * radius,
                .y = center.y - perp_y * radius,
            };

            const left_terrain = self.queryPoint(left);
            const right_terrain = self.queryPoint(right);

            if (left_terrain == .Wall or right_terrain == .Wall) {
                return .Wall;
            }

            // Keep track of highest density terrain found
            if (@intFromEnum(left_terrain) > @intFromEnum(highest_terrain)) {
                highest_terrain = left_terrain;
            }
            if (@intFromEnum(right_terrain) > @intFromEnum(highest_terrain)) {
                highest_terrain = right_terrain;
            }
            if (@intFromEnum(center_terrain) > @intFromEnum(highest_terrain)) {
                highest_terrain = center_terrain;
            }
        }
        return highest_terrain;
    }

    pub fn draw(self: *const World, camera: *const Camera.Camera, window_width: i32, window_height: i32) void {
        // Calculate visible grid bounds based on camera view
        const top_left = camera.screenToWorld(.{ .x = 0, .y = 0 });
        const bottom_right = camera.screenToWorld(.{ .x = @floatFromInt(window_width), .y = @floatFromInt(window_height) });

        // Get grid cells that cover the view
        const start_cell = getGridCell(top_left);
        const end_cell = getGridCell(bottom_right);

        // Draw grid squares
        var cell_y = start_cell.y;
        while (cell_y <= end_cell.y) : (cell_y += 1) {
            var cell_x = start_cell.x;
            while (cell_x <= end_cell.x) : (cell_x += 1) {
                const cell = GridCell{ .x = cell_x, .y = cell_y };
                const cell_center = getGridCellCenter(cell);
                const cell_top_left = ray.Vector2{
                    .x = @as(f32, @floatFromInt(cell_x)) * GRID_SIZE,
                    .y = @as(f32, @floatFromInt(cell_y)) * GRID_SIZE,
                };

                // Get noise value using the shared function
                const noise = self.getNoise(cell_center);

                // If noise is above threshold, fill the square
                if (noise > NOISE_THRESHOLD) {
                    const top_left_screen = camera.worldToScreen(cell_top_left);
                    const bottom_right_screen = camera.worldToScreen(.{
                        .x = cell_top_left.x + GRID_SIZE,
                        .y = cell_top_left.y + GRID_SIZE,
                    });

                    // Use noise value to determine color intensity and whether it's a wall
                    const intensity = @as(u8, @intFromFloat(noise * 255));
                    const color = if (noise > WALL_THRESHOLD)
                        ray.Color{ .r = 60, .g = 60, .b = intensity, .a = 255 } // Brighter for walls
                    else
                        ray.Color{ .r = 30, .g = 30, .b = intensity, .a = 255 }; // Normal ground

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
                    const start_pos_v = camera.worldToScreen(cell_top_left);
                    const end_pos_v = camera.worldToScreen(.{
                        .x = cell_top_left.x,
                        .y = cell_top_left.y + GRID_SIZE,
                    });
                    ray.drawLineEx(.{ .x = start_pos_v.x, .y = start_pos_v.y }, .{ .x = end_pos_v.x, .y = end_pos_v.y }, 1.0, GRID_COLOR);

                    const start_pos_h = camera.worldToScreen(cell_top_left);
                    const end_pos_h = camera.worldToScreen(.{
                        .x = cell_top_left.x + GRID_SIZE,
                        .y = cell_top_left.y,
                    });
                    ray.drawLineEx(.{ .x = start_pos_h.x, .y = start_pos_h.y }, .{ .x = end_pos_h.x, .y = end_pos_h.y }, 1.0, GRID_COLOR);
                }
            }
        }

        // Draw final grid lines if enabled
        if (self.grid_lines_visible) {
            const final_x = @as(f32, @floatFromInt(end_cell.x + 1)) * GRID_SIZE;
            const final_y = @as(f32, @floatFromInt(end_cell.y + 1)) * GRID_SIZE;
            const start_y = @as(f32, @floatFromInt(start_cell.y)) * GRID_SIZE;
            const start_x = @as(f32, @floatFromInt(start_cell.x)) * GRID_SIZE;

            const start_pos = camera.worldToScreen(.{ .x = final_x, .y = start_y });
            const end_pos = camera.worldToScreen(.{ .x = final_x, .y = final_y });
            ray.drawLineEx(.{ .x = start_pos.x, .y = start_pos.y }, .{ .x = end_pos.x, .y = end_pos.y }, 1.0, GRID_COLOR);

            const start_pos_h = camera.worldToScreen(.{ .x = start_x, .y = final_y });
            const end_pos_h = camera.worldToScreen(.{ .x = final_x, .y = final_y });
            ray.drawLineEx(.{ .x = start_pos_h.x, .y = start_pos_h.y }, .{ .x = end_pos_h.x, .y = end_pos_h.y }, 1.0, GRID_COLOR);
        }
    }
};

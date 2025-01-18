const std = @import("std");
const ray = @import("../raylib.zig");
const State = @import("State.zig");
const Entity = @import("Entity.zig");
const ui = @import("./ui/Index.zig");
const Camera = @import("Camera.zig");
const perlin = @import("perlin");

const MIN_CHILD_SCALE = 0.01;
const DEFAULT_CHILD_SCALE = 0.2;
const MAX_CHILD_SCALE = 1.0;

const UI_PADDING = 30;
const GRID_SIZE: f32 = 100.0; // Size of each grid cell
const GRID_COLOR = ray.Color{ .r = 40, .g = 40, .b = 40, .a = 255 }; // Dark gray grid
const NOISE_SCALE: f32 = 0.001; // Scale factor for noise coordinates
const NOISE_THRESHOLD: f32 = 0.1; // Threshold for filling squares
const FILL_COLOR = ray.Color{ .r = 30, .g = 30, .b = 50, .a = 255 }; // Dark blue-ish fill

pub const Renderer = struct {
    window_width: i32,
    window_height: i32,
    player_scale_slider: ui.Slider.Slider,
    child_scale_slider: ui.Slider.Slider,
    child_scale_slider_value: f32,
    ui_visible: bool,
    camera: Camera.Camera,
    noise_offset: ray.Vector2,

    pub fn init() Renderer {
        const window_width = ray.getScreenWidth();
        const window_height = ray.getScreenHeight();
        return .{
            .window_width = window_width,
            .window_height = window_height,
            .player_scale_slider = ui.Slider.Slider.init(1, @as(f32, @floatFromInt(window_width - ui.Slider.WIDTH - UI_PADDING)), UI_PADDING, 0.01, 20.0, 0.01, "Player Scale"),
            .child_scale_slider = ui.Slider.Slider.init(DEFAULT_CHILD_SCALE, @as(f32, @floatFromInt(window_width - ui.Slider.WIDTH - UI_PADDING)), UI_PADDING + ui.Slider.HEIGHT + ui.Slider.HEIGHT + UI_PADDING, MIN_CHILD_SCALE, MAX_CHILD_SCALE, 0.001, "Child Scale"),
            .child_scale_slider_value = DEFAULT_CHILD_SCALE,
            .ui_visible = true,
            .camera = Camera.Camera.init(@floatFromInt(window_width), @floatFromInt(window_height)),
            .noise_offset = .{ .x = 0, .y = 0 },
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.player_scale_slider.deinit();
        self.child_scale_slider.deinit();
    }

    pub fn drawDebugText(game_state: *State.GameState, player: Entity.Entity, active_children: []const usize) !void {
        // Draw UI
        const player_coords = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "player: ({d}, {d})",
            .{ player.position.x, player.position.y },
        );
        defer std.heap.page_allocator.free(player_coords);

        const spawn_text = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "spawning: {any}",
            .{game_state.is_spawning},
        );
        defer std.heap.page_allocator.free(spawn_text);

        const children_text = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "children: {d}",
            .{active_children.len},
        );
        defer std.heap.page_allocator.free(children_text);

        const delete_text = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "deleting: {any}",
            .{game_state.is_deleting},
        );
        defer std.heap.page_allocator.free(delete_text);

        const marking_delete_text = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "marking delete: {any}",
            .{game_state.is_marking_delete},
        );
        defer std.heap.page_allocator.free(marking_delete_text);

        var next_y: i32 = 30;

        ray.drawFPS(10, 10);
        ray.drawText(player_coords.ptr, 10, next_y, 20, ray.WHITE);
        next_y += 20;
        ray.drawText(children_text.ptr, 10, next_y, 20, ray.WHITE);
        next_y += 20;
        ray.drawText(spawn_text.ptr, 10, next_y, 20, ray.WHITE);
        next_y += 20;
        ray.drawText(marking_delete_text.ptr, 10, next_y, 20, ray.WHITE);
        next_y += 20;
        ray.drawText(delete_text.ptr, 10, next_y, 20, ray.WHITE);
        next_y += 20;
        ray.drawText("Controls: Arrow keys to move, hold space to spawn, hold R to delete", 10, next_y, 20, ray.WHITE);
    }

    pub fn renderUI(self: *Renderer, game_state: *State.GameState) !void {
        const player = game_state.entity_manager.getActiveEntity(game_state.player_id).?;
        const active_children = game_state.entity_manager.getActiveChildren(game_state.player_id);

        // Draw debug sliders
        self.player_scale_slider.setValue(player.scale);
        self.player_scale_slider.drawAndUpdate();
        game_state.entity_manager.entities.items(.scale)[game_state.player_id] = self.player_scale_slider.getValue();

        self.child_scale_slider.drawAndUpdate();
        self.child_scale_slider_value = self.child_scale_slider.getValue();
        // Draw debug text
        try drawDebugText(game_state, player, active_children);
    }

    pub fn toggleUI(self: *Renderer) void {
        self.ui_visible = !self.ui_visible;
    }

    pub fn update(self: *Renderer) !void {
        if (ray.isKeyPressed(ray.KeyboardKey.KEY_H)) {
            self.toggleUI();
        }

        self.window_width = ray.getScreenWidth();
        self.window_height = ray.getScreenHeight();
        self.camera.viewport_width = @floatFromInt(self.window_width);
        self.camera.viewport_height = @floatFromInt(self.window_height);

        // Slowly move noise pattern
        self.noise_offset.x += 0.1 * ray.getFrameTime();
        self.noise_offset.y += 0.05 * ray.getFrameTime();

        // Camera zoom controls with mouse wheel
        const wheel_move = ray.getMouseWheelMove();
        if (wheel_move != 0) {
            // Reduced zoom factor for more gradual zooming
            const zoom_factor: f32 = if (wheel_move > 0) 1.05 else 0.95;

            // Get mouse position
            const mouse_pos = ray.getMousePosition();

            // Calculate the point we want to zoom towards in world space
            const before_zoom_world = self.camera.screenToWorld(.{
                .x = mouse_pos.x,
                .y = mouse_pos.y,
            });

            // Apply zoom
            self.camera.zoom *= zoom_factor;
            self.camera.zoom = std.math.clamp(self.camera.zoom, 0.1, 10.0);

            // Calculate where that same point is after zooming
            const after_zoom_world = self.camera.screenToWorld(.{
                .x = mouse_pos.x,
                .y = mouse_pos.y,
            });

            // Adjust camera position to keep the point under the mouse in the same world position
            self.camera.position.x += before_zoom_world.x - after_zoom_world.x;
            self.camera.position.y += before_zoom_world.y - after_zoom_world.y;
        }
    }

    fn drawWorldGrid(self: *const Renderer) void {
        // Calculate visible grid bounds based on camera view
        const top_left = self.camera.screenToWorld(.{ .x = 0, .y = 0 });
        const bottom_right = self.camera.screenToWorld(.{ .x = @floatFromInt(self.window_width), .y = @floatFromInt(self.window_height) });

        // Calculate grid start and end points
        const start_x = @floor(top_left.x / GRID_SIZE) * GRID_SIZE;
        const end_x = @ceil(bottom_right.x / GRID_SIZE) * GRID_SIZE;
        const start_y = @floor(top_left.y / GRID_SIZE) * GRID_SIZE;
        const end_y = @ceil(bottom_right.y / GRID_SIZE) * GRID_SIZE;

        // Draw grid squares with noise
        var y = start_y;
        while (y <= end_y) : (y += GRID_SIZE) {
            var x = start_x;
            while (x <= end_x) : (x += GRID_SIZE) {
                // Get noise value for this grid cell
                const center_x = x + GRID_SIZE * 0.5;
                const center_y = y + GRID_SIZE * 0.5;
                const noise = perlin.noise(f32, .{
                    .x = (center_x + self.noise_offset.x) * NOISE_SCALE,
                    .y = (center_y + self.noise_offset.y) * NOISE_SCALE,
                    .z = 0,
                });

                // If noise is above threshold, fill the square
                if (noise > NOISE_THRESHOLD) {
                    const top_left_screen = self.camera.worldToScreen(.{ .x = x, .y = y });
                    const bottom_right_screen = self.camera.worldToScreen(.{ .x = x + GRID_SIZE, .y = y + GRID_SIZE });

                    ray.drawRectangle(@as(i32, @intFromFloat(top_left_screen.x)), @as(i32, @intFromFloat(top_left_screen.y)), @as(i32, @intFromFloat(bottom_right_screen.x - top_left_screen.x)), @as(i32, @intFromFloat(bottom_right_screen.y - top_left_screen.y)), FILL_COLOR);
                }

                // Draw grid lines
                const start_pos_v = self.camera.worldToScreen(.{ .x = x, .y = y });
                const end_pos_v = self.camera.worldToScreen(.{ .x = x, .y = y + GRID_SIZE });
                ray.drawLineEx(.{ .x = start_pos_v.x, .y = start_pos_v.y }, .{ .x = end_pos_v.x, .y = end_pos_v.y }, 1.0, GRID_COLOR);
            }

            // Draw horizontal lines
            const start_pos_h = self.camera.worldToScreen(.{ .x = start_x, .y = y });
            const end_pos_h = self.camera.worldToScreen(.{ .x = end_x, .y = y });
            ray.drawLineEx(.{ .x = start_pos_h.x, .y = start_pos_h.y }, .{ .x = end_pos_h.x, .y = end_pos_h.y }, 1.0, GRID_COLOR);
        }

        // Draw final vertical lines
        var x = start_x;
        while (x <= end_x) : (x += GRID_SIZE) {
            const start_pos = self.camera.worldToScreen(.{ .x = x, .y = start_y });
            const end_pos = self.camera.worldToScreen(.{ .x = x, .y = end_y });
            ray.drawLineEx(.{ .x = start_pos.x, .y = start_pos.y }, .{ .x = end_pos.x, .y = end_pos.y }, 1.0, GRID_COLOR);
        }
    }

    pub fn render(self: *Renderer, game_state: *State.GameState) !void {
        ray.beginDrawing();
        defer ray.endDrawing();

        ray.clearBackground(ray.BLACK);

        // Update camera to follow player
        self.camera.setTarget(game_state.player_id);
        self.camera.update(&game_state.entity_manager);

        // Draw world grid
        self.drawWorldGrid();

        // Draw player
        if (game_state.entity_manager.getActiveEntity(game_state.player_id)) |player| {
            const screen_pos = self.camera.worldToScreen(player.position);
            const screen_radius = 20 * player.scale * self.camera.zoom;

            if (self.camera.isInView(player.position, 20 * player.scale)) {
                ray.drawCircle(
                    @as(i32, @intFromFloat(screen_pos.x)),
                    @as(i32, @intFromFloat(screen_pos.y)),
                    screen_radius,
                    ray.WHITE,
                );
            }

            // Draw children
            const active_children = game_state.entity_manager.getActiveChildren(game_state.player_id);
            for (active_children) |child_id| {
                const child_pos = game_state.entity_manager.entities.items(.position)[child_id];
                game_state.entity_manager.entities.items(.scale)[child_id] = self.child_scale_slider_value;
                const child_scale = game_state.entity_manager.entities.items(.scale)[child_id];
                const child_radius = 18 * child_scale;

                if (self.camera.isInView(child_pos, child_radius)) {
                    const screen_child_pos = self.camera.worldToScreen(child_pos);
                    const screen_child_radius = child_radius * self.camera.zoom;
                    const color = if (game_state.entity_manager.entities.items(.deleteable)[child_id] > 0) ray.RED else ray.BLUE;

                    ray.drawCircle(
                        @as(i32, @intFromFloat(screen_child_pos.x)),
                        @as(i32, @intFromFloat(screen_child_pos.y)),
                        screen_child_radius,
                        color,
                    );
                }
            }
        }

        if (self.ui_visible) {
            try renderUI(self, game_state);
        }
    }
};

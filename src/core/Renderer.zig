const std = @import("std");
const ray = @import("../raylib.zig");
const State = @import("State.zig");
const Entity = @import("Entity.zig");
const ui = @import("ui/Index.zig");
const Camera = @import("Camera.zig");

const MIN_CHILD_SCALE = 0.01;
const DEFAULT_CHILD_SCALE = 0.2;
const MAX_CHILD_SCALE = 1.0;

const UI_PADDING = 30;

pub const Renderer = struct {
    window_width: i32,
    window_height: i32,
    player_scale_slider: ui.Slider.Slider,
    child_scale_slider: ui.Slider.Slider,
    child_scale_slider_value: f32,
    ui_visible: bool,
    camera: Camera.Camera,

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
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.player_scale_slider.deinit();
        self.child_scale_slider.deinit();
    }

    pub fn toggleUI(self: *Renderer) void {
        self.ui_visible = !self.ui_visible;
    }

    pub fn update(self: *Renderer, game_state: *State.GameState) !void {
        if (ray.isKeyPressed(ray.KeyboardKey.KEY_H)) {
            self.toggleUI();
        }
        if (ray.isKeyPressed(ray.KeyboardKey.KEY_L)) {
            game_state.world.toggleGridLines();
        }

        self.window_width = ray.getScreenWidth();
        self.window_height = ray.getScreenHeight();
        self.camera.viewport_width = @floatFromInt(self.window_width);
        self.camera.viewport_height = @floatFromInt(self.window_height);

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

    pub fn drawDebugText(game_state: *State.GameState, player: Entity.Entity, active_children_len: usize) !void {
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
            .{active_children_len},
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

    pub fn renderUI(game_state: *State.GameState) !void {
        if (game_state.entity_manager.getActiveEntity(game_state.player_id)) |player| {
            const active_children = game_state.entity_manager.getActiveChildren(game_state.player_id);
            defer game_state.allocator.free(active_children);
            // Render player info
            try Renderer.drawDebugText(game_state, player, active_children.len);
        } else {
            ray.drawText("Connecting...", 10, 10, 20, ray.WHITE);
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
        game_state.world.draw(&self.camera, self.window_width, self.window_height);

        // Draw all entities
        const entities = game_state.entity_manager.entities.slice();
        for (entities.items(.position), entities.items(.scale), entities.items(.deleteable), entities.items(.entity_type), 0..) |pos, scale, deleteable, entity_type, id| {
            if (!game_state.entity_manager.isActive(id)) continue;

            const base_radius: f32 = switch (entity_type) {
                .player => 20.0,
                .child => 18.0,
            };
            const screen_radius = base_radius * scale * self.camera.zoom;

            // Only draw if in view
            if (!self.camera.isInView(pos, base_radius * scale)) continue;

            const screen_pos = self.camera.worldToScreen(pos);

            // Determine color based on entity type and state
            const color = switch (entity_type) {
                .player => ray.WHITE,
                .child => if (deleteable > 0) ray.RED else ray.BLUE,
            };

            // For children, use the slider value for scale
            if (entity_type == .child) {
                game_state.entity_manager.entities.items(.scale)[id] = self.child_scale_slider_value;
            }

            ray.drawCircle(
                @as(i32, @intFromFloat(screen_pos.x)),
                @as(i32, @intFromFloat(screen_pos.y)),
                screen_radius,
                color,
            );
        }

        if (self.ui_visible) {
            try renderUI(game_state);
        }
    }
};

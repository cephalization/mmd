const std = @import("std");
const ray = @import("../raylib.zig");
const State = @import("State.zig");
const Entity = @import("Entity.zig");
const ui = @import("./ui/Index.zig");

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

        // TODO: Call ui updates?
    }

    pub fn render(self: *Renderer, game_state: *State.GameState) !void {
        ray.beginDrawing();
        defer ray.endDrawing();

        ray.clearBackground(ray.BLACK);

        // Draw player
        if (game_state.entity_manager.getActiveEntity(game_state.player_id)) |player| {
            ray.drawCircle(
                @as(i32, @intFromFloat(player.position.x)),
                @as(i32, @intFromFloat(player.position.y)),
                20 * player.scale,
                ray.WHITE,
            );

            // Draw children
            const active_children = game_state.entity_manager.getActiveChildren(game_state.player_id);
            for (active_children) |child_id| {
                const child = game_state.entity_manager.entities.items(.position)[child_id];
                game_state.entity_manager.entities.items(.scale)[child_id] = self.child_scale_slider_value;
                const color = if (game_state.entity_manager.entities.items(.deleteable)[child_id] > 0) ray.RED else ray.BLUE;
                ray.drawCircle(
                    @as(i32, @intFromFloat(child.x)),
                    @as(i32, @intFromFloat(child.y)),
                    18 * game_state.entity_manager.entities.items(.scale)[child_id],
                    color,
                );
            }
        }

        if (self.ui_visible) {
            try renderUI(self, game_state);
        }
    }
};

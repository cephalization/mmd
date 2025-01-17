const std = @import("std");
const ray = @import("../raylib.zig");
const State = @import("State.zig");
const Entity = @import("Entity.zig");

pub const Renderer = struct {
    pub fn render(game_state: *State.GameState) !void {
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
                const color = if (game_state.entity_manager.entities.items(.deleteable)[child_id] > 0) ray.RED else ray.BLUE;
                ray.drawCircle(
                    @as(i32, @intFromFloat(child.x)),
                    @as(i32, @intFromFloat(child.y)),
                    18 * game_state.entity_manager.entities.items(.scale)[child_id],
                    color,
                );
            }

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
    }
};

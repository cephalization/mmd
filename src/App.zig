const std = @import("std");
const ray = @import("raylib.zig");
const State = @import("core/State.zig");
const Renderer = @import("core/Renderer.zig");
const network = @import("core/network/Client.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    client: network.GameClient,
    renderer: Renderer.Renderer,

    pub fn init(allocator: std.mem.Allocator, mode: network.GameMode) !App {
        return App{
            .allocator = allocator,
            .client = try network.GameClient.init(allocator, mode),
            .renderer = Renderer.Renderer.init(),
        };
    }

    pub fn deinit(self: *App) void {
        self.client.deinit();
        self.renderer.deinit();
    }

    pub fn connectToServer(self: *App, host: []const u8, port: u16) !void {
        try self.client.connectToServer(host, port);
    }

    pub fn update(self: *App) !void {
        const current_game_time = ray.getTime();
        const delta_time = ray.getFrameTime();
        try self.client.update(delta_time, current_game_time);
        try self.renderer.update();
    }

    pub fn render(self: *App) !void {
        try self.renderer.render(&self.client.game_state);
    }
};

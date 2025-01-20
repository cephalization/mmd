const std = @import("std");
const ray = @import("raylib.zig");
const Network = @import("core/network/Client.zig");
const Renderer = @import("core/Renderer.zig");
const State = @import("core/State.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    client: Network.GameClient,
    renderer: Renderer.Renderer,
    last_frame_time: f64,

    pub fn init(allocator: std.mem.Allocator, mode: Network.GameMode) !App {
        return .{
            .allocator = allocator,
            .client = try Network.GameClient.init(allocator, mode),
            .renderer = Renderer.Renderer.init(),
            .last_frame_time = @as(f64, @floatFromInt(std.time.nanoTimestamp())) / std.time.ns_per_s,
        };
    }

    pub fn deinit(self: *App) void {
        self.client.deinit();
        self.renderer.deinit();
    }

    pub fn update(self: *App) !void {
        const current_time = @as(f64, @floatFromInt(std.time.nanoTimestamp())) / std.time.ns_per_s;
        const delta_time = @as(f32, @floatCast(current_time - self.last_frame_time));
        self.last_frame_time = current_time;

        try self.client.update(delta_time, current_time);
        try self.renderer.update(&self.client.game_state);
        try self.renderer.render(&self.client.game_state);
    }

    pub fn connectToServer(self: *App, host: []const u8, port: u16) !void {
        try self.client.connectToServer(host, port);
    }

    pub fn render(self: *App) !void {
        try self.renderer.render(&self.client.game_state);
    }
};

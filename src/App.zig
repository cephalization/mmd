const std = @import("std");
const ray = @import("raylib.zig");
const State = @import("core/State.zig");
const Renderer = @import("core/Renderer.zig");

const App = @This();

game_state: State.GameState,

pub fn init() !App {
    return App{
        .game_state = try State.GameState.init(),
    };
}

pub fn deinit(self: *App) void {
    self.game_state.deinit();
}

pub fn run(self: *App) !void {
    ray.init(1920, 1080, "mmd");
    ray.setTargetFPS(120);

    while (!ray.shouldClose()) {
        try self.update();
        try Renderer.Renderer.render(&self.game_state);
    }

    ray.close();
}

fn update(self: *App) !void {
    const delta_time = ray.getFrameTime();
    try self.game_state.update(delta_time);
}

const std = @import("std");
const ray = @import("raylib.zig");
const State = @import("core/State.zig");
const Renderer = @import("core/Renderer.zig");

const App = @This();

game_state: State.GameState,
renderer: Renderer.Renderer,

const WINDOW_WIDTH = 1920;
const WINDOW_HEIGHT = 1080;

pub fn init() !App {
    ray.init(WINDOW_WIDTH, WINDOW_HEIGHT, "mmd");
    ray.setTargetFPS(999);
    return App{
        .game_state = try State.GameState.init(),
        .renderer = Renderer.Renderer.init(),
    };
}

pub fn deinit(self: *App) void {
    self.game_state.deinit();
    self.renderer.deinit();
}

pub fn run(self: *App) !void {
    while (!ray.shouldClose()) {
        try self.update();
        try self.renderer.update();
        try self.renderer.render(&self.game_state);
    }

    ray.close();
}

fn update(self: *App) !void {
    const delta_time = ray.getFrameTime();
    try self.game_state.update(delta_time);
}

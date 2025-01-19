const std = @import("std");
const ray = @import("raylib.zig");
const App = @import("App.zig");
const network = @import("core/network/Client.zig");
const Server = @import("core/network/Server.zig");

const WINDOW_WIDTH = 1920;
const WINDOW_HEIGHT = 1080;

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    // Default to singleplayer if no arguments
    var mode = network.GameMode.singleplayer;
    var is_server = false;
    var server_host: ?[]const u8 = null;
    var server_port: u16 = 7777; // Default port

    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--server")) {
            is_server = true;
        } else if (std.mem.eql(u8, arg, "--client")) {
            mode = network.GameMode.multiplayer;
            if (args.next()) |host| {
                server_host = host;
            } else {
                std.debug.print("Error: --client requires a host address\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |port_str| {
                server_port = try std.fmt.parseInt(u16, port_str, 10);
            } else {
                std.debug.print("Error: --port requires a port number\n", .{});
                return;
            }
        }
    }

    if (is_server) {
        std.debug.print("Starting server on port {}\n", .{server_port});
        var server = try Server.GameServer.init(allocator, server_port);
        defer server.deinit();
        try server.start();
    } else {
        // Run as client (either singleplayer or multiplayer)
        ray.init(WINDOW_WIDTH, WINDOW_HEIGHT, "mmd");
        ray.setTargetFPS(999);
        defer ray.close();

        var app = try App.App.init(allocator, mode);
        defer app.deinit();

        // Connect to server if in multiplayer mode
        if (mode == .multiplayer) {
            if (server_host) |host| {
                try app.connectToServer(host, server_port);
                std.debug.print("Connected to server at {s}:{d}\n", .{ host, server_port });
            } else {
                std.debug.print("Error: No server host specified for multiplayer mode\n", .{});
                return;
            }
        }

        // Main game loop
        while (!ray.shouldClose()) {
            try app.update();
            try app.render();
        }
    }
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}

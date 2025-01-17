const std = @import("std");
const App = @import("App.zig");

pub fn main() !void {
    var app = try App.init();
    defer app.deinit();
    try app.run();
}

const std = @import("std");
const State = @import("../State.zig");
const Protocol = @import("Protocol.zig");
const Input = @import("../Input.zig");
const network = @import("network");
const ray = @import("../../raylib.zig");

pub const GameMode = enum {
    singleplayer,
    multiplayer,
};

pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
};

const NetworkThread = struct {
    socket: network.Socket,
    server_endpoint: network.EndPoint,
    allocator: std.mem.Allocator,
    client: *GameClient,
    should_stop: std.atomic.Value(bool),

    fn run(self: *NetworkThread) !void {
        var buf: [4096]u8 = undefined;

        while (!self.should_stop.load(.acquire)) {
            const receive_result = self.socket.receiveFrom(&buf) catch |err| {
                if (err == error.WouldBlock) {
                    std.time.sleep(1 * std.time.ns_per_ms); // Sleep 1ms to avoid busy loop
                    continue;
                }
                std.debug.print("Error receiving message: {}\n", .{err});
                return err;
            };

            if (receive_result.numberOfBytes == 0) continue;

            const message = std.json.parseFromSlice(Protocol.NetworkMessage, self.allocator, buf[0..receive_result.numberOfBytes], .{}) catch |err| {
                std.debug.print("Error parsing message: {}\n", .{err});
                continue;
            };
            defer message.deinit();

            self.client.handleMessage(message.value) catch |err| {
                std.debug.print("Error handling message: {}\n", .{err});
            };
        }
    }
};

pub const GameClient = struct {
    allocator: std.mem.Allocator,
    game_state: State.GameState,
    socket: ?network.Socket,
    server_endpoint: ?network.EndPoint,
    client_id: ?u64,
    player_entity_id: ?usize,
    mode: GameMode,
    last_state_update: f64,
    connection_state: ConnectionState,
    connect_tries: u32,
    last_connect_try: f64,
    network_thread: ?std.Thread = null,
    network_thread_data: ?*NetworkThread = null,

    pub fn init(allocator: std.mem.Allocator, mode: GameMode) !GameClient {
        if (mode == .multiplayer) {
            try network.init();
        }

        return GameClient{
            .allocator = allocator,
            .game_state = try State.GameState.init(allocator, mode == .singleplayer),
            .socket = null,
            .server_endpoint = null,
            .client_id = null,
            .player_entity_id = null,
            .mode = mode,
            .last_state_update = 0,
            .connection_state = .disconnected,
            .connect_tries = 0,
            .last_connect_try = 0,
            .network_thread = null,
            .network_thread_data = null,
        };
    }

    pub fn deinit(self: *GameClient) void {
        if (self.network_thread_data) |thread_data| {
            // Signal thread to stop and wait for it
            thread_data.should_stop.store(true, .release);
            if (self.network_thread) |thread| {
                thread.join();
            }
            // Close socket only once since it's shared
            if (self.socket) |socket| {
                socket.close();
                self.socket = null;
            }
            self.allocator.destroy(thread_data);
            self.network_thread_data = null;
            self.network_thread = null;
        } else if (self.socket) |socket| {
            // Only close if not already closed by thread cleanup
            socket.close();
            self.socket = null;
        }

        // Clear any remaining entities before deinit
        if (self.game_state.entity_manager.entities.len > 0) {
            self.game_state.entity_manager.entities.clearAndFree(self.allocator);
        }

        // Clear any remaining relationships before deinit
        if (self.game_state.entity_manager.relationships.items.len > 0) {
            for (self.game_state.entity_manager.relationships.items) |*rel| {
                rel.children.deinit();
            }
            self.game_state.entity_manager.relationships.clearAndFree();
        }

        if (self.mode == .multiplayer) {
            network.deinit();
        }
        self.game_state.deinit();
    }

    pub fn connectToServer(self: *GameClient, host: []const u8, port: u16) !void {
        if (self.mode != .multiplayer) return error.NotInMultiplayerMode;

        // Create UDP socket
        var socket = try network.Socket.create(.ipv4, .udp);
        errdefer socket.close();

        // Bind to any port
        try socket.bind(.{
            .address = .{ .ipv4 = network.Address.IPv4.any },
            .port = 0,
        });

        // Resolve server address
        const ipv4 = try network.Address.parse(host);
        const server_endpoint = network.EndPoint{
            .address = ipv4,
            .port = port,
        };

        // Create network thread data
        const thread_data = try self.allocator.create(NetworkThread);
        thread_data.* = .{
            .socket = socket,
            .server_endpoint = server_endpoint,
            .allocator = self.allocator,
            .client = self,
            .should_stop = std.atomic.Value(bool).init(false),
        };

        // Start network thread
        self.network_thread = try std.Thread.spawn(.{}, NetworkThread.run, .{thread_data});
        self.network_thread_data = thread_data;

        self.socket = socket;
        self.server_endpoint = server_endpoint;
        self.connection_state = .connecting;
        self.connect_tries = 0;
        self.last_connect_try = 0;

        // Send initial connect request
        const msg = Protocol.NetworkMessage.init(.connect_request);
        try self.sendToServer(msg);
    }

    pub fn update(self: *GameClient, delta_time: f32) !void {
        switch (self.mode) {
            .singleplayer => {
                try self.game_state.update(delta_time);
            },
            .multiplayer => {
                if (self.socket == null) return error.NotConnected;

                // Always update game state
                try self.game_state.update(delta_time);

                // Handle connection state
                switch (self.connection_state) {
                    .connecting => {
                        const current_time = ray.getTime();
                        if (current_time - self.last_connect_try >= 0.1) { // Try every 100ms
                            self.connect_tries += 1;
                            if (self.connect_tries >= 10) {
                                return error.ConnectionTimeout;
                            }

                            // Send connect request
                            const msg = Protocol.NetworkMessage.init(.connect_request);
                            try self.sendToServer(msg);
                            self.last_connect_try = current_time;
                        }
                    },
                    .connected => {
                        // First apply local input events to our state
                        try self.game_state.update(delta_time);

                        // Then send them to server
                        for (self.game_state.input_manager.processEvents()) |event| {
                            if (event.source == .local) {
                                var msg = Protocol.NetworkMessage.init(.input_event);
                                // Set the source player ID to our player entity ID
                                var modified_event = event;
                                modified_event.source_player_id = self.player_entity_id.?;
                                msg.payload.input_event = modified_event;
                                try self.sendToServer(msg);
                            }
                        }
                        // Clear processed events
                        self.game_state.input_manager.clearEvents();
                    },
                    .disconnected => return error.NotConnected,
                }
            },
        }
    }

    fn handleMessage(self: *GameClient, message: Protocol.NetworkMessage) !void {
        std.debug.print("Handling message of type: {}\n", .{message.type});
        switch (message.type) {
            .connect_response => {
                std.debug.print("Received connect response, success: {}\n", .{message.payload.connect_response.success});
                const connect_response = message.payload.connect_response;
                if (!connect_response.success) return error.ConnectionFailed;

                self.client_id = connect_response.client_id;
                self.player_entity_id = connect_response.player_entity_id;
                self.game_state.player_id = connect_response.player_entity_id;
                self.connection_state = .connected;
                std.debug.print("Connection successful! Client ID: {}, Player Entity ID: {}\n", .{ self.client_id.?, self.player_entity_id.? });
            },

            .state_update => {
                std.debug.print("Received state update with {} entities\n", .{message.payload.state_update.entities.len});
                const state_update = message.payload.state_update;

                // Ensure we have enough capacity for all entities
                while (self.game_state.entity_manager.entities.len < state_update.entities.len) {
                    try self.game_state.entity_manager.entities.append(self.allocator, .{
                        .position = .{ .x = 0, .y = 0 },
                        .scale = 1.0,
                        .deleteable = 0,
                        .entity_type = .player,
                    });
                }

                // Update entity positions and properties
                for (state_update.entities, 0..) |entity, i| {
                    if (i >= self.game_state.entity_manager.entities.len) break;

                    // Skip updating our own player's position to avoid overwriting local state
                    if (self.player_entity_id) |player_id| {
                        if (i == player_id) continue;
                    }

                    // Update entity properties
                    self.game_state.entity_manager.entities.items(.position)[i] = .{ .x = entity.position.x, .y = entity.position.y };
                    self.game_state.entity_manager.entities.items(.scale)[i] = entity.scale;
                    self.game_state.entity_manager.entities.items(.deleteable)[i] = entity.deleteable;
                    self.game_state.entity_manager.entities.items(.entity_type)[i] = entity.entity_type;
                }

                // Update relationships
                self.game_state.entity_manager.relationships.clearRetainingCapacity();
                for (state_update.relationships) |relationship| {
                    var new_rel = try self.game_state.entity_manager.relationships.addOne();
                    new_rel.* = .{
                        .parent_id = relationship.parent_id,
                        .children = std.ArrayList(usize).init(self.allocator),
                        .allocator = self.allocator,
                    };
                    try new_rel.children.appendSlice(relationship.children);
                }

                // Update player ID if we have one and the entity exists
                if (self.player_entity_id) |id| {
                    if (id < self.game_state.entity_manager.entities.len) {
                        self.game_state.player_id = id;
                        self.game_state.input_manager.player_id = id;
                    }
                }

                self.last_state_update = state_update.timestamp;
            },

            .player_joined => {
                const player = message.payload.player_joined;
                // Create a new player entity with the received ID
                const window_width = ray.getScreenWidth();
                const window_height = ray.getScreenHeight();
                const center_x = @divTrunc(@as(f32, @floatFromInt(window_width)), 2);
                const center_y = @divTrunc(@as(f32, @floatFromInt(window_height)), 2);

                // Ensure we have enough capacity for the new player's ID
                while (self.game_state.entity_manager.entities.len <= player.player_entity_id) {
                    try self.game_state.entity_manager.entities.append(self.allocator, .{
                        .position = .{ .x = center_x, .y = center_y },
                        .scale = 1.0,
                        .deleteable = 0,
                        .entity_type = .player,
                    });
                }
            },

            .player_left => {
                const player = message.payload.player_left;
                // Remove the player's entity from the game state
                if (player.player_entity_id < self.game_state.entity_manager.entities.len) {
                    self.game_state.entity_manager.deleteEntity(player.player_entity_id);
                }
            },

            else => {}, // Ignore other message types that should only go server -> client
        }
    }

    fn sendToServer(self: *GameClient, message: Protocol.NetworkMessage) !void {
        if (self.socket == null or self.server_endpoint == null) return error.NotConnected;

        const json = try std.json.stringifyAlloc(self.allocator, message, .{});
        defer self.allocator.free(json);

        _ = try self.socket.?.sendTo(self.server_endpoint.?, json);
    }
};

const std = @import("std");
const State = @import("../State.zig");
const Protocol = @import("Protocol.zig");
const Input = @import("../Input.zig");
const network = @import("network");

const Client = struct {
    id: u64,
    player_entity_id: usize,
    last_input_time: f64,
    addr: network.EndPoint,
};

const NetworkThread = struct {
    socket: network.Socket,
    allocator: std.mem.Allocator,
    server: *GameServer,
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

            self.server.handleMessage(message.value, receive_result.sender) catch |err| {
                std.debug.print("Error handling message: {}\n", .{err});
            };
        }
    }
};

pub const GameServer = struct {
    allocator: std.mem.Allocator,
    game_state: State.GameState,
    clients: std.AutoHashMap(u64, Client),
    socket: network.Socket,
    next_client_id: u64,
    last_state_update: i128,
    state_update_rate: i128, // How often to send state updates (in nanoseconds)
    network_thread: ?std.Thread = null,
    network_thread_data: ?*NetworkThread = null,

    pub fn init(allocator: std.mem.Allocator, port: u16) !*GameServer {
        try network.init();
        errdefer network.deinit();

        // Create UDP socket and bind to port
        var socket = try network.Socket.create(.ipv4, .udp);
        errdefer socket.close();

        try socket.bindToPort(port);

        // Allocate server on heap
        var server = try allocator.create(GameServer);
        errdefer allocator.destroy(server);

        server.* = GameServer{
            .allocator = allocator,
            .game_state = try State.GameState.init(allocator, false),
            .clients = std.AutoHashMap(u64, Client).init(allocator),
            .socket = socket,
            .next_client_id = 1,
            .last_state_update = std.time.nanoTimestamp(),
            .state_update_rate = std.time.ns_per_s / 60, // 60 Hz state updates
            .network_thread = null,
            .network_thread_data = null,
        };

        // Create network thread data
        const thread_data = try allocator.create(NetworkThread);
        thread_data.* = .{
            .socket = socket,
            .allocator = allocator,
            .server = server,
            .should_stop = std.atomic.Value(bool).init(false),
        };

        // Start network thread
        server.network_thread = try std.Thread.spawn(.{}, NetworkThread.run, .{thread_data});
        server.network_thread_data = thread_data;

        return server;
    }

    pub fn deinit(self: *GameServer) void {
        if (self.network_thread_data) |thread_data| {
            // Signal thread to stop and wait for it
            thread_data.should_stop.store(true, .release);
            if (self.network_thread) |thread| {
                thread.join();
            }
            thread_data.socket.close();
            self.allocator.destroy(thread_data);
            self.network_thread_data = null;
            self.network_thread = null;
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

        self.clients.deinit();
        self.game_state.deinit();
        network.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *GameServer) !void {
        std.debug.print("Server starting main loop\n", .{});

        var last_frame_time = std.time.nanoTimestamp();
        const target_frame_time: i128 = std.time.ns_per_s / 60; // Target 60 FPS

        while (true) {
            const current_time = std.time.nanoTimestamp();
            const frame_time = current_time - last_frame_time;
            last_frame_time = current_time;

            // Send state updates if needed
            const time_since_last_update = current_time - self.last_state_update;
            if (time_since_last_update >= self.state_update_rate) {
                try self.broadcastGameState();
                self.last_state_update = current_time;
            }

            // Update game state
            try self.game_state.update(@as(f32, @floatFromInt(frame_time)) / std.time.ns_per_s);

            // Sleep for remaining frame time
            const elapsed = std.time.nanoTimestamp() - current_time;
            if (elapsed < target_frame_time) {
                std.time.sleep(@intCast(target_frame_time - elapsed));
            }
        }
    }

    fn handleMessage(self: *GameServer, message: Protocol.NetworkMessage, sender: network.EndPoint) !void {
        std.debug.print("Server handling message of type: {}\n", .{message.type});
        switch (message.type) {
            .connect_request => {
                std.debug.print("Received connect request from {}\n", .{sender});
                const client_id = self.next_client_id;
                self.next_client_id += 1;

                // Create a new player entity
                const player_entity_id = try self.game_state.createPlayerEntity();

                // Store client info
                try self.clients.put(client_id, .{
                    .id = client_id,
                    .player_entity_id = player_entity_id,
                    .last_input_time = 0,
                    .addr = sender,
                });

                // std.debug.print("Created new client with ID: {}, player entity ID: {}\n", .{ client_id, player_entity_id });

                // Send connect response
                var response = Protocol.NetworkMessage.init(.connect_response);
                response.payload.connect_response = .{
                    .success = true,
                    .client_id = client_id,
                    .player_entity_id = player_entity_id,
                };

                try self.sendTo(sender, response);
                std.debug.print("Sent connect response to client\n", .{});

                // Notify other clients
                var join_msg = Protocol.NetworkMessage.init(.player_joined);
                join_msg.payload.player_joined = .{
                    .client_id = client_id,
                    .player_entity_id = player_entity_id,
                };
                try self.broadcast(join_msg, client_id);
            },

            .disconnect => {
                if (message.payload.connect_request.client_id) |client_id| {
                    if (self.clients.get(client_id)) |client| {
                        // Remove player entity
                        self.game_state.entity_manager.deleteEntity(client.player_entity_id);

                        // Remove client
                        _ = self.clients.remove(client_id);

                        // Notify other clients
                        var leave_msg = Protocol.NetworkMessage.init(.player_left);
                        leave_msg.payload.player_left = .{
                            .client_id = client_id,
                            .player_entity_id = client.player_entity_id,
                        };
                        try self.broadcast(leave_msg, client_id);
                    }
                }
            },

            .input_event => {
                // Process input events from clients
                const input_event = message.payload.input_event;
                // Convert local events from clients to remote events for processing
                var modified_event = input_event;
                modified_event.source = .remote;
                try self.game_state.input_manager.addRemoteInput(modified_event);
            },

            else => {}, // Ignore other message types that should only go client -> server
        }
    }

    fn broadcastGameState(self: *GameServer) !void {
        // std.debug.print("Starting to broadcast game state\n", .{});
        var state_msg = Protocol.NetworkMessage.init(.state_update);

        // Convert entities to network format
        var network_entities = std.ArrayList(Protocol.NetworkEntity).init(self.allocator);
        defer network_entities.deinit();

        // Ensure we have enough capacity for all entities
        try network_entities.ensureTotalCapacity(self.game_state.entity_manager.entities.len);

        const entities = self.game_state.entity_manager.entities.slice();
        // std.debug.print("Converting {} entities to network format\n", .{entities.len});
        for (entities.items(.position), entities.items(.scale), entities.items(.deleteable), entities.items(.entity_type), 0..entities.len) |pos, scale, deleteable, entity_type, id| {
            try network_entities.append(.{
                .id = id,
                .position = .{ .x = pos.x, .y = pos.y },
                .scale = scale,
                .deleteable = deleteable,
                .entity_type = entity_type,
            });
        }

        // Convert relationships to network format
        var network_relationships = std.ArrayList(Protocol.NetworkRelationship).init(self.allocator);
        defer network_relationships.deinit();

        // Ensure we have enough capacity for all relationships
        try network_relationships.ensureTotalCapacity(self.game_state.entity_manager.relationships.items.len);

        // std.debug.print("Converting {} relationships to network format\n", .{self.game_state.entity_manager.relationships.items.len});
        for (self.game_state.entity_manager.relationships.items) |rel| {
            try network_relationships.append(.{
                .parent_id = rel.parent_id,
                .children = try self.allocator.dupe(usize, rel.children.items),
            });
        }

        // Create state update
        state_msg.payload.state_update = .{
            .timestamp = @as(f64, @floatFromInt(std.time.nanoTimestamp())),
            .entities = try self.allocator.dupe(Protocol.NetworkEntity, network_entities.items),
            .relationships = try self.allocator.dupe(Protocol.NetworkRelationship, network_relationships.items),
        };

        // Verify all player entities exist before sending
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            const client = entry.value_ptr.*;
            if (client.player_entity_id >= network_entities.items.len) {
                std.debug.print("Warning: Client {} has invalid player entity ID {}\n", .{ client.id, client.player_entity_id });
                continue;
            }
        }

        // std.debug.print("Broadcasting state update to {} clients\n", .{self.clients.count()});
        try self.broadcast(state_msg, null);

        // Clean up allocated memory
        self.allocator.free(state_msg.payload.state_update.entities);
        for (state_msg.payload.state_update.relationships) |rel| {
            self.allocator.free(rel.children);
        }
        self.allocator.free(state_msg.payload.state_update.relationships);
        // std.debug.print("Finished broadcasting game state\n", .{});
    }

    fn broadcast(self: *GameServer, message: Protocol.NetworkMessage, exclude_client: ?u64) !void {
        var it = self.clients.iterator();
        var clients_sent: usize = 0;
        while (it.next()) |entry| {
            if (exclude_client != null and entry.key_ptr.* == exclude_client.?) {
                continue;
            }
            try self.sendTo(entry.value_ptr.*.addr, message);
            clients_sent += 1;
        }
        // std.debug.print("Sent message to {} clients\n", .{clients_sent});
    }

    fn sendTo(self: *GameServer, endpoint: network.EndPoint, message: Protocol.NetworkMessage) !void {
        const json = try std.json.stringifyAlloc(self.allocator, message, .{});
        defer self.allocator.free(json);

        // std.debug.print("Sending {} bytes to {}\n", .{ json.len, endpoint });
        _ = try self.socket.sendTo(endpoint, json);
    }
};

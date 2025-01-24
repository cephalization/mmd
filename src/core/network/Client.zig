const std = @import("std");
const State = @import("../State.zig");
const Protocol = @import("Protocol.zig");
const Input = @import("../Input.zig");
const network = @import("network");
const ray = @import("../../raylib.zig");
const Constants = @import("Constants.zig");

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
        var buf: [Constants.MAX_PACKET_SIZE]u8 = undefined;
        var messages_per_second: u32 = 0;
        var last_time: f64 = 0;
        var delta_accumulator: f64 = 0;
        while (!self.should_stop.load(.acquire)) {
            const current_time = ray.getTime();
            const delta_time = current_time - last_time;
            last_time = current_time;
            delta_accumulator += delta_time;
            // std.debug.print("Network thread waiting for message\n", .{});
            const receive_result = self.socket.receiveFrom(&buf) catch |err| {
                if (err == error.WouldBlock) {
                    std.time.sleep(1 * std.time.ns_per_ms); // Sleep 1ms to avoid busy loop
                    continue;
                }
                std.debug.print("Error receiving message: {}\n", .{err});
                return err;
            };

            if (self.should_stop.load(.acquire)) {
                std.debug.print("Network thread received should_stop signal\n", .{});
                break;
            }

            // std.debug.print("Received message\n", .{});

            if (receive_result.numberOfBytes == 0) continue;

            const message = std.json.parseFromSlice(Protocol.NetworkMessage, self.allocator, buf[0..receive_result.numberOfBytes], .{}) catch |err| {
                std.debug.print("Error parsing message: {}\n", .{err});
                continue;
            };
            defer message.deinit();

            // std.debug.print("Received message type {}\n", .{message.value.type});

            self.client.handleMessage(message.value) catch |err| {
                std.debug.print("Error handling message: {}\n", .{err});
            };

            if (delta_accumulator >= 5.0) {
                std.debug.print("Messages received over last 5 seconds: {}\n", .{messages_per_second});
                messages_per_second = 0;
                delta_accumulator = 0;
            } else {
                messages_per_second += 1;
            }
        }
        std.debug.print("Network thread stopped\n", .{});
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
    last_state_update: f64 = 0,
    connection_state: ConnectionState,
    connect_tries: u32,
    last_connect_try: f64,
    network_thread: ?std.Thread = null,
    network_thread_data: ?*NetworkThread = null,
    last_input_time: f64 = 0,
    mutex: std.Thread.Mutex = .{},
    last_snapshot: ?Protocol.StateSnapshot = null,
    last_sequence_received: u32 = 0,
    interpolation_buffer: std.ArrayList(Protocol.StateSnapshot),
    interpolation_delay: f64 = 0.1, // 100ms interpolation delay
    render_time: f64 = 0,
    pending_snapshot_chunks: std.AutoHashMap(u32, Protocol.StateSnapshotChunk),
    pending_delta_chunks: std.AutoHashMap(u32, Protocol.StateDeltaChunk),

    pub fn init(allocator: std.mem.Allocator, mode: GameMode) !GameClient {
        if (mode == .multiplayer) {
            try network.init();
        }

        var game_state = try State.GameState.init(allocator, mode == .singleplayer);
        if (mode == .multiplayer) {
            game_state.is_client_mode = true;
        }

        const client = GameClient{
            .allocator = allocator,
            .game_state = game_state,
            .socket = null,
            .server_endpoint = null,
            .client_id = null,
            .player_entity_id = null,
            .mode = mode,
            .connection_state = .disconnected,
            .connect_tries = 0,
            .last_connect_try = 0,
            .network_thread = null,
            .network_thread_data = null,
            .last_snapshot = null,
            .last_sequence_received = 0,
            .interpolation_buffer = std.ArrayList(Protocol.StateSnapshot).init(allocator),
            .render_time = 0,
            .pending_snapshot_chunks = std.AutoHashMap(u32, Protocol.StateSnapshotChunk).init(allocator),
            .pending_delta_chunks = std.AutoHashMap(u32, Protocol.StateDeltaChunk).init(allocator),
        };
        return client;
    }

    pub fn deinit(self: *GameClient) void {
        std.debug.print("Deinitializing GameClient\n", .{});
        // First stop the network thread if it exists
        if (self.network_thread_data) |thread_data| {
            thread_data.should_stop.store(true, .release);
        }
        std.debug.print("Network thread data updated with should_stop\n", .{});

        // Unblock the network thread

        // Try to send disconnect message if connected
        if (self.mode == .multiplayer and self.connection_state == .connected) {
            var msg = Protocol.NetworkMessage.init(.disconnect);
            msg.payload.disconnect.client_id = self.client_id;
            self.sendToServer(msg) catch |err| {
                std.debug.print("Error sending disconnect message: {}\n", .{err});
            };
        }
        std.debug.print("Disconnect message sent\n", .{});

        // Wait for network thread
        std.debug.print("Waiting for network thread to join\n", .{});
        if (self.network_thread) |thread| {
            thread.join();
        }
        std.debug.print("Network thread joined\n", .{});

        // Cleanup network resources, this should let the network thread proceed
        if (self.socket) |socket| {
            socket.close();
            self.socket = null;
        }
        std.debug.print("Socket closed\n", .{});

        if (self.network_thread_data) |thread_data| {
            self.allocator.destroy(thread_data);
            self.network_thread_data = null;
            self.network_thread = null;
        }
        std.debug.print("Network thread data destroyed\n", .{});

        // Clear any remaining entities before deinit
        if (self.game_state.entity_manager.entities.len > 0) {
            self.game_state.entity_manager.entities.clearAndFree(self.allocator);
        }
        std.debug.print("Entities cleared\n", .{});

        if (self.mode == .multiplayer) {
            network.deinit();
        }
        std.debug.print("Network deinitialized\n", .{});

        self.game_state.deinit();
        std.debug.print("GameState deinitialized\n", .{});

        // Clean up any pending chunks and their allocated memory
        {
            var it = self.pending_delta_chunks.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.*.deltas);
            }
            self.pending_delta_chunks.deinit();

            var snapshot_it = self.pending_snapshot_chunks.iterator();
            while (snapshot_it.next()) |entry| {
                self.allocator.free(entry.value_ptr.*.entities);
            }
            self.pending_snapshot_chunks.deinit();
        }

        if (self.last_snapshot) |snapshot| {
            self.allocator.free(snapshot.entities);
        }
        for (self.interpolation_buffer.items) |snapshot| {
            self.allocator.free(snapshot.entities);
        }
        self.interpolation_buffer.deinit();
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

    pub fn update(self: *GameClient, delta_time: f32, current_game_time: f64) !void {
        switch (self.mode) {
            .singleplayer => {
                try self.game_state.update(current_game_time, delta_time);
                try self.game_state.processStateEvents(delta_time, current_game_time);
            },
            .multiplayer => {
                if (self.socket == null) return error.NotConnected;

                // Handle connection state
                switch (self.connection_state) {
                    .connecting => {
                        const current_time = ray.getTime();
                        if (current_time - self.last_connect_try >= 10.0) { // Try every 10 seconds
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
                        // Update render time for interpolation
                        self.render_time = current_game_time - self.interpolation_delay;

                        // Interpolate entity positions
                        if (self.interpolation_buffer.items.len >= 2) {
                            var i: usize = 0;
                            while (i < self.interpolation_buffer.items.len - 1) : (i += 1) {
                                const from = self.interpolation_buffer.items[i];
                                const to = self.interpolation_buffer.items[i + 1];

                                if (from.timestamp <= self.render_time and to.timestamp > self.render_time) {
                                    const alpha = (self.render_time - from.timestamp) / (to.timestamp - from.timestamp);
                                    try self.interpolateStates(from, to, alpha);
                                    break;
                                }
                            }

                            // Remove old snapshots
                            while (self.interpolation_buffer.items.len > 0 and
                                self.interpolation_buffer.items[0].timestamp < self.render_time - self.interpolation_delay * 2)
                            {
                                const old = self.interpolation_buffer.orderedRemove(0);
                                self.allocator.free(old.entities);
                            }
                        }

                        // Process input events
                        try self.game_state.input_manager.pollLocalInput();
                        const pending_events = self.game_state.input_manager.processEvents();
                        const current_time = ray.getTime();

                        // Send input events to server
                        for (pending_events) |event| {
                            if (event.source == .local) {
                                var msg = Protocol.NetworkMessage.init(.input_event);
                                var modified_event = event;
                                modified_event.source_player_id = self.player_entity_id.?;
                                msg.payload.input_event = modified_event;
                                try self.sendToServer(msg);
                                self.last_input_time = current_time;
                            }
                        }

                        self.game_state.input_manager.clearEvents();
                    },
                    .disconnected => return error.NotConnected,
                }
            },
        }
    }

    fn interpolateStates(self: *GameClient, from: Protocol.StateSnapshot, to: Protocol.StateSnapshot, alpha: f64) !void {
        // Create a map of entity IDs to their indices for quick lookup
        var to_indices = std.AutoHashMap(usize, usize).init(self.allocator);
        defer to_indices.deinit();

        for (to.entities, 0..) |entity, i| {
            try to_indices.put(entity.id, i);
        }

        // Interpolate each entity from the 'from' state
        for (from.entities) |from_entity| {
            if (to_indices.get(from_entity.id)) |to_idx| {
                const to_entity = to.entities[to_idx];
                const entity_id = from_entity.id;

                // Ensure we have capacity
                while (self.game_state.entity_manager.entities.len <= entity_id) {
                    try self.game_state.entity_manager.entities.append(self.allocator, .{
                        .position = .{ .x = from_entity.position.x, .y = from_entity.position.y },
                        .scale = from_entity.scale,
                        .deleteable = from_entity.deleteable,
                        .entity_type = from_entity.entity_type,
                        .active = from_entity.active,
                        .parent_id = from_entity.parent_id,
                    });
                }

                // Interpolate position
                const lerped_x = from_entity.position.x + @as(f32, @floatCast(alpha)) * (to_entity.position.x - from_entity.position.x);
                const lerped_y = from_entity.position.y + @as(f32, @floatCast(alpha)) * (to_entity.position.y - from_entity.position.y);
                self.game_state.entity_manager.entities.items(.position)[entity_id] = ray.Vector2{ .x = lerped_x, .y = lerped_y };

                // Interpolate scale
                const lerped_scale = from_entity.scale + @as(f32, @floatCast(alpha)) * (to_entity.scale - from_entity.scale);
                self.game_state.entity_manager.entities.items(.scale)[entity_id] = lerped_scale;

                // Other properties are discrete, no interpolation needed
                self.game_state.entity_manager.entities.items(.deleteable)[entity_id] = to_entity.deleteable;
                self.game_state.entity_manager.entities.items(.entity_type)[entity_id] = to_entity.entity_type;
                self.game_state.entity_manager.entities.items(.active)[entity_id] = to_entity.active;
                self.game_state.entity_manager.entities.items(.parent_id)[entity_id] = to_entity.parent_id;
            }
        }
    }

    fn handleMessage(self: *GameClient, message: Protocol.NetworkMessage) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        switch (message.type) {
            .connect_response => {
                std.debug.print("Received connect response, success: {}\n", .{message.payload.connect_response.success});
                const connect_response = message.payload.connect_response;
                if (!connect_response.success) return error.ConnectionFailed;

                self.client_id = connect_response.client_id;
                self.player_entity_id = connect_response.player_entity_id;
                self.game_state.player_id = connect_response.player_entity_id;
                self.game_state.input_manager.player_id = connect_response.player_entity_id;
                self.connection_state = .connected;
                std.debug.print("Connection successful! Client ID: {}, Player Entity ID: {}\n", .{ self.client_id.?, self.player_entity_id.? });
            },

            .initial_state_chunk => {
                const chunk = message.payload.initial_state_chunk;
                std.debug.print("Received initial state chunk {}/{} with {} entities\n", .{ chunk.chunk_id + 1, chunk.total_chunks, chunk.entities.len });

                // Process entities in this chunk
                for (chunk.entities) |entity| {
                    // Ensure we have enough capacity
                    while (self.game_state.entity_manager.entities.len <= entity.id) {
                        try self.game_state.entity_manager.entities.append(self.allocator, .{
                            .position = .{ .x = entity.position.x, .y = entity.position.y },
                            .scale = entity.scale,
                            .deleteable = entity.deleteable,
                            .entity_type = entity.entity_type,
                            .active = entity.active,
                            .parent_id = entity.parent_id,
                        });
                    }

                    // Update entity data
                    self.game_state.entity_manager.entities.items(.position)[entity.id] = .{ .x = entity.position.x, .y = entity.position.y };
                    self.game_state.entity_manager.entities.items(.scale)[entity.id] = entity.scale;
                    self.game_state.entity_manager.entities.items(.deleteable)[entity.id] = entity.deleteable;
                    self.game_state.entity_manager.entities.items(.entity_type)[entity.id] = entity.entity_type;
                    self.game_state.entity_manager.entities.items(.active)[entity.id] = entity.active;
                    self.game_state.entity_manager.entities.items(.parent_id)[entity.id] = entity.parent_id;
                }

                // Send acknowledgment
                var ack_msg = Protocol.NetworkMessage.init(.initial_state_ack);
                ack_msg.payload.initial_state_ack = .{
                    .chunk_id = chunk.chunk_id,
                };
                try self.sendToServer(ack_msg);
            },

            .entity_created => {
                const entity = message.payload.entity_created.entity;
                // Ensure we have enough capacity
                while (self.game_state.entity_manager.entities.len <= entity.id) {
                    try self.game_state.entity_manager.entities.append(self.allocator, .{
                        .position = .{ .x = entity.position.x, .y = entity.position.y },
                        .scale = entity.scale,
                        .deleteable = entity.deleteable,
                        .entity_type = entity.entity_type,
                        .active = entity.active,
                        .parent_id = entity.parent_id,
                    });
                }
            },

            .entity_updated => {
                const entity_update = message.payload.entity_updated;
                if (entity_update.id >= self.game_state.entity_manager.entities.len) return;

                if (entity_update.position) |pos| {
                    self.game_state.entity_manager.entities.items(.position)[entity_update.id] = .{ .x = pos.x, .y = pos.y };
                }
                if (entity_update.scale) |scale| {
                    self.game_state.entity_manager.entities.items(.scale)[entity_update.id] = scale;
                }
                if (entity_update.deleteable) |deleteable| {
                    self.game_state.entity_manager.entities.items(.deleteable)[entity_update.id] = deleteable;
                }
                if (entity_update.entity_type) |entity_type| {
                    self.game_state.entity_manager.entities.items(.entity_type)[entity_update.id] = entity_type;
                }
                if (entity_update.active) |active| {
                    self.game_state.entity_manager.entities.items(.active)[entity_update.id] = active;
                }
                if (entity_update.parent_id) |parent_id| {
                    self.game_state.entity_manager.entities.items(.parent_id)[entity_update.id] = parent_id;
                }
            },

            .entity_deleted => {
                const entity_id = message.payload.entity_deleted.id;
                if (entity_id < self.game_state.entity_manager.entities.len) {
                    self.game_state.entity_manager.deleteEntity(entity_id);
                }
            },

            .player_joined => {
                const player = message.payload.player_joined;
                // Create a new player entity with the received ID
                const window_width = ray.getScreenWidth();
                const window_height = ray.getScreenHeight();
                const center_x = @as(f32, @floatFromInt(window_width)) / 2.0;
                const center_y = @as(f32, @floatFromInt(window_height)) / 2.0;

                // Ensure we have enough capacity for the new player's ID
                while (self.game_state.entity_manager.entities.len <= player.player_entity_id) {
                    try self.game_state.entity_manager.entities.append(self.allocator, .{
                        .position = .{ .x = center_x, .y = center_y },
                        .scale = 1.0,
                        .deleteable = 0,
                        .entity_type = .player,
                        .active = true,
                        .parent_id = null,
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

            .batched_updates => {
                const batch = message.payload.batched_updates;

                // Handle created entities
                for (batch.created) |create| {
                    const entity = create.entity;
                    // Ensure we have enough capacity
                    while (self.game_state.entity_manager.entities.len <= entity.id) {
                        try self.game_state.entity_manager.entities.append(self.allocator, .{
                            .position = .{ .x = entity.position.x, .y = entity.position.y },
                            .scale = entity.scale,
                            .deleteable = entity.deleteable,
                            .entity_type = entity.entity_type,
                            .active = entity.active,
                            .parent_id = entity.parent_id,
                        });
                    }
                }

                // Handle updated entities
                for (batch.updates) |entity_update| {
                    if (entity_update.id >= self.game_state.entity_manager.entities.len) continue;

                    if (entity_update.position) |pos| {
                        self.game_state.entity_manager.entities.items(.position)[entity_update.id] = .{ .x = pos.x, .y = pos.y };
                    }
                    if (entity_update.scale) |scale| {
                        self.game_state.entity_manager.entities.items(.scale)[entity_update.id] = scale;
                    }
                    if (entity_update.deleteable) |deleteable| {
                        self.game_state.entity_manager.entities.items(.deleteable)[entity_update.id] = deleteable;
                    }
                    if (entity_update.entity_type) |entity_type| {
                        self.game_state.entity_manager.entities.items(.entity_type)[entity_update.id] = entity_type;
                    }
                    if (entity_update.active) |active| {
                        self.game_state.entity_manager.entities.items(.active)[entity_update.id] = active;
                    }
                    if (entity_update.parent_id) |parent_id| {
                        self.game_state.entity_manager.entities.items(.parent_id)[entity_update.id] = parent_id;
                    }
                }

                // Handle deleted entities
                for (batch.deleted) |delete| {
                    if (delete.id < self.game_state.entity_manager.entities.len) {
                        self.game_state.entity_manager.deleteEntity(delete.id);
                    }
                }
            },

            .state_snapshot => {
                const snapshot = message.payload.state_snapshot;
                if (snapshot.sequence <= self.last_sequence_received) return;

                // Store snapshot for interpolation
                const snapshot_copy = Protocol.StateSnapshot{
                    .sequence = snapshot.sequence,
                    .timestamp = snapshot.timestamp,
                    .entities = try self.allocator.dupe(Protocol.NetworkEntity, snapshot.entities),
                };

                // Insert snapshot in order
                var insert_idx: usize = self.interpolation_buffer.items.len;
                for (self.interpolation_buffer.items, 0..) |buf_snapshot, i| {
                    if (buf_snapshot.timestamp > snapshot.timestamp) {
                        insert_idx = i;
                        break;
                    }
                }
                try self.interpolation_buffer.insert(insert_idx, snapshot_copy);

                self.last_sequence_received = snapshot.sequence;
            },

            .state_delta => {
                const delta = message.payload.state_delta;
                if (delta.sequence <= self.last_sequence_received) return;

                // Find the base snapshot
                var base_snapshot: ?Protocol.StateSnapshot = null;
                for (self.interpolation_buffer.items) |snapshot| {
                    if (snapshot.sequence == delta.base_sequence) {
                        base_snapshot = snapshot;
                        break;
                    }
                }
                if (base_snapshot == null) return; // Can't apply delta without base

                // Create new snapshot from base + delta
                var new_entities = std.ArrayList(Protocol.NetworkEntity).init(self.allocator);
                defer new_entities.deinit();

                // Copy base entities
                try new_entities.appendSlice(base_snapshot.?.entities);

                // Apply deltas
                for (delta.deltas) |entity_delta| {
                    var found = false;
                    for (new_entities.items) |*entity| {
                        if (entity.id == entity_delta.id) {
                            found = true;
                            if (entity_delta.position_delta) |pos| {
                                entity.position = .{ .x = pos.x, .y = pos.y };
                            }
                            if (entity_delta.scale_delta) |scale| {
                                entity.scale = scale;
                            }
                            if (entity_delta.deleteable_delta) |deleteable| {
                                entity.deleteable = deleteable;
                            }
                            if (entity_delta.entity_type_changed) |entity_type| {
                                entity.entity_type = entity_type;
                            }
                            if (entity_delta.active_changed) |active| {
                                entity.active = active;
                            }
                            if (entity_delta.parent_id_changed) |parent_id| {
                                entity.parent_id = parent_id;
                            }
                            break;
                        }
                    }

                    if (!found) {
                        // New entity - ensure all required fields are present
                        if (entity_delta.position_delta == null or
                            entity_delta.scale_delta == null or
                            entity_delta.deleteable_delta == null or
                            entity_delta.entity_type_changed == null or
                            entity_delta.active_changed == null)
                        {
                            std.debug.print("Warning: Incomplete delta data for new entity {}\n", .{entity_delta.id});
                            continue;
                        }

                        try new_entities.append(.{
                            .id = entity_delta.id,
                            .position = .{ .x = entity_delta.position_delta.?.x, .y = entity_delta.position_delta.?.y },
                            .scale = entity_delta.scale_delta.?,
                            .deleteable = entity_delta.deleteable_delta.?,
                            .entity_type = entity_delta.entity_type_changed.?,
                            .active = entity_delta.active_changed.?,
                            .parent_id = entity_delta.parent_id_changed,
                        });
                    }
                }

                // Create new snapshot
                const new_snapshot = Protocol.StateSnapshot{
                    .sequence = delta.sequence,
                    .timestamp = delta.timestamp,
                    .entities = try self.allocator.dupe(Protocol.NetworkEntity, new_entities.items),
                };

                // Insert new snapshot in order
                var insert_idx: usize = self.interpolation_buffer.items.len;
                for (self.interpolation_buffer.items, 0..) |buf_snapshot, i| {
                    if (buf_snapshot.timestamp > delta.timestamp) {
                        insert_idx = i;
                        break;
                    }
                }
                try self.interpolation_buffer.insert(insert_idx, new_snapshot);

                self.last_sequence_received = delta.sequence;
            },

            .state_snapshot_chunk => {
                const chunk = message.payload.state_snapshot_chunk;
                if (chunk.sequence <= self.last_sequence_received) return;

                // Store chunk
                const chunk_copy = Protocol.StateSnapshotChunk{
                    .sequence = chunk.sequence,
                    .chunk_id = chunk.chunk_id,
                    .total_chunks = chunk.total_chunks,
                    .timestamp = chunk.timestamp,
                    .entities = try self.allocator.dupe(Protocol.NetworkEntity, chunk.entities),
                };
                try self.pending_snapshot_chunks.put(chunk.chunk_id, chunk_copy);

                // Check if we have all chunks
                if (self.pending_snapshot_chunks.count() == chunk.total_chunks) {
                    // Combine chunks into complete snapshot
                    var all_entities = std.ArrayList(Protocol.NetworkEntity).init(self.allocator);
                    defer all_entities.deinit();

                    var chunk_id: u32 = 0;
                    while (chunk_id < chunk.total_chunks) : (chunk_id += 1) {
                        const stored_chunk = self.pending_snapshot_chunks.get(chunk_id).?;
                        try all_entities.appendSlice(stored_chunk.entities);
                    }

                    // Create complete snapshot
                    const complete_snapshot = Protocol.StateSnapshot{
                        .sequence = chunk.sequence,
                        .timestamp = chunk.timestamp,
                        .entities = try self.allocator.dupe(Protocol.NetworkEntity, all_entities.items),
                    };

                    // Insert in interpolation buffer
                    var insert_idx: usize = self.interpolation_buffer.items.len;
                    for (self.interpolation_buffer.items, 0..) |buf_snapshot, i| {
                        if (buf_snapshot.timestamp > chunk.timestamp) {
                            insert_idx = i;
                            break;
                        }
                    }
                    try self.interpolation_buffer.insert(insert_idx, complete_snapshot);

                    // Clean up chunks
                    var it = self.pending_snapshot_chunks.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.value_ptr.*.entities);
                    }
                    self.pending_snapshot_chunks.clearRetainingCapacity();

                    self.last_sequence_received = chunk.sequence;
                }
            },

            .state_delta_chunk => {
                const chunk = message.payload.state_delta_chunk;
                if (chunk.sequence <= self.last_sequence_received) return;

                // Store chunk
                const chunk_copy = Protocol.StateDeltaChunk{
                    .base_sequence = chunk.base_sequence,
                    .sequence = chunk.sequence,
                    .chunk_id = chunk.chunk_id,
                    .total_chunks = chunk.total_chunks,
                    .timestamp = chunk.timestamp,
                    .deltas = try self.allocator.dupe(Protocol.EntityDelta, chunk.deltas),
                };
                try self.pending_delta_chunks.put(chunk.chunk_id, chunk_copy);

                // Check if we have all chunks
                if (self.pending_delta_chunks.count() == chunk.total_chunks) {
                    // Find the base snapshot
                    var base_snapshot: ?Protocol.StateSnapshot = null;
                    for (self.interpolation_buffer.items) |snapshot| {
                        if (snapshot.sequence == chunk.base_sequence) {
                            base_snapshot = snapshot;
                            break;
                        }
                    }
                    if (base_snapshot == null) {
                        // Clean up chunks if we can't find base snapshot
                        var it = self.pending_delta_chunks.iterator();
                        while (it.next()) |entry| {
                            self.allocator.free(entry.value_ptr.*.deltas);
                        }
                        self.pending_delta_chunks.clearRetainingCapacity();
                        return;
                    }

                    // Combine all deltas
                    var all_deltas = std.ArrayList(Protocol.EntityDelta).init(self.allocator);
                    defer all_deltas.deinit();

                    var chunk_id: u32 = 0;
                    while (chunk_id < chunk.total_chunks) : (chunk_id += 1) {
                        const stored_chunk = self.pending_delta_chunks.get(chunk_id).?;
                        try all_deltas.appendSlice(stored_chunk.deltas);
                    }

                    // Create new entities list from base + deltas
                    var new_entities = std.ArrayList(Protocol.NetworkEntity).init(self.allocator);
                    defer new_entities.deinit();

                    // Copy base entities
                    try new_entities.appendSlice(base_snapshot.?.entities);

                    // Apply all deltas
                    for (all_deltas.items) |entity_delta| {
                        var found = false;
                        for (new_entities.items) |*entity| {
                            if (entity.id == entity_delta.id) {
                                found = true;
                                if (entity_delta.position_delta) |pos| {
                                    entity.position = .{ .x = pos.x, .y = pos.y };
                                }
                                if (entity_delta.scale_delta) |scale| {
                                    entity.scale = scale;
                                }
                                if (entity_delta.deleteable_delta) |deleteable| {
                                    entity.deleteable = deleteable;
                                }
                                if (entity_delta.entity_type_changed) |entity_type| {
                                    entity.entity_type = entity_type;
                                }
                                if (entity_delta.active_changed) |active| {
                                    entity.active = active;
                                }
                                if (entity_delta.parent_id_changed) |parent_id| {
                                    entity.parent_id = parent_id;
                                }
                                break;
                            }
                        }

                        if (!found) {
                            // New entity - ensure all required fields are present
                            if (entity_delta.position_delta == null or
                                entity_delta.scale_delta == null or
                                entity_delta.deleteable_delta == null or
                                entity_delta.entity_type_changed == null or
                                entity_delta.active_changed == null)
                            {
                                std.debug.print("Warning: Incomplete delta data for new entity {}\n", .{entity_delta.id});
                                continue;
                            }

                            try new_entities.append(.{
                                .id = entity_delta.id,
                                .position = .{ .x = entity_delta.position_delta.?.x, .y = entity_delta.position_delta.?.y },
                                .scale = entity_delta.scale_delta.?,
                                .deleteable = entity_delta.deleteable_delta.?,
                                .entity_type = entity_delta.entity_type_changed.?,
                                .active = entity_delta.active_changed.?,
                                .parent_id = entity_delta.parent_id_changed,
                            });
                        }
                    }

                    // Create new snapshot
                    const new_snapshot = Protocol.StateSnapshot{
                        .sequence = chunk.sequence,
                        .timestamp = chunk.timestamp,
                        .entities = try self.allocator.dupe(Protocol.NetworkEntity, new_entities.items),
                    };

                    // Insert in interpolation buffer
                    var insert_idx: usize = self.interpolation_buffer.items.len;
                    for (self.interpolation_buffer.items, 0..) |buf_snapshot, i| {
                        if (buf_snapshot.timestamp > chunk.timestamp) {
                            insert_idx = i;
                            break;
                        }
                    }
                    try self.interpolation_buffer.insert(insert_idx, new_snapshot);

                    // Clean up chunks and their allocated memory
                    var it = self.pending_delta_chunks.iterator();
                    while (it.next()) |entry| {
                        self.allocator.free(entry.value_ptr.*.deltas);
                    }
                    self.pending_delta_chunks.clearRetainingCapacity();

                    self.last_sequence_received = chunk.sequence;
                }
            },

            else => {}, // Ignore other message types that should only go server -> client
        }
    }

    fn sendToServer(self: *GameClient, message: Protocol.NetworkMessage) !void {
        if (self.socket == null or self.server_endpoint == null) return error.NotConnected;

        const json = try std.json.stringifyAlloc(self.allocator, message, .{});
        defer self.allocator.free(json);

        const socket = self.socket.?;
        const endpoint = self.server_endpoint.?;
        _ = try socket.sendTo(endpoint, json);
    }
};

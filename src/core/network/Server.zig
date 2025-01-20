const std = @import("std");
const State = @import("../State.zig");
const Protocol = @import("Protocol.zig");
const Input = @import("../Input.zig");
const network = @import("network");
const Constants = @import("Constants.zig");

const Client = struct {
    id: u64,
    player_entity_id: usize,
    last_input_time: f64,
    addr: network.EndPoint,
    initial_state_sent: bool = false,
    pending_chunks: std.AutoHashMap(u32, bool),
    current_chunk: u32 = 0,
    total_chunks: u32 = 0,
    pending_updates: std.ArrayList(Protocol.NetworkMessage),

    pub fn init(allocator: std.mem.Allocator, id: u64, player_entity_id: usize, addr: network.EndPoint) !Client {
        return Client{
            .id = id,
            .player_entity_id = player_entity_id,
            .last_input_time = 0,
            .addr = addr,
            .initial_state_sent = false,
            .pending_chunks = std.AutoHashMap(u32, bool).init(allocator),
            .current_chunk = 0,
            .total_chunks = 0,
            .pending_updates = std.ArrayList(Protocol.NetworkMessage).init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        self.pending_chunks.deinit();
        for (self.pending_updates.items) |*msg| {
            // Free any allocated memory in network messages
            if (msg.type == .relationship_updated) {
                self.pending_updates.allocator.free(msg.payload.relationship_updated.children);
            } else if (msg.type == .initial_state_chunk) {
                for (msg.payload.initial_state_chunk.relationships) |rel| {
                    self.pending_updates.allocator.free(rel.children);
                }
            }
        }
        self.pending_updates.deinit();
    }
};

const NetworkThread = struct {
    socket: network.Socket,
    allocator: std.mem.Allocator,
    server: *GameServer,
    should_stop: std.atomic.Value(bool),

    fn run(self: *NetworkThread) !void {
        var buf: [Constants.MAX_PACKET_SIZE]u8 = undefined;

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

// Message queue entry for outgoing messages
const OutgoingMessage = struct {
    endpoint: network.EndPoint,
    data: []const u8,

    pub fn deinit(self: *OutgoingMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

const SenderThread = struct {
    socket: network.Socket,
    allocator: std.mem.Allocator,
    server: *GameServer,
    should_stop: std.atomic.Value(bool),
    message_queue: std.ArrayList(OutgoingMessage),
    mutex: std.Thread.Mutex,

    fn init(allocator: std.mem.Allocator, socket: network.Socket, server: *GameServer) !*SenderThread {
        const sender = try allocator.create(SenderThread);
        sender.* = .{
            .socket = socket,
            .allocator = allocator,
            .server = server,
            .should_stop = std.atomic.Value(bool).init(false),
            .message_queue = std.ArrayList(OutgoingMessage).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
        return sender;
    }

    fn deinit(self: *SenderThread) void {
        // Clean up any remaining messages in the queue
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.message_queue.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.message_queue.deinit();
        self.allocator.destroy(self);
    }

    fn run(self: *SenderThread) !void {
        var messages_per_second: u32 = 0;
        var last_time = std.time.nanoTimestamp();
        var delta_accumulator: i128 = 0;

        while (!self.should_stop.load(.acquire)) {
            const current_time = std.time.nanoTimestamp();
            const delta_time = current_time - last_time;
            last_time = current_time;
            delta_accumulator += delta_time;

            // Process all messages in the queue
            self.mutex.lock();
            const messages = self.message_queue.items;
            if (messages.len > 0) {
                for (messages) |msg| {
                    _ = self.socket.sendTo(msg.endpoint, msg.data) catch |err| {
                        std.debug.print("Error sending message: {}\n", .{err});
                        continue;
                    };
                    messages_per_second += 1;
                }

                // Clean up sent messages
                for (messages) |*msg| {
                    msg.deinit(self.allocator);
                }
                self.message_queue.clearRetainingCapacity();
            }
            self.mutex.unlock();

            // Print stats every second
            if (delta_accumulator >= std.time.ns_per_s) {
                std.debug.print("Messages sent per second: {}\n", .{messages_per_second});
                messages_per_second = 0;
                delta_accumulator = 0;
            }

            // Small sleep to avoid busy loop if queue is empty
            if (messages.len == 0) {
                std.time.sleep(100 * std.time.ns_per_us); // 100 microseconds
            }
        }
    }

    fn queueMessage(self: *SenderThread, endpoint: network.EndPoint, data: []const u8) !void {
        const msg_data = try self.allocator.dupe(u8, data);
        const msg = OutgoingMessage{
            .endpoint = endpoint,
            .data = msg_data,
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.message_queue.append(msg);
    }
};

pub const GameServer = struct {
    allocator: std.mem.Allocator,
    game_state: State.GameState,
    clients: std.AutoHashMap(u64, Client),
    socket: network.Socket,
    next_client_id: u64,
    current_game_time_seconds: f64,
    last_frame_time: i128,
    last_state_update: i128,
    state_update_rate: i128, // How often to send state updates (in nanoseconds)
    last_input_update: i128, // Track last input processing time
    input_update_rate: i128, // How often to process inputs (in nanoseconds)
    network_thread: ?std.Thread = null,
    network_thread_data: ?*NetworkThread = null,
    sender_thread: ?std.Thread = null,
    sender_thread_data: ?*SenderThread = null,
    last_entity_states: std.AutoHashMap(usize, Protocol.NetworkEntity),
    last_relationships: std.ArrayList(Protocol.NetworkRelationship),
    entities_per_chunk: u32 = 10, // Number of entities to send in each initial state chunk

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
            .state_update_rate = std.time.ns_per_s / 20, // 20 Hz state updates (50ms)
            .last_input_update = std.time.nanoTimestamp(),
            .input_update_rate = std.time.ns_per_s / 60, // 60 Hz input processing (16.6ms)
            .network_thread = null,
            .network_thread_data = null,
            .sender_thread = null,
            .sender_thread_data = null,
            .last_entity_states = std.AutoHashMap(usize, Protocol.NetworkEntity).init(allocator),
            .last_relationships = std.ArrayList(Protocol.NetworkRelationship).init(allocator),
            .entities_per_chunk = 10,
            .current_game_time_seconds = 0,
            .last_frame_time = std.time.nanoTimestamp(),
        };

        // Create network thread data
        const thread_data = try allocator.create(NetworkThread);
        thread_data.* = .{
            .socket = socket,
            .allocator = allocator,
            .server = server,
            .should_stop = std.atomic.Value(bool).init(false),
        };

        // Create sender thread data
        const sender_data = try SenderThread.init(allocator, socket, server);

        // Start network thread
        server.network_thread = try std.Thread.spawn(.{}, NetworkThread.run, .{thread_data});
        server.network_thread_data = thread_data;

        // Start sender thread
        server.sender_thread = try std.Thread.spawn(.{}, SenderThread.run, .{sender_data});
        server.sender_thread_data = sender_data;

        return server;
    }

    pub fn deinit(self: *GameServer) void {
        // Stop sender thread first
        if (self.sender_thread_data) |thread_data| {
            thread_data.should_stop.store(true, .release);
            if (self.sender_thread) |thread| {
                thread.join();
            }
            thread_data.deinit();
            self.sender_thread_data = null;
            self.sender_thread = null;
        }

        // Stop network thread
        if (self.network_thread_data) |thread_data| {
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

        // Clean up new fields
        self.last_entity_states.deinit();
        self.last_relationships.deinit();

        self.clients.deinit();
        self.game_state.deinit();
        network.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *GameServer) !void {
        std.debug.print("Server starting main loop\n", .{});

        const target_frame_time: i128 = std.time.ns_per_s / 120; // Target 120 FPS

        while (true) {
            const current_time = std.time.nanoTimestamp();
            self.last_frame_time = current_time;
            // increment game time by time since last frame
            self.current_game_time_seconds += @as(f64, @floatFromInt(current_time - self.last_frame_time)) / std.time.ns_per_s;

            // Only process inputs at fixed rate
            const time_since_last_input = current_time - self.last_input_update;
            if (time_since_last_input >= self.input_update_rate) {
                // Use fixed delta time based on input rate instead of frame time
                const fixed_delta = @as(f32, @floatFromInt(self.input_update_rate)) / std.time.ns_per_s;
                // convert current time to seconds
                const current_game_time_seconds = @as(f64, @floatFromInt(current_time)) / std.time.ns_per_s;
                try self.game_state.update(
                    current_game_time_seconds,
                    fixed_delta,
                );
                try self.game_state.processStateEvents(fixed_delta, current_game_time_seconds);
                // Clear processed input events
                self.game_state.input_manager.clearEvents();
                self.last_input_update = current_time;
            }

            // Then send state updates if needed
            const time_since_last_update = current_time - self.last_state_update;
            if (time_since_last_update >= self.state_update_rate) {
                try self.broadcastGameState();
                self.last_state_update = current_time;
            }

            // Sleep for remaining frame time
            const elapsed = std.time.nanoTimestamp() - current_time;
            if (elapsed < target_frame_time) {
                std.time.sleep(@intCast(target_frame_time - elapsed));
            }
        }
    }

    fn handleMessage(self: *GameServer, message: Protocol.NetworkMessage, sender: network.EndPoint) !void {
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
                    .initial_state_sent = false,
                    .pending_chunks = std.AutoHashMap(u32, bool).init(self.allocator),
                    .current_chunk = 0,
                    .total_chunks = 0,
                    .pending_updates = std.ArrayList(Protocol.NetworkMessage).init(self.allocator),
                });

                // Send connect response
                var response = Protocol.NetworkMessage.init(.connect_response);
                response.payload.connect_response = .{
                    .success = true,
                    .client_id = client_id,
                    .player_entity_id = player_entity_id,
                };

                try self.sendTo(sender, response);
                std.debug.print("Client {} connected with player ID {}\n", .{ client_id, player_entity_id });

                // Start sending initial state chunks
                try self.startInitialStateStream(client_id);

                // Notify other clients about the new player
                var join_msg = Protocol.NetworkMessage.init(.player_joined);
                join_msg.payload.player_joined = .{
                    .client_id = client_id,
                    .player_entity_id = player_entity_id,
                };
                try self.broadcast(join_msg, client_id);
            },

            .initial_state_ack => {
                // Find client by endpoint
                var it = self.clients.iterator();
                while (it.next()) |entry| {
                    const client = entry.value_ptr;
                    if (std.meta.eql(client.addr, sender)) {
                        const chunk_id = message.payload.initial_state_ack.chunk_id;
                        _ = client.pending_chunks.remove(chunk_id);

                        // If all chunks are acknowledged, mark initial state as sent and process queued updates
                        if (client.pending_chunks.count() == 0) {
                            try self.handleInitialStateComplete(client);
                        }
                        break;
                    }
                }
            },

            .disconnect => {
                std.debug.print("Received disconnect message\n", .{});
                if (message.payload.disconnect.client_id) |client_id| {
                    if (self.clients.get(client_id)) |client| {
                        std.debug.print("Removing player entity {}\n", .{client.player_entity_id});
                        // Remove player entity
                        self.game_state.entity_manager.deleteEntity(client.player_entity_id);

                        // Remove client
                        defer _ = self.clients.remove(client_id);

                        // Notify other clients
                        var leave_msg = Protocol.NetworkMessage.init(.player_left);
                        leave_msg.payload.player_left = .{
                            .client_id = client_id,
                            .player_entity_id = client.player_entity_id,
                        };
                        try self.broadcast(leave_msg, null);
                    }
                }
            },

            .input_event => {
                const input_event = message.payload.input_event;

                // Find the client by player entity ID
                var it = self.clients.iterator();
                while (it.next()) |entry| {
                    const client = entry.value_ptr;
                    if (client.player_entity_id == input_event.source_player_id) {
                        if (input_event.timestamp < client.last_input_time) {
                            return; // Ignore old inputs
                        }
                        client.last_input_time = input_event.timestamp;

                        var modified_event = input_event;
                        modified_event.source = .remote;
                        try self.game_state.input_manager.addRemoteInput(modified_event);
                        break;
                    }
                }
            },

            else => {}, // Ignore other message types that should only go client -> server
        }
    }

    fn broadcastGameState(self: *GameServer) !void {
        // Convert current entities to network format and detect changes
        const entities = self.game_state.entity_manager.entities.slice();

        // Track created, updated, and deleted entities
        for (entities.items(.position), entities.items(.scale), entities.items(.deleteable), entities.items(.entity_type), entities.items(.active), 0..entities.len) |pos, scale, deleteable, entity_type, active, id| {
            if (id >= entities.len) continue;

            const current_entity = Protocol.NetworkEntity{
                .id = id,
                .position = .{ .x = pos.x, .y = pos.y },
                .scale = scale,
                .deleteable = deleteable,
                .entity_type = entity_type,
                .active = active,
            };

            // Check if this is a new entity
            if (!self.last_entity_states.contains(id)) {
                // Broadcast entity creation
                var create_msg = Protocol.NetworkMessage.init(.entity_created);
                create_msg.payload.entity_created = .{
                    .entity = current_entity,
                };
                try self.broadcastToInitializedClients(create_msg, null);
                try self.last_entity_states.put(id, current_entity);
                continue;
            }

            // Check for updates
            const last_entity = self.last_entity_states.get(id).?;
            var has_changes = false;
            var update_msg = Protocol.NetworkMessage.init(.entity_updated);
            update_msg.payload.entity_updated = .{ .id = id };

            if (!std.meta.eql(last_entity.position, current_entity.position)) {
                update_msg.payload.entity_updated.position = .{ .x = current_entity.position.x, .y = current_entity.position.y };
                has_changes = true;
            }
            if (last_entity.scale != current_entity.scale) {
                update_msg.payload.entity_updated.scale = current_entity.scale;
                has_changes = true;
            }
            if (last_entity.deleteable != current_entity.deleteable) {
                update_msg.payload.entity_updated.deleteable = current_entity.deleteable;
                has_changes = true;
            }
            if (last_entity.entity_type != current_entity.entity_type) {
                update_msg.payload.entity_updated.entity_type = current_entity.entity_type;
                has_changes = true;
            }
            if (last_entity.active != current_entity.active) {
                update_msg.payload.entity_updated.active = current_entity.active;
                has_changes = true;
            }

            if (has_changes) {
                try self.broadcastToInitializedClients(update_msg, null);
                try self.last_entity_states.put(id, current_entity);
            }
        }

        // Check for deleted entities
        var it = self.last_entity_states.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            if (id >= entities.len) {
                // Entity was deleted
                var delete_msg = Protocol.NetworkMessage.init(.entity_deleted);
                delete_msg.payload.entity_deleted = .{ .id = id };
                try self.broadcastToInitializedClients(delete_msg, null);
                _ = self.last_entity_states.remove(id);
            }
        }

        // Track relationship changes
        var relationships_changed = false;

        // First check if number of relationships changed
        if (self.last_relationships.items.len != self.game_state.entity_manager.relationships.items.len) {
            relationships_changed = true;
        } else {
            // Check each relationship for changes
            outer: for (self.game_state.entity_manager.relationships.items) |rel| {
                // Find matching relationship in last state
                for (self.last_relationships.items) |last_rel| {
                    if (last_rel.parent_id == rel.parent_id) {
                        // Check if children array length changed
                        if (last_rel.children.len != rel.children.items.len) {
                            relationships_changed = true;
                            break :outer;
                        }
                        // Check if any children changed
                        for (rel.children.items, last_rel.children) |child, last_child| {
                            if (child != last_child) {
                                relationships_changed = true;
                                break :outer;
                            }
                        }
                        continue :outer;
                    }
                }
                // If we get here, this is a new relationship
                relationships_changed = true;
                break;
            }
        }

        // Only send updates and update last state if changes detected
        if (relationships_changed) {
            // Clear last relationships
            for (self.last_relationships.items) |*rel| {
                self.allocator.free(rel.children);
            }
            self.last_relationships.clearRetainingCapacity();

            // Send updates and store new state
            for (self.game_state.entity_manager.relationships.items) |rel| {
                var update_msg = Protocol.NetworkMessage.init(.relationship_updated);
                update_msg.payload.relationship_updated = .{
                    .parent_id = rel.parent_id,
                    .children = try self.allocator.dupe(usize, rel.children.items),
                };
                try self.broadcastToInitializedClients(update_msg, null);

                // Store current state
                try self.last_relationships.append(.{
                    .parent_id = rel.parent_id,
                    .children = try self.allocator.dupe(usize, rel.children.items),
                });
            }
        }
    }

    fn broadcastToInitializedClients(self: *GameServer, message: Protocol.NetworkMessage, exclude_client: ?u64) !void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            const client = entry.value_ptr;
            if (exclude_client != null and client.id == exclude_client.?) {
                continue;
            }
            if (client.initial_state_sent) {
                try self.sendTo(client.addr, message);
            } else {
                // Deep copy the message before queueing
                var msg_copy = message;
                if (message.type == .relationship_updated) {
                    msg_copy.payload.relationship_updated.children = try self.allocator.dupe(usize, message.payload.relationship_updated.children);
                } else if (message.type == .initial_state_chunk) {
                    var rels = try self.allocator.alloc(Protocol.NetworkRelationship, message.payload.initial_state_chunk.relationships.len);
                    for (message.payload.initial_state_chunk.relationships, 0..) |rel, i| {
                        rels[i] = .{
                            .parent_id = rel.parent_id,
                            .children = try self.allocator.dupe(usize, rel.children),
                        };
                    }
                    msg_copy.payload.initial_state_chunk.relationships = rels;
                }
                try client.pending_updates.append(msg_copy);
            }
        }
    }

    fn handleInitialStateComplete(self: *GameServer, client: *Client) !void {
        client.initial_state_sent = true;

        // Send all queued updates
        for (client.pending_updates.items) |update| {
            try self.sendTo(client.addr, update);
        }
        client.pending_updates.clearRetainingCapacity();
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
        errdefer self.allocator.free(json);

        if (self.sender_thread_data) |sender| {
            try sender.queueMessage(endpoint, json);
        } else {
            defer self.allocator.free(json);
            _ = try self.socket.sendTo(endpoint, json);
        }
    }

    fn startInitialStateStream(self: *GameServer, client_id: u64) !void {
        var client = self.clients.getPtr(client_id) orelse return error.ClientNotFound;

        // Convert current entities to network format
        var network_entities = std.ArrayList(Protocol.NetworkEntity).init(self.allocator);
        defer network_entities.deinit();

        const entities = self.game_state.entity_manager.entities.slice();
        for (entities.items(.position), entities.items(.scale), entities.items(.deleteable), entities.items(.entity_type), entities.items(.active), 0..entities.len) |pos, scale, deleteable, entity_type, active, id| {
            if (id >= entities.len) continue;

            try network_entities.append(.{
                .id = id,
                .position = .{ .x = pos.x, .y = pos.y },
                .scale = scale,
                .deleteable = deleteable,
                .entity_type = entity_type,
                .active = active,
            });
        }

        // Convert relationships to network format
        var network_relationships = std.ArrayList(Protocol.NetworkRelationship).init(self.allocator);
        defer network_relationships.deinit();

        for (self.game_state.entity_manager.relationships.items) |rel| {
            try network_relationships.append(.{
                .parent_id = rel.parent_id,
                .children = try self.allocator.dupe(usize, rel.children.items),
            });
        }

        // Calculate total chunks needed
        const total_entities = network_entities.items.len;
        const total_chunks = @divTrunc(total_entities + self.entities_per_chunk - 1, self.entities_per_chunk);
        client.total_chunks = @intCast(total_chunks);

        // Send initial state in chunks
        var chunk_id: u32 = 0;
        var entity_index: usize = 0;
        while (entity_index < total_entities) {
            const chunk_size = @min(self.entities_per_chunk, total_entities - entity_index);
            const chunk_end = entity_index + chunk_size;

            var chunk_msg = Protocol.NetworkMessage.init(.initial_state_chunk);
            chunk_msg.payload.initial_state_chunk = .{
                .chunk_id = chunk_id,
                .total_chunks = @intCast(total_chunks),
                .entities = network_entities.items[entity_index..chunk_end],
                .relationships = network_relationships.items,
            };

            try self.sendTo(client.addr, chunk_msg);
            try client.pending_chunks.put(chunk_id, true);

            entity_index = chunk_end;
            chunk_id += 1;
        }

        // Clean up relationship children arrays
        for (network_relationships.items) |rel| {
            self.allocator.free(rel.children);
        }
    }
};

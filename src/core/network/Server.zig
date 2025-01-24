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
            if (msg.type == .initial_state_chunk) {
                self.pending_updates.allocator.free(msg.payload.initial_state_chunk.entities);
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

            // Print stats every 5 seconds
            if (delta_accumulator >= 5 * std.time.ns_per_s) {
                std.debug.print("Messages sent over last 5 seconds: {}\n", .{messages_per_second});
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
    state_update_rate: i128 = std.time.ns_per_s / 60, // Update state at 60Hz (16.6ms)
    last_input_update: i128,
    input_update_rate: i128 = std.time.ns_per_s / 60, // Process inputs at 60Hz
    network_thread: ?std.Thread = null,
    network_thread_data: ?*NetworkThread = null,
    sender_thread: ?std.Thread = null,
    sender_thread_data: ?*SenderThread = null,
    last_entity_states: std.AutoHashMap(usize, Protocol.NetworkEntity),
    entities_per_chunk: u32 = 10, // Number of entities to send in each initial state chunk
    pending_updates: std.ArrayList(Protocol.EntityUpdated),
    pending_creates: std.ArrayList(Protocol.EntityCreated),
    pending_deletes: std.ArrayList(Protocol.EntityDeleted),
    update_batch_size: usize = 50, // Maximum number of updates to batch together
    max_updates_per_batch: usize = 10, // Maximum number of updates to send in a single network message
    min_update_interval: i128 = std.time.ns_per_s / 60, // Send deltas at 60Hz
    last_batch_time: i128,
    current_sequence: u32 = 0,
    snapshot_interval: i128 = std.time.ns_per_s / 4, // Full snapshot every 250ms
    last_snapshot_time: i128,
    snapshot_history: std.ArrayList(Protocol.StateSnapshot),
    max_snapshot_history: usize = 30, // Keep more snapshots for better delta references
    entities_per_snapshot_chunk: u32 = 20, // Maximum entities per snapshot chunk
    deltas_per_chunk: u32 = 20, // Maximum deltas per chunk

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

        const current_time = std.time.nanoTimestamp();

        server.* = GameServer{
            .allocator = allocator,
            .game_state = try State.GameState.init(allocator, false),
            .clients = std.AutoHashMap(u64, Client).init(allocator),
            .socket = socket,
            .next_client_id = 1,
            .last_state_update = current_time,
            .state_update_rate = std.time.ns_per_s / 60,
            .last_input_update = current_time,
            .input_update_rate = std.time.ns_per_s / 60,
            .network_thread = null,
            .network_thread_data = null,
            .sender_thread = null,
            .sender_thread_data = null,
            .last_entity_states = std.AutoHashMap(usize, Protocol.NetworkEntity).init(allocator),
            .entities_per_chunk = 10,
            .current_game_time_seconds = 0,
            .last_frame_time = current_time,
            .pending_updates = std.ArrayList(Protocol.EntityUpdated).init(allocator),
            .pending_creates = std.ArrayList(Protocol.EntityCreated).init(allocator),
            .pending_deletes = std.ArrayList(Protocol.EntityDeleted).init(allocator),
            .last_batch_time = current_time,
            .current_sequence = 0,
            .last_snapshot_time = current_time,
            .snapshot_history = std.ArrayList(Protocol.StateSnapshot).init(allocator),
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

        // Clean up new fields
        self.last_entity_states.deinit();

        self.clients.deinit();
        self.game_state.deinit();
        network.deinit();
        self.allocator.destroy(self);
        self.pending_updates.deinit();
        self.pending_creates.deinit();
        self.pending_deletes.deinit();
        for (self.snapshot_history.items) |snapshot| {
            self.allocator.free(snapshot.entities);
        }
        self.snapshot_history.deinit();
    }

    pub fn start(self: *GameServer) !void {
        std.debug.print("Server starting main loop\n", .{});

        const target_frame_time: i128 = std.time.ns_per_s / 30; // Target 30 hz server tick rate

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
        const current_time = std.time.nanoTimestamp();
        const entities = self.game_state.entity_manager.entities.slice();
        const time_since_snapshot = current_time - self.last_snapshot_time;

        // Decide whether to send a full snapshot or delta
        if (time_since_snapshot >= self.snapshot_interval or self.snapshot_history.items.len == 0) {
            // Send full snapshot
            var snapshot_entities = try std.ArrayList(Protocol.NetworkEntity).initCapacity(
                self.allocator,
                entities.len,
            );
            defer snapshot_entities.deinit();

            // Collect all active entities
            for (entities.items(.position), entities.items(.scale), entities.items(.deleteable), entities.items(.entity_type), entities.items(.active), entities.items(.parent_id), entities.items(.health), 0..entities.len) |pos, scale, deleteable, entity_type, active, parent_id, health, id| {
                if (id >= entities.len) continue;
                if (!active) continue; // Only send active entities

                try snapshot_entities.append(.{
                    .id = id,
                    .position = .{ .x = pos.x, .y = pos.y },
                    .scale = scale,
                    .deleteable = deleteable,
                    .entity_type = entity_type,
                    .active = active,
                    .parent_id = parent_id,
                    .health = health,
                });
            }

            // Create the snapshot for history
            const snapshot = Protocol.StateSnapshot{
                .sequence = self.current_sequence,
                .timestamp = @as(f64, @floatFromInt(current_time)) / std.time.ns_per_s,
                .entities = try self.allocator.dupe(Protocol.NetworkEntity, snapshot_entities.items),
            };

            // Store snapshot in history
            try self.snapshot_history.append(snapshot);
            if (self.snapshot_history.items.len > self.max_snapshot_history) {
                const old_snapshot = self.snapshot_history.orderedRemove(0);
                self.allocator.free(old_snapshot.entities);
            }

            // Send snapshot in chunks if needed
            const total_chunks = (snapshot_entities.items.len + self.entities_per_snapshot_chunk - 1) / self.entities_per_snapshot_chunk;
            var chunk_id: u32 = 0;
            var entity_start: usize = 0;

            while (entity_start < snapshot_entities.items.len) {
                const chunk_end = @min(entity_start + self.entities_per_snapshot_chunk, snapshot_entities.items.len);
                var chunk_msg = Protocol.NetworkMessage.init(.state_snapshot_chunk);
                chunk_msg.payload.state_snapshot_chunk = .{
                    .sequence = self.current_sequence,
                    .chunk_id = chunk_id,
                    .total_chunks = @intCast(total_chunks),
                    .timestamp = snapshot.timestamp,
                    .entities = snapshot_entities.items[entity_start..chunk_end],
                };

                try self.broadcastToInitializedClients(chunk_msg, null);
                chunk_id += 1;
                entity_start = chunk_end;
            }

            self.last_snapshot_time = current_time;
        } else {
            // Send delta update based on last snapshot
            if (self.snapshot_history.items.len == 0) return;
            const base_snapshot = self.snapshot_history.items[self.snapshot_history.items.len - 1];

            var deltas = std.ArrayList(Protocol.EntityDelta).init(self.allocator);
            defer deltas.deinit();

            // Calculate deltas from last snapshot
            for (entities.items(.position), entities.items(.scale), entities.items(.deleteable), entities.items(.entity_type), entities.items(.active), entities.items(.parent_id), 0..entities.len) |pos, scale, deleteable, entity_type, active, parent_id, id| {
                if (id >= entities.len) continue;
                if (!active) continue;

                // Find entity in base snapshot
                var found_in_base = false;
                var base_entity: Protocol.NetworkEntity = undefined;
                for (base_snapshot.entities) |entity| {
                    if (entity.id == id) {
                        found_in_base = true;
                        base_entity = entity;
                        break;
                    }
                }

                if (!found_in_base) {
                    // New entity, include all data
                    try deltas.append(.{
                        .id = id,
                        .position_delta = .{ .x = pos.x, .y = pos.y },
                        .scale_delta = scale,
                        .deleteable_delta = deleteable,
                        .entity_type_changed = entity_type,
                        .active_changed = active,
                        .parent_id_changed = parent_id,
                    });
                    continue;
                }

                // Check for changes
                var delta = Protocol.EntityDelta{ .id = id };
                var has_changes = false;

                if (!std.meta.eql(base_entity.position, .{ .x = pos.x, .y = pos.y })) {
                    delta.position_delta = .{ .x = pos.x, .y = pos.y };
                    has_changes = true;
                }
                if (base_entity.scale != scale) {
                    delta.scale_delta = scale;
                    has_changes = true;
                }
                if (base_entity.deleteable != deleteable) {
                    delta.deleteable_delta = deleteable;
                    has_changes = true;
                }
                if (base_entity.entity_type != entity_type) {
                    delta.entity_type_changed = entity_type;
                    has_changes = true;
                }
                if (base_entity.active != active) {
                    delta.active_changed = active;
                    has_changes = true;
                }
                if (base_entity.parent_id != parent_id) {
                    delta.parent_id_changed = parent_id;
                    has_changes = true;
                }

                if (has_changes) {
                    try deltas.append(delta);
                }
            }

            // Send deltas in chunks if needed
            if (deltas.items.len > 0) {
                const total_chunks = (deltas.items.len + self.deltas_per_chunk - 1) / self.deltas_per_chunk;
                var chunk_id: u32 = 0;
                var delta_start: usize = 0;

                while (delta_start < deltas.items.len) {
                    const chunk_end = @min(delta_start + self.deltas_per_chunk, deltas.items.len);
                    var chunk_msg = Protocol.NetworkMessage.init(.state_delta_chunk);
                    chunk_msg.payload.state_delta_chunk = .{
                        .base_sequence = base_snapshot.sequence,
                        .sequence = self.current_sequence,
                        .chunk_id = chunk_id,
                        .total_chunks = @intCast(total_chunks),
                        .timestamp = @as(f64, @floatFromInt(current_time)) / std.time.ns_per_s,
                        .deltas = deltas.items[delta_start..chunk_end],
                    };

                    try self.broadcastToInitializedClients(chunk_msg, null);
                    chunk_id += 1;
                    delta_start = chunk_end;
                }
            }
        }

        self.current_sequence += 1;
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
                if (message.type == .initial_state_chunk) {
                    msg_copy.payload.initial_state_chunk.entities = try self.allocator.dupe(Protocol.NetworkEntity, message.payload.initial_state_chunk.entities);
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
        for (entities.items(.position), entities.items(.scale), entities.items(.deleteable), entities.items(.entity_type), entities.items(.active), entities.items(.parent_id), entities.items(.health), 0..entities.len) |pos, scale, deleteable, entity_type, active, parent_id, health, id| {
            if (id >= entities.len) continue;

            try network_entities.append(.{
                .id = id,
                .position = .{ .x = pos.x, .y = pos.y },
                .scale = scale,
                .deleteable = deleteable,
                .entity_type = entity_type,
                .active = active,
                .parent_id = parent_id,
                .health = health,
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
            };

            try self.sendTo(client.addr, chunk_msg);
            try client.pending_chunks.put(chunk_id, true);

            entity_index = chunk_end;
            chunk_id += 1;
        }
    }
};

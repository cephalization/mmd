const std = @import("std");
const Entity = @import("../Entity.zig");
const Input = @import("../Input.zig");

pub const MessageType = enum {
    connect_request,
    connect_response,
    disconnect,
    player_joined,
    player_left,
    input_event,
    state_update,
    entity_created,
    entity_updated,
    entity_deleted,
    initial_state_chunk,
    initial_state_ack,
};

// Network-friendly version of Entity
pub const NetworkEntity = struct {
    id: usize,
    position: struct { x: f32, y: f32 },
    scale: f32,
    deleteable: f64,
    entity_type: Entity.EntityType,
    active: bool,
    parent_id: ?usize = null,
};

pub const ConnectRequest = struct {
    client_id: ?u64 = null,
};

pub const ConnectResponse = struct {
    success: bool,
    client_id: u64,
    player_entity_id: usize,
};

pub const PlayerEvent = struct {
    client_id: u64,
    player_entity_id: usize,
};

pub const StateUpdate = struct {
    timestamp: f64,
    entities: []NetworkEntity,
};

pub const EntityCreated = struct {
    entity: NetworkEntity,
};

pub const EntityUpdated = struct {
    id: usize,
    position: ?struct { x: f32, y: f32 } = null,
    scale: ?f32 = null,
    deleteable: ?f64 = null,
    entity_type: ?Entity.EntityType = null,
    active: ?bool = null,
    parent_id: ?usize = null,
};

pub const EntityDeleted = struct {
    id: usize,
};

pub const InitialStateChunk = struct {
    chunk_id: u32,
    total_chunks: u32,
    entities: []NetworkEntity,
};

pub const InitialStateAck = struct {
    chunk_id: u32,
};

pub const MessagePayload = union(MessageType) {
    connect_request: ConnectRequest,
    connect_response: ConnectResponse,
    disconnect: ConnectRequest,
    player_joined: PlayerEvent,
    player_left: PlayerEvent,
    input_event: Input.InputEvent,
    state_update: StateUpdate,
    entity_created: EntityCreated,
    entity_updated: EntityUpdated,
    entity_deleted: EntityDeleted,
    initial_state_chunk: InitialStateChunk,
    initial_state_ack: InitialStateAck,
};

pub const NetworkMessage = struct {
    type: MessageType,
    payload: MessagePayload,

    pub fn init(msg_type: MessageType) NetworkMessage {
        return .{
            .type = msg_type,
            .payload = switch (msg_type) {
                .connect_request => .{ .connect_request = .{} },
                .connect_response => .{ .connect_response = .{ .success = false, .client_id = 0, .player_entity_id = 0 } },
                .disconnect => .{ .disconnect = .{} },
                .player_joined => .{ .player_joined = .{ .client_id = 0, .player_entity_id = 0 } },
                .player_left => .{ .player_left = .{ .client_id = 0, .player_entity_id = 0 } },
                .input_event => .{ .input_event = undefined },
                .state_update => .{ .state_update = .{ .timestamp = 0, .entities = &[_]NetworkEntity{} } },
                .entity_created => .{ .entity_created = .{ .entity = undefined } },
                .entity_updated => .{ .entity_updated = .{ .id = 0 } },
                .entity_deleted => .{ .entity_deleted = .{ .id = 0 } },
                .initial_state_chunk => .{ .initial_state_chunk = .{ .chunk_id = 0, .total_chunks = 0, .entities = &[_]NetworkEntity{} } },
                .initial_state_ack => .{ .initial_state_ack = .{ .chunk_id = 0 } },
            },
        };
    }
};

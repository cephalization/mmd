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
    batched_updates,
    state_snapshot,
    state_delta,
    state_snapshot_chunk,
    state_delta_chunk,
};

// Network-friendly version of Entity
pub const NetworkEntity = struct {
    id: usize,
    position: struct { x: f32, y: f32 },
    scale: f32,
    health: f32,
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
    health: ?f32 = null,
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

pub const BatchedEntityUpdates = struct {
    updates: []EntityUpdated,
    created: []EntityCreated,
    deleted: []EntityDeleted,
    timestamp: f64,
};

pub const StateSnapshot = struct {
    sequence: u32,
    timestamp: f64,
    entities: []NetworkEntity,
};

pub const EntityDelta = struct {
    id: usize,
    position_delta: ?struct { x: f32, y: f32 } = null,
    scale_delta: ?f32 = null,
    health_delta: ?f32 = null,
    deleteable_delta: ?f64 = null,
    entity_type_changed: ?Entity.EntityType = null,
    active_changed: ?bool = null,
    parent_id_changed: ?usize = null,
};

pub const StateDelta = struct {
    base_sequence: u32,
    sequence: u32,
    timestamp: f64,
    deltas: []EntityDelta,
};

pub const StateSnapshotChunk = struct {
    sequence: u32,
    chunk_id: u32,
    total_chunks: u32,
    timestamp: f64,
    entities: []NetworkEntity,
};

pub const StateDeltaChunk = struct {
    base_sequence: u32,
    sequence: u32,
    chunk_id: u32,
    total_chunks: u32,
    timestamp: f64,
    deltas: []EntityDelta,
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
    batched_updates: BatchedEntityUpdates,
    state_snapshot: StateSnapshot,
    state_delta: StateDelta,
    state_snapshot_chunk: StateSnapshotChunk,
    state_delta_chunk: StateDeltaChunk,
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
                .batched_updates => .{ .batched_updates = .{ .updates = &[_]EntityUpdated{}, .created = &[_]EntityCreated{}, .deleted = &[_]EntityDeleted{}, .timestamp = 0 } },
                .state_snapshot => .{ .state_snapshot = .{ .sequence = 0, .timestamp = 0, .entities = &[_]NetworkEntity{} } },
                .state_delta => .{ .state_delta = .{ .base_sequence = 0, .sequence = 0, .timestamp = 0, .deltas = &[_]EntityDelta{} } },
                .state_snapshot_chunk => .{ .state_snapshot_chunk = .{ .sequence = 0, .chunk_id = 0, .total_chunks = 0, .timestamp = 0, .entities = &[_]NetworkEntity{} } },
                .state_delta_chunk => .{ .state_delta_chunk = .{ .base_sequence = 0, .sequence = 0, .chunk_id = 0, .total_chunks = 0, .timestamp = 0, .deltas = &[_]EntityDelta{} } },
            },
        };
    }
};

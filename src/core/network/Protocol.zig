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
};

// Network-friendly version of Entity
pub const NetworkEntity = struct {
    id: usize,
    position: struct { x: f32, y: f32 },
    scale: f32,
    deleteable: f64,
    entity_type: Entity.EntityType,
};

// Network-friendly version of EntityRelationship
pub const NetworkRelationship = struct {
    parent_id: ?usize,
    children: []usize,
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
    relationships: []NetworkRelationship,
};

pub const MessagePayload = union(MessageType) {
    connect_request: ConnectRequest,
    connect_response: ConnectResponse,
    disconnect: ConnectRequest,
    player_joined: PlayerEvent,
    player_left: PlayerEvent,
    input_event: Input.InputEvent,
    state_update: StateUpdate,
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
                .state_update => .{ .state_update = .{ .timestamp = 0, .entities = &[_]NetworkEntity{}, .relationships = &[_]NetworkRelationship{} } },
            },
        };
    }
};

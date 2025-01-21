const std = @import("std");
const ray = @import("../raylib.zig");

pub const EntityType = enum {
    player,
    child,
};

pub const Entity = struct {
    position: ray.Vector2,
    scale: f32,
    // time marked for deletion or 0 if not marked
    deleteable: f64,
    active: bool = true,
    entity_type: EntityType,
    parent_id: ?usize = null,
};

pub const EntityList = std.MultiArrayList(Entity);

pub const EntityManager = struct {
    entities: EntityList,
    free_slots: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EntityManager {
        return .{
            .entities = EntityList{},
            .free_slots = std.ArrayList(usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EntityManager) void {
        self.free_slots.deinit();
        self.entities.deinit(self.allocator);
    }

    pub fn createEntity(self: *EntityManager, entity: Entity, parent_id: ?usize) !usize {
        var entity_id: usize = undefined;
        var new_entity = entity;
        new_entity.active = true;
        new_entity.parent_id = parent_id;

        // Reuse a free slot if available
        if (self.free_slots.items.len > 0) {
            entity_id = self.free_slots.pop();
            self.entities.set(entity_id, new_entity);
        } else {
            try self.entities.append(self.allocator, new_entity);
            entity_id = self.entities.len - 1;
        }

        return entity_id;
    }

    pub fn deleteEntity(self: *EntityManager, entity_id: usize) void {
        // Mark entity as inactive
        self.entities.items(.active)[entity_id] = false;

        // Mark slot as free
        self.free_slots.append(entity_id) catch unreachable;
    }

    // Helper function to get an entity only if it's active
    pub fn getActiveEntity(self: *const EntityManager, entity_id: usize) ?Entity {
        if (entity_id >= self.entities.len) return null;

        const pos = self.entities.items(.position)[entity_id];
        const scale = self.entities.items(.scale)[entity_id];
        const deleteable = self.entities.items(.deleteable)[entity_id];
        const entity_type = self.entities.items(.entity_type)[entity_id];
        const parent_id = self.entities.items(.parent_id)[entity_id];

        return Entity{
            .position = pos,
            .scale = scale,
            .deleteable = deleteable,
            .entity_type = entity_type,
            .parent_id = parent_id,
        };
    }

    // Helper function to get a slice of active children for a parent
    pub fn getActiveChildren(self: *EntityManager, parent_id: usize) []const usize {
        // Filter out inactive children
        var temp_active = std.ArrayList(usize).init(self.allocator);
        defer temp_active.deinit();

        for (self.entities.items(.active), self.entities.items(.parent_id), 0..) |active, maybe_parent, id| {
            if (active and maybe_parent != null and maybe_parent.? == parent_id) {
                temp_active.append(id) catch continue;
            }
        }

        // Create a slice of the active children that will persist
        const result = self.allocator.alloc(usize, temp_active.items.len) catch return &[_]usize{};
        @memcpy(result, temp_active.items);
        return result;
    }

    // Helper function to check if an entity is active
    pub fn isActive(self: *EntityManager, entity_id: usize) bool {
        if (entity_id >= self.entities.len) return false;
        return self.entities.items(.active)[entity_id];
    }

    // Helper function to get all active player IDs
    pub fn getActivePlayers(self: *const EntityManager) !std.ArrayList(usize) {
        var players = std.ArrayList(usize).init(self.allocator);
        for (self.entities.items(.active), self.entities.items(.entity_type), 0..) |active, entity_type, id| {
            if (active and entity_type == .player) {
                try players.append(id);
            }
        }
        return players;
    }
};

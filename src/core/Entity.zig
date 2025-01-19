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
};

pub const EntityList = std.MultiArrayList(Entity);

// Relationship storage for parent-child connections
pub const Relationships = struct {
    parent_id: ?usize,
    children: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    pub fn init(parent: ?usize, allocator: std.mem.Allocator) Relationships {
        return .{
            .parent_id = parent,
            .children = std.ArrayList(usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Relationships) void {
        self.children.deinit();
    }
};

pub const EntityManager = struct {
    entities: EntityList,
    relationships: std.ArrayList(Relationships),
    free_slots: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EntityManager {
        return .{
            .entities = EntityList{},
            .relationships = std.ArrayList(Relationships).init(allocator),
            .free_slots = std.ArrayList(usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EntityManager) void {
        for (self.relationships.items) |*rel| {
            rel.deinit();
        }
        self.relationships.deinit();
        self.free_slots.deinit();
        self.entities.deinit(self.allocator);
    }

    pub fn createEntity(self: *EntityManager, entity: Entity, parent_id: ?usize) !usize {
        var entity_id: usize = undefined;
        var new_entity = entity;
        new_entity.active = true;

        // Reuse a free slot if available
        if (self.free_slots.items.len > 0) {
            entity_id = self.free_slots.pop();
            self.entities.set(entity_id, new_entity);
            self.relationships.items[entity_id] = Relationships.init(parent_id, self.allocator);
        } else {
            try self.entities.append(self.allocator, new_entity);
            try self.relationships.append(Relationships.init(parent_id, self.allocator));
            entity_id = self.entities.len - 1;
        }

        // Add to parent's children if parent exists
        if (parent_id) |pid| {
            try self.relationships.items[pid].children.append(entity_id);
        }

        return entity_id;
    }

    pub fn deleteEntity(self: *EntityManager, entity_id: usize) void {
        var rel = &self.relationships.items[entity_id];

        // Remove from parent's children list
        if (rel.parent_id) |pid| {
            for (self.relationships.items[pid].children.items, 0..) |child, i| {
                if (child == entity_id) {
                    _ = self.relationships.items[pid].children.orderedRemove(i);
                    break;
                }
            }
        }

        // Clean up relationships
        rel.deinit();
        rel.* = Relationships.init(null, self.allocator);

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

        return Entity{
            .position = pos,
            .scale = scale,
            .deleteable = deleteable,
            .entity_type = entity_type,
        };
    }

    // Helper function to get a slice of active children for a parent
    pub fn getActiveChildren(self: *EntityManager, parent_id: usize) []const usize {
        // Filter out inactive children
        const children = &self.relationships.items[parent_id].children;
        var active_count: usize = 0;
        for (children.items) |child_id| {
            if (self.entities.items(.active)[child_id]) {
                children.items[active_count] = child_id;
                active_count += 1;
            }
        }
        return children.items[0..active_count];
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

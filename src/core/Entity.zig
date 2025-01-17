const std = @import("std");
const ray = @import("../raylib.zig");

pub const Entity = struct {
    position: ray.Vector2,
    scale: f32,
    // time marked for deletion or 0 if not marked
    deleteable: f64,
    active: bool = true,
};

pub const EntityList = std.MultiArrayList(Entity);

// Relationship storage for parent-child connections
pub const Relationships = struct {
    parent_id: ?usize,
    children: std.ArrayList(usize),

    pub fn init(parent: ?usize) Relationships {
        return .{
            .parent_id = parent,
            .children = std.ArrayList(usize).init(std.heap.page_allocator),
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

    pub fn init() EntityManager {
        return .{
            .entities = EntityList{},
            .relationships = std.ArrayList(Relationships).init(std.heap.page_allocator),
            .free_slots = std.ArrayList(usize).init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *EntityManager) void {
        for (self.relationships.items) |*rel| {
            rel.deinit();
        }
        self.relationships.deinit();
        self.free_slots.deinit();
        self.entities.deinit(std.heap.page_allocator);
    }

    pub fn createEntity(self: *EntityManager, entity: Entity, parent_id: ?usize) !usize {
        var entity_id: usize = undefined;
        var new_entity = entity;
        new_entity.active = true;

        // Reuse a free slot if available
        if (self.free_slots.items.len > 0) {
            entity_id = self.free_slots.pop();
            self.entities.set(entity_id, new_entity);
            self.relationships.items[entity_id] = Relationships.init(parent_id);
        } else {
            try self.entities.append(std.heap.page_allocator, new_entity);
            try self.relationships.append(Relationships.init(parent_id));
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
        rel.* = Relationships.init(null);

        // Mark entity as inactive
        self.entities.items(.active)[entity_id] = false;

        // Mark slot as free
        self.free_slots.append(entity_id) catch unreachable;
    }

    // Helper function to get an entity only if it's active
    pub fn getActiveEntity(self: *EntityManager, entity_id: usize) ?Entity {
        if (entity_id >= self.entities.len) return null;
        if (!self.entities.items(.active)[entity_id]) return null;
        return self.entities.get(entity_id);
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
};

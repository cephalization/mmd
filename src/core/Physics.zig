const std = @import("std");
const ray = @import("../raylib.zig");
const Entity = @import("Entity.zig");

pub const PhysicsComponent = struct {
    velocity: ray.Vector2 = .{ .x = 0, .y = 0 },
    mass: f32 = 1.0,
    // Circular collision for simplicity
    radius: f32 = 16.0,
    // Damping to simulate friction/drag
    damping: f32 = 0.98,
};

pub const PhysicsSystem = struct {
    components: std.AutoHashMap(usize, PhysicsComponent),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PhysicsSystem {
        return .{
            .components = std.AutoHashMap(usize, PhysicsComponent).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PhysicsSystem) void {
        self.components.deinit();
    }

    pub fn addComponent(self: *PhysicsSystem, entity_id: usize, component: PhysicsComponent) !void {
        try self.components.put(entity_id, component);
    }

    pub fn removeComponent(self: *PhysicsSystem, entity_id: usize) void {
        _ = self.components.remove(entity_id);
    }

    pub fn step(self: *PhysicsSystem, entity_manager: *Entity.EntityManager, dt: f32) void {
        var iter = self.components.iterator();
        while (iter.next()) |entry| {
            const entity_id = entry.key_ptr.*;
            var physics = entry.value_ptr.*;

            // Skip inactive entities
            if (!entity_manager.entities.get(entity_id).active) continue;

            // Apply damping (adjusted for fixed timestep)
            const damping_factor = std.math.pow(f32, physics.damping, dt / (1.0 / 60.0));
            physics.velocity.x *= damping_factor;
            physics.velocity.y *= damping_factor;

            // Update position with fixed timestep
            var entity = entity_manager.entities.get(entity_id);
            entity.position.x += physics.velocity.x * dt;
            entity.position.y += physics.velocity.y * dt;
            entity_manager.entities.set(entity_id, entity);

            // Handle collisions with other entities
            var other_iter = self.components.iterator();
            while (other_iter.next()) |other_entry| {
                const other_id = other_entry.key_ptr.*;
                if (other_id == entity_id) continue;

                const other_physics = other_entry.value_ptr.*;
                const other_entity = entity_manager.entities.get(other_id);
                if (!other_entity.active) continue;

                // Calculate distance between entities
                const dx = entity.position.x - other_entity.position.x;
                const dy = entity.position.y - other_entity.position.y;
                const distance = @sqrt(dx * dx + dy * dy);
                const min_distance = physics.radius + other_physics.radius;

                // Check for collision
                if (distance < min_distance) {
                    // Calculate collision response
                    const overlap = min_distance - distance;
                    const nx = dx / distance;
                    const ny = dy / distance;

                    // Move entities apart (simple resolution)
                    const move_x = nx * overlap * 0.5;
                    const move_y = ny * overlap * 0.5;

                    var updated_entity = entity;
                    updated_entity.position.x += move_x;
                    updated_entity.position.y += move_y;
                    entity_manager.entities.set(entity_id, updated_entity);

                    var updated_other = other_entity;
                    updated_other.position.x -= move_x;
                    updated_other.position.y -= move_y;
                    entity_manager.entities.set(other_id, updated_other);

                    // Update velocities (elastic collision)
                    // Scale impulse by fixed timestep to maintain consistent behavior
                    const relative_vel_x = physics.velocity.x - other_physics.velocity.x;
                    const relative_vel_y = physics.velocity.y - other_physics.velocity.y;
                    const impulse = -(1.5 * (relative_vel_x * nx + relative_vel_y * ny)) /
                        (1.0 / physics.mass + 1.0 / other_physics.mass);

                    const impulse_scale = dt / (1.0 / 60.0);
                    physics.velocity.x += (impulse * nx / physics.mass) * impulse_scale;
                    physics.velocity.y += (impulse * ny / physics.mass) * impulse_scale;

                    var other_phys = other_physics;
                    other_phys.velocity.x -= (impulse * nx / other_phys.mass) * impulse_scale;
                    other_phys.velocity.y -= (impulse * ny / other_phys.mass) * impulse_scale;
                    self.components.put(other_id, other_phys) catch unreachable;
                }
            }

            // Update the physics component
            self.components.put(entity_id, physics) catch unreachable;
        }
    }

    pub fn applyForce(self: *PhysicsSystem, entity_id: usize, force: ray.Vector2) void {
        if (self.components.getPtr(entity_id)) |physics| {
            physics.velocity.x += force.x;
            physics.velocity.y += force.y;
        }
    }
};

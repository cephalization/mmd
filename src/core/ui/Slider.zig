// Slider UI component. Rendered by raylib
// Has a draw function that can be called by the renderer each frame
// Has a value that can be set and retrieved
// Has a min and max value that can be set and retrieved
// Has a step value that can be set and retrieved
// Has a callback function that can be set, called when the slider is changed with the new value

const ray = @import("../../raylib.zig");
const std = @import("std");
pub const WIDTH = 100;
pub const HEIGHT = 20;
const THUMB_RADIUS = 10;
const THUMB_COLOR = ray.WHITE;
const TRACK_COLOR = ray.RED;

pub const Slider = struct {
    value: f32,
    min: f32,
    max: f32,
    step: f32,
    startX: i32,
    startY: i32,
    is_dragging: bool,
    label: [:0]const u8,

    pub fn init(
        value: f32,
        startX: f32,
        startY: f32,
        min: f32,
        max: f32,
        step: ?f32,
        label: [:0]const u8,
    ) Slider {
        const stepValue = step orelse 1;
        return .{
            .value = value,
            .min = min,
            .max = max,
            .step = stepValue,
            .startX = @as(i32, @intFromFloat(startX)),
            .startY = @as(i32, @intFromFloat(startY)),
            .is_dragging = false,
            .label = label,
        };
    }

    pub fn deinit(_: *Slider) void {
        // nothing to deinit
    }

    fn valueToPosition(self: *Slider) i32 {
        // Convert to normalized position (0.0 to 1.0) using floating point math
        const normalized = (self.value - self.min) / (self.max - self.min);
        // Scale to width and add offset
        return self.startX + @as(i32, @intFromFloat(normalized * @as(f32, @floatFromInt(WIDTH))));
    }

    fn positionToValue(self: *Slider, pos: i32) f32 {
        const normalized = @as(f32, @floatFromInt(pos - self.startX)) / @as(f32, @floatFromInt(WIDTH));
        const clamped = @max(0, @min(normalized, 1));
        return self.min + (self.max - self.min) * clamped;
    }

    pub fn update(self: *Slider) void {
        const mouse_pos = ray.getMousePosition();
        const thumb_pos = ray.Vector2{
            .x = @as(f32, @floatFromInt(valueToPosition(self))) + THUMB_RADIUS,
            .y = @as(f32, @floatFromInt(self.startY)) + HEIGHT / 2,
        };

        // Check if mouse is over thumb
        const dx = mouse_pos.x - thumb_pos.x;
        const dy = mouse_pos.y - thumb_pos.y;
        const distance = @sqrt(dx * dx + dy * dy);
        const is_over_thumb = distance <= THUMB_RADIUS;

        // Handle dragging
        if (ray.isMouseButtonDown(ray.MOUSE_BUTTON_LEFT)) {
            if (is_over_thumb or self.is_dragging) {
                self.is_dragging = true;
                const new_value = positionToValue(self, @as(i32, @intFromFloat(mouse_pos.x)));
                self.value = new_value;
            }
        } else {
            self.is_dragging = false;
        }
    }

    pub fn draw(self: *Slider) void {
        // we need to draw a slider track with two circles and a rectangle
        // the circles are at each end of the rectangle, and simulate rounded ends
        ray.drawCircle(self.startX, self.startY + HEIGHT / 2, HEIGHT / 2, TRACK_COLOR);
        ray.drawCircle(self.startX + WIDTH, self.startY + HEIGHT / 2, HEIGHT / 2, TRACK_COLOR);
        ray.drawRectangle(self.startX, self.startY, WIDTH, HEIGHT, TRACK_COLOR);

        // draw the thumb at the current value
        ray.drawCircle(self.valueToPosition(), self.startY + HEIGHT / 2, THUMB_RADIUS, THUMB_COLOR);

        if (self.label.len > 0) {
            ray.drawText(self.label, self.startX, self.startY - 20, 14, ray.WHITE);
        }
    }

    pub fn getValue(self: *Slider) f32 {
        return self.value;
    }

    pub fn setValue(self: *Slider, value: f32) void {
        self.value = value;
    }

    pub fn drawAndUpdate(self: *Slider) void {
        Slider.update(self);
        Slider.draw(self);
    }
};

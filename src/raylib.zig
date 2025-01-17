const std = @import("std");

pub const c = @cImport({
    @cInclude("raylib.h");
});

// Re-export Window related types
pub const getWindowHandle = c.GetWindowHandle;

// Re-export common types and constants with more Zig-friendly names
pub const Color = c.Color;
pub const Vector2 = c.Vector2;
pub const Vector3 = c.Vector3;
pub const Rectangle = c.Rectangle;

pub const KeyboardKey = enum(c_int) {
    KEY_NULL = 0,
    KEY_APOSTROPHE = 39,
    KEY_COMMA = 44,
    KEY_MINUS = 45,
    KEY_PERIOD = 46,
    KEY_SLASH = 47,
    KEY_ZERO = 48,
    KEY_ONE = 49,
    KEY_TWO = 50,
    KEY_THREE = 51,
    KEY_FOUR = 52,
    KEY_FIVE = 53,
    KEY_SIX = 54,
    KEY_SEVEN = 55,
    KEY_EIGHT = 56,
    KEY_NINE = 57,
    KEY_SEMICOLON = 59,
    KEY_EQUAL = 61,
    KEY_A = 65,
    KEY_B = 66,
    KEY_C = 67,
    KEY_D = 68,
    KEY_E = 69,
    KEY_F = 70,
    KEY_G = 71,
    KEY_H = 72,
    KEY_I = 73,
    KEY_J = 74,
    KEY_K = 75,
    KEY_L = 76,
    KEY_M = 77,
    KEY_N = 78,
    KEY_O = 79,
    KEY_P = 80,
    KEY_Q = 81,
    KEY_R = 82,
    KEY_S = 83,
    KEY_T = 84,
    KEY_U = 85,
    KEY_V = 86,
    KEY_W = 87,
    KEY_X = 88,
    KEY_Y = 89,
    KEY_Z = 90,
    KEY_LEFT_BRACKET = 91,
    KEY_BACKSLASH = 92,
    KEY_RIGHT_BRACKET = 93,
    KEY_GRAVE = 96,
    KEY_SPACE = 32,
    KEY_ESCAPE = 256,
    KEY_ENTER = 257,
    KEY_TAB = 258,
    KEY_BACKSPACE = 259,
    KEY_INSERT = 260,
    KEY_DELETE = 261,
    KEY_RIGHT = 262,
    KEY_LEFT = 263,
    KEY_DOWN = 264,
    KEY_UP = 265,
    KEY_PAGE_UP = 266,
    KEY_PAGE_DOWN = 267,
    KEY_HOME = 268,
    KEY_END = 269,
    KEY_CAPS_LOCK = 280,
    KEY_SCROLL_LOCK = 281,
    KEY_NUM_LOCK = 282,
    KEY_PRINT_SCREEN = 283,
    KEY_PAUSE = 284,
    KEY_F1 = 290,
    KEY_F2 = 291,
    KEY_F3 = 292,
    KEY_F4 = 293,
    KEY_F5 = 294,
    KEY_F6 = 295,
    KEY_F7 = 296,
    KEY_F8 = 297,
    KEY_F9 = 298,
    KEY_F10 = 299,
    KEY_F11 = 300,
    KEY_F12 = 301,
    KEY_KP_0 = 320,
    KEY_KP_1 = 321,
    KEY_KP_2 = 322,
    KEY_KP_3 = 323,
    KEY_KP_4 = 324,
    KEY_KP_5 = 325,
    KEY_KP_6 = 326,
    KEY_KP_7 = 327,
    KEY_KP_8 = 328,
    KEY_KP_9 = 329,
};

pub const MouseButton = c.MouseButton;

// Common colors
pub const RAYWHITE = c.RAYWHITE;
pub const BLACK = c.BLACK;
pub const WHITE = c.WHITE;
pub const RED = c.RED;
pub const GREEN = c.GREEN;
pub const BLUE = c.BLUE;

// Re-export common functions with Zig naming conventions
pub const init = c.InitWindow;
pub const close = c.CloseWindow;
pub const shouldClose = c.WindowShouldClose;
pub const beginDrawing = c.BeginDrawing;
pub const endDrawing = c.EndDrawing;
pub const clearBackground = c.ClearBackground;
pub const drawFPS = c.DrawFPS;
pub const setTargetFPS = c.SetTargetFPS;
pub const getFrameTime = c.GetFrameTime;
pub const getTime = c.GetTime;
pub fn isKeyUp(key: KeyboardKey) bool {
    return c.IsKeyUp(@intFromEnum(key));
}

pub fn isKeyDown(key: KeyboardKey) bool {
    return c.IsKeyDown(@intFromEnum(key));
}

pub fn isKeyPressed(key: KeyboardKey) bool {
    return c.IsKeyPressed(@intFromEnum(key));
}

pub const drawText = c.DrawText;
pub const drawRectangle = c.DrawRectangle;
pub const drawCircle = c.DrawCircle;

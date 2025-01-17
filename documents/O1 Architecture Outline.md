# O1 Architecture Outline 1-16-2025

Here’s a broad outline of how you might organize your code to accommodate both singleplayer and multiplayer modes, while leaving room for future WASM support. The key idea is to separate your “core game logic” from any platform- or I/O-specific concerns (like networking, file I/O, rendering, etc.). This way, your game logic remains portable (so you can compile it to WASM), and your higher-level modules can wrap that logic for whichever platform they are running on (native, WASM, server, etc.).

---

## 1. Core (Platform-Agnostic) Game Module

Think of this as the “pure logic” code of your game. It should:

- Own and manage the game state (player data, entities, positions, etc.).  
- Provide functions/methods to manipulate that state (move entities, process collisions, etc.).  
- Be free of direct I/O (no sockets, no file access, no direct calls to the OS).

You might end up with a structure like:

```c
// src/Core.zig
pub const State = struct {
  // All your game data (entities, positions, etc.)
  // No networking, no windowing, just raw game logic.
  pub fn init() State {
    // Initialize your game state here
    return State{};
  }
  pub fn update(state: State, delta_time: f32) void {
    // Update your game logic each frame/tick: movement, collisions, etc.
  }
  pub fn handleInput(state: State, input: UserInput) void {
    // Handle “up”, “down”, “spawn”, etc.
    // Potentially invoked by singleplayer or multiplayer logic.
  }
};
```

By keeping this core module free of external dependencies (beyond math, standard library, etc.), you can compile it for native or WASM without worry. Multiplayer or singleplayer modes can both use the same APIs to manipulate game state.

---

## 2. Platform-Specific Wrappers

You’ll likely still need “system” modules that handle:

- Rendering (e.g., Mach’s GPU code).  
- Windowing and input events.  
- Network I/O for multiplayer (sockets, WebSockets if WASM, etc.).  

You might have something like:

```c
// src/Platform.zig
pub const Platform = struct {
  // Possibly references to Mach objects, window object, etc.
  pub fn init() !Platform {
    // Initialize Mach, create windows, etc.
    return Platform{};
  }
  pub fn pollEvents(self: Platform) !?UserInput {
    // Convert Mach event system to your UserInput struct
    // Return the input event or null if none
  }
  pub fn renderFrame(self: Platform, state: Core.State) !void {
    // Use Mach GPU calls to render the given state.
    // This organizes your “render only” pipeline outside your core logic.
  }
};
```

Or, for networking:

```c
// src/Net.zig
pub const Network = struct {
  // Underlying socket/websocket/etc. references
  pub fn init(conf: NetworkConfig) !Network {
    // Initialize platform-specific networking: native or WASM
    return Network{};
  }
  pub fn pollMessages(self: Network) ![]const u8 {
    // Read from network buffers, return messages to be processed
  }
  pub fn sendMessage(self: Network, data: []const u8) !void {
    // Send data out to server or clients
  }
};
```

This lets you keep the logic for how you send/receive data separate from “what the game logic does with it.”

---

## 3. Singleplayer vs. Multiplayer

In singleplayer mode, you might never create a network interface at all. Your “update loop” simply calls:

1. platform.pollEvents() → pass to core.handleInput()  
2. core.update()  
3. platform.renderFrame()  

In multiplayer, you have an extra step:

1. Read from the network (network.pollMessages()), apply relevant state updates to your Core.State (maybe these are authoritative commands from a host, or you are the server receiving inputs from clients).  
2. Possibly broadcast your updated game state to peers.  
3. Poll local input events, merge with incoming network events, call core.handleInput().  
4. Finally, call core.update() and platform.renderFrame().

Either scenario reuses the exact same “Core” logic.

---

## 4. Synchronization Approach

A straightforward solution is to keep your core logic authoritative on the server side, then treat the client logic as a “mirror”:

- Client sends local input: “Move Right,” “Spawn,” etc.  
- Server updates the authoritative State.  
- Server sends back the updated chunk of state (or just enough data to keep the client in sync).  
- Client receives state updates and overwrites or interpolates its local state.

In a strictly peer-to-peer scenario, you can pick one peer to be “host” or run a distributed lockstep approach. The important part is: the code that manipulates State remains the same, it’s just triggered differently depending on singleplayer or multiplayer usage.

---

## 5. Future WASM Support

The above split means that to build for WASM, you only:

- Compile your “Core” logic.  
- Rewrite a WASM-friendly “Platform” layer with WebSockets, HTML canvas or WebGPU calls (some of which Zig’s Mach may facilitate in the future).  
- Keep the same core logic intact.  

If your “Core” never calls into OS-specific functions, you should be able to cross-compile cleanly. Only the platform-specific wrappers (rendering, network I/O, etc.) require separate WASM or native variants.

---

## Summary

1. Put the main game logic in a data-structure-oriented “Core” module.  
2. Expose the things you need for input handling and updating in platform-agnostic functions.  
3. Write platform-specific wrappers (Mach-based rendering, network modules, OS input pollers).  
4. Singleplayer is just “Core + local platform wrappers.”  
5. Multiplayer is “Core + local platform wrappers + network wrapper.”  
6. WASM is “Core + WASM-based wrappers for rendering, input, networking.”  

This layered approach gives you the flexibility to reuse your core game logic while keeping your codebase organized for future expansions (multiplayer, WASM, etc.).

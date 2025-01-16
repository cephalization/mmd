# MMD

Mach Multiplayer Demo

## Setup

- Download [zigup](https://github.com/marler8997/zigup?tab=readme-ov-file)
  - Put it in your path, `.local/bin` is a good place on macOS

```sh
# we use zigup to install this zig version, required by mach, the zig game engine
zigup 0.14.0-dev.2577+271452d22
```

- Download deps and run the game

```sh
zig build run
```

## Details

- [mach](https://github.com/hexops/mach)
- Based on [custom renderer example](https://github.com/hexops/mach/tree/main/examples/custom-renderer)
- Build setup based on `zig init` and [random build help post](https://ziggit.dev/t/importing-zig-dependencies/4230/5)

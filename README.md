# MMD

Mini Multiplayer Demo

## Setup

- Download [zigup](https://github.com/marler8997/zigup?tab=readme-ov-file)
  - Put it in your path, `~/.local/bin` is a good place on macOS

```sh
# we use zigup to install this zig version
zigup 0.14.0-dev.2577+271452d22
```

- Download deps and run the game

```sh
zig build run
```

## Details

- [raylib](https://github.com/raysan5/raylib)
- Build setup based on `zig init` and [random build help post](https://ziggit.dev/t/importing-zig-dependencies/4230/5)

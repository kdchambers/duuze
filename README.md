# duuze

A fast, multi-threaded clone of `du -sh <dir_path`. 

## Running

```sh
zig build run -Doptimize=ReleaseSafe -- <dir_path>
```

Or 

```sh
zig build -Doptimize=ReleaseSafe
zig-out/bin/duuze <dir_path>
```

Zig version: [0.12.0-dev.2158+4f2009de1](https://ziglang.org/builds/zig-linux-x86_64-0.12.0-dev.2158+4f2009de1.tar.xz)

# scoutd

A minimalist `init(1)` daemon for Firecracker microVMs.

`scoutd` runs as PID 1 to boot a workload cleanly, supervise it, and shut the guest down deterministically. It is a
sub-100KB static binary with zero dependencies.

## Release artifacts

The primary runtime artifact is a minimal bootable ext4 rootfs image for Firecracker guests.

## Build

Current local build command:

```bash
zig build
```

## Status
scoutd is being built as a purpose-specific guest init for SpaceScale, not as a general-purpose Linux init system.


## Contributing

Feel free to open an issue or submit a PR
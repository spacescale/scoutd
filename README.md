# scoutd

A minimalist `init(1)` daemon for Firecracker microVMs.

`scoutd` runs as PID 1 to boot a workload cleanly, supervise it, and shut the guest down deterministically. It is a
sub-100KB static binary with zero dependencies.

## Build

Current local build command:

```bash
zig build
```

## Contributing

if anything looks like bug, or you just want to assist. Feel free to open an issue or submit a PR
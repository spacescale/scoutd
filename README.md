# scoutd

A minimalist `init(1)` daemon for Firecracker microVMs.

`scoutd` runs as PID 1 to boot a workload cleanly, supervise it, and shut the guest down deterministically. It is a
sub-100KB static binary with zero dependencies.scoutd is being built as a purpose-specific guest init for SpaceScale's
. It is not intended to be a general-purpose Linux init system like systemd

## Roadmap & Vision

scoutd is being built in strict, linear architectural phases to ensure safety and determinism at the lowest levels of
the Firecracker guest before moving up the stack.

- Phase 1: Init Foundation (Completed) - Establishing scoutd as a safe PID 1 process with a fail-fast panic path and
  basic filesystem mounting
- Phase 2: Host/Guest Wiring (Current Focus) - Establishing the vsock control plane and bringing up guest networking to
  parse the MMDS payload
- Workload Execution (Upcoming) - Forking/executing the actual payloads, wiring stdout/stderr telemetry to the host, and
  handling deterministic guest shutdown

## Release artifacts

The primary runtime artifact is a minimal bootable ext4 rootfs image for Firecracker guests.

## Build

Current local build command:

```bash
zig build
```

## Contributing

We manage all day-to-day engineering and active issues on our GitHub Project Board.Feel free to open an issue or submit
a PR
# scoutd

`scoutd` is a tiny guest side init and workload launcher for Firecracker microVMs.
It runs as PID 1 inside the guest and exists for one reason: boot the workload cleanly, supervise it correctly, and shut
the guest down deterministically.
This repository is intentionally narrow. `scoutd` is not a general purpose init system, not a config management agent,
and not a second control plane. It is a small, production focused guest runtime component.

## Why this exists

A Firecracker guest still needs a real PID 1.
Without that, the guest has no reliable process reaper, no clean signal forwarding, no deterministic shutdown path, and
no safe place to perform minimal boot initialization before the workload starts.
`scoutd` fills that gap with a tiny static binary designed for dense microVM workloads.

## Why Zig

`scoutd` runs inside every guest, so its footprint matters.
Zig is a strong fit for this kind of software because it gives us:

- a very small static binary
- direct control over Linux syscalls
- no runtime garbage collector
- deterministic startup behavior
- explicit memory management in early boot code
  This is the kind of software where small, boring, and predictable wins.

## What scoutd is responsible for

`scoutd`  owns only the guest side responsibilities that belong to PID 1:

- mount the minimal virtual filesystems needed by userspace
- read minimal early boot data from the kernel command line
- bring up basic guest networking
- fetch workload metadata from Firecracker MMDS
- launch the workload process
- reap zombies
- forward signals to the workload process group
- report terminal status back to the host
- power the guest off cleanly when the workload exits

## Build

Current local build command:

```bash
zig build-exe main.zig -O ReleaseSmall -target x86_64-linux-musl
```

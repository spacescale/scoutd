# scoutd

`scoutd` is the guest side PID 1 and workload launcher for SpaceScale Firecracker microVMs.

Firecracker gives SpaceScale the hardware boundary. `scoutd` gives the guest a tiny, reliable init process that can boot the workload cleanly inside that boundary.

The host daemon `scaled` owns host preflight, scheduling, asset management, and Firecracker control. `scoutd` owns only the guest boot path inside the microVM.

## Why Zig

`scoutd` runs inside every guest. It must be extremely small, deterministic, and easy to reason about as PID 1.

Zig is a good fit because it gives us:

- a tiny static binary
- no GC runtime overhead
- direct Linux syscall level control
- predictable startup behavior
- explicit memory management for init code

## Role in the architecture

The current SpaceScale direction is:

- `scalecp` resolves product plans into one concrete `MicroVMShape`
- `scaled` owns host preflight, node capacity, and launch orchestration
- `scoutd` boots inside the guest and starts the customer payload

`scoutd` should stay boring. It is not a second control plane. It is not a full guest agent. It is a very small init and launcher.

## Boot contract

`scoutd` should read two classes of boot data.

### Kernel cmdline

Kernel cmdline is only for minimal early boot data that must exist before the guest can talk to anything else.

That includes:

- enough network bootstrap data to bring up `eth0`
- `init=/scoutd` or equivalent init handoff

Kernel cmdline must not carry secrets or the full workload configuration.

### MMDS

After basic guest networking is up, `scoutd` should fetch the real runtime payload from Firecracker MMDS.

That payload should carry the workload metadata needed to start the customer process.

Examples:

- `microvm_id`
- command
- args
- environment variables
- working directory
- runtime port

This keeps early boot bootstrap small and keeps the richer runtime contract out of the kernel command line.

## First production scope

The first real version of `scoutd` should do only this:

1. mount the minimal virtual filesystems needed by userspace
2. read kernel cmdline bootstrap values
3. bring up `eth0`
4. fetch MMDS runtime metadata
5. fork and exec the customer workload
6. act as PID 1 and reap zombies
7. forward signals to the workload process group
8. exit with the workload status

That is enough to make the guest boot path real.

## Out of scope for the first cut

These things are valid later, but they should not bloat the first version:

- guest side snapshot coordination
- complex multi process supervision
- service management inside the guest
- rich guest telemetry agents
- long lived vsock RPC protocols

## About vsock

SpaceScale may use vsock later for richer host guest communication such as logs, health, and control. `scoutd` should be designed so a vsock transport can be added later without changing its core PID 1 behavior.

The first version does not need vsock to boot a workload correctly.

## Roadmap

The roadmap for `scoutd` is intentionally staged so the guest contract stays small and correct.

### Phase 1

Build the minimal PID 1.

- mount the required virtual filesystems
- parse kernel cmdline bootstrap data
- bring up guest networking
- fork and exec the workload
- reap zombies
- forward signals

### Phase 2

Fetch runtime metadata from MMDS.

- fetch workload command and args
- fetch environment variables
- fetch runtime port and guest identity
- start the workload from MMDS supplied metadata

### Phase 3

Add a richer host and guest transport.

- vsock for logs
- vsock for health and status
- vsock for later control messages

### Phase 4

Add later guest features only when the platform actually needs them.

- snapshot coordination
- restore hooks
- richer telemetry
- more advanced lifecycle control

## Build

Current local build command:

```bash
zig build-exe main.zig -O ReleaseSmall -target x86_64-linux-musl
```

This repository is still an early stub. The first implementation milestone is to lock the guest boot contract and build a minimal PID 1 that can reliably launch one workload process inside a Firecracker guest.

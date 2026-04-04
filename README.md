# scoutd 🛰️

`scoutd` is the dedicated guest agent and PID 1 supervisor for SpaceScale Firecracker microVMs.

In a bare-metal hyperscaler environment, Firecracker provides the hardware boundary, but the guest OS still requires a reliable supervisor to handle initialization, secret injection, and process reaping. `scoutd` is deployed directly into the customer's `ext4` root filesystem to bridge the gap between the isolated VM and the host control plane.

## Why Zig?
SpaceScale workloads demand extreme density. A standard Go GC Runtime requires 5MB+ of memory overhead just to boot. Hypervisors footprint must be mathematically invisible. Written in Zig, `scoutd` is statically compiled against `musl`, resulting in a microscopic binary (< 500KB) with zero runtime GC overhead, deterministic memory allocation, and sub-millisecond execution times. 

## Core Architecture (PID 1)
When Firecracker boots the Linux kernel, `scoutd` is the first process executed. It guarantees the safe execution of customer payloads by handling:

1. **System Initialization:** Mounts essential virtual filesystems (`/proc`, `/sys`, `/dev`).
2. **Network Bring-Up:** Activates `eth0` and configures routing based on host-provided boot arguments.
3. **MMDS Integration:** Interfaces with the Firecracker Microvm Metadata Service (`169.254.169.254`) to securely fetch and inject encrypted customer environment variables.
4. **Payload Ignition:** Safely executes the customer's application via `fork()` and `execve()`.
5. **Process Supervision (The Reaper):** Operates as the absolute PID 1 zombie reaper, catching crashing sub-processes to prevent VM memory leaks.
6. **Telemetry & Log Shipping:** Intercepts `stdout`/`stderr` from the customer payload and pipes it over the Firecracker serial console (or vsock) back to the `scaled` host daemon.

*(Future Scope: In-memory snapshot coordination and rapid restore signaling for sub-50ms cold starts).*


```bash
# Build a static release binary for x86_64 Firecracker guests
zig build-exe src/main.zig -O ReleaseSmall -target x86_64-linux-musl

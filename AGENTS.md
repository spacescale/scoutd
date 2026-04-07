## Context
You are writing `scoutd`, a custom PID 1 (init system) and workload supervisor written in Zig. It runs inside a Firecracker microVM boundary.
If `scoutd` crashes, exits, or leaks memory, the Linux kernel panics and the virtual machine dies. There is no safety net, no operating system to clean up after you, and no standard out.

You must write paranoid, hyper-optimized, blocking state-machine code.

## 1. Build and Target Constraints
* **Always Static:** The binary must be compiled with `-target x86_64-linux-musl`.
* **Zero Dynamic Linking:** Never assume the presence of `glibc` or dynamic shared objects (`.so`). The rootfs is completely bare.
* **No C Dependencies:** Rely exclusively on Zig's standard library (`std.os.linux`, `std.http`, `std.json`). Do not link external C libraries.

## 2. Memory Management (The No-Leak Rule)
* **No General Purpose Allocator:** Never use `std.heap.GeneralPurposeAllocator`.
* **Static / Fixed Buffers Only:** For early boot, use `std.heap.FixedBufferAllocator` with a small, statically allocated byte array (e.g., 64KB).
* **Arena for MMDS:** If parsing the MMDS JSON payload, use an `ArenaAllocator` backed by a fixed buffer. You never need to call `free()`; the memory will persist for the lifespan of the VM.
* **No Hidden Allocations:** Never use string concatenation or functions that allocate implicitly without passing an allocator.

## 3. The PID 1 Contract & Safety
* **Custom Panic Handler:** You MUST override `pub fn panic`. If vsock is not up, the panic handler must immediately execute the `LINUX_REBOOT_CMD_POWER_OFF` syscall. If vsock is up, dump the stack trace to the vsock file descriptor, then power off.
* **The Infinite Supervisor:** When acting as PID 1, the parent process must enter an infinite `while` loop calling a **blocking** `waitpid(-1, &status, 0)`.
* **Zombie Reaping:** You must explicitly check the PID returned by `waitpid`. If it is the main payload, exit the loop and shut down. If it is an orphaned background daemon, ignore it and continue the `waitpid` loop to clear the zombie.
* **No Busy Waiting:** Never use `WNOHANG` in a `while(true)` loop. `scoutd` must consume 0% CPU while the customer payload is running.

## 4. Host-Guest IPC & Logging (Vsock Only)
* **Serial is Dead:** Do NOT write to `/dev/ttyS0` or use standard `std.debug.print` for production logging. Emulated serial causes VM exits and destroys boot times.
* **Vsock Lifeline:** All communication with the host daemon (`scaled`) must happen over `AF_VSOCK`.
* **The Dup2 Routing:** Before calling `execve()` on the customer payload, the child process must use `dup2()` to overwrite `STDOUT_FILENO` (1) and `STDERR_FILENO` (2) with a dedicated log vsock file descriptor.
* **Process Groups:** Always put the executed child process in its own process group using `setpgid(0, 0)` so signals can be forwarded cleanly.

## 5. Linux Syscalls (Direct OS Interaction)
* **Use Zig's Wrappers:** Prefer `std.os.linux` native syscalls (e.g., `std.os.linux.mount`, `std.os.linux.fork`, `std.os.linux.execve`).
* **Networking via ioctl:** Do not use `ip` or `ifconfig` shell commands. Bring up `lo` and `eth0` using direct `ioctl` syscalls with the appropriate bitmasks (`IFF_UP | IFF_RUNNING`).
* **Flush Before Death:** Always call `std.os.linux.sync()` before triggering the ACPI power-off syscall to ensure guest disk writes are persisted.

## 6. Error Handling
* **No Silent Failures:** Use error unions (`!`) for every function that can fail.
* **Fail Fast:** If a critical boot step fails (e.g., mounting `/proc`, bringing up `eth0`, or connecting the control vsock), do not attempt to recover. Log the error to vsock (if available) and execute the power-off syscall immediately.
* **Use `errdefer`:** Use `errdefer` to clean up file descriptors or sockets if a complex function fails halfway through execution.

# Zig Idioms & Best Practices - AI Agent Directives

## Context
You are writing modern, idiomatic Zig code (0.13.0+). The developer is building hyper-optimized systems software. Do not write Go, Rust, or C++ logic translated into Zig. Write native, explicit Zig.

## 1. File & Folder Organization
* **Flat is Better:** Do not use deeply nested directories or Go's standard layout (no `cmd/`, no `pkg/`).
* **The Root:** `build.zig` and `build.zig.zon` live at the repository root.
* **The Source:** All code lives in `src/`.
    * `src/main.zig` (The entry point).
    * `src/net.zig` (Domain-specific logic).
    * `src/mmds.zig` (Domain-specific logic).
* **Imports:** Use `@import("file.zig")` directly. Do not over-engineer module exports for a single binary project.

## 2. Naming Conventions (Strict)
* **Files:** `snake_case.zig`.
* **Functions & Variables:** `camelCase`.
* **Types, Structs, Enums, Error Sets:** `PascalCase`.
* **Constants:** `PascalCase` (e.g., `const MaxBuffer = 1024;`). Do not use screaming snake case (`MAX_BUFFER`).
* **The `Self` Idiom:** When writing methods inside a struct, always alias the struct type to `Self` at the top, and use `self: *Self` as the receiver parameter.

## 3. Memory & Allocators (The "No Hidden Cost" Rule)
* **Never hide allocations.** If a function allocates memory, its first parameter MUST be `allocator: std.mem.Allocator`.
* **Never use global allocators.** * **Always return memory control.** If a function allocates and returns a slice or pointer, the caller is responsible for freeing it. Clearly document this or use an `ArenaAllocator` at the top level to manage the entire lifecycle.

## 4. Error Handling (The `!` Paradigm)
* **No Sentinel Values:** Do not return `-1` or `null` to indicate a failure. Use Zig's Error Unions (e.g., `!void`, `!usize`).
* **Explicit Custom Errors:** Define tightly scoped error sets for domain logic (e.g., `const NetworkError = error{ Timeout, HostUnreachable };`).
* **Bubble Up:** Use the `try` keyword aggressively to pass errors up the stack.
* **No `catch unreachable` in Production:** Unless you are absolutely, mathematically certain a function cannot fail, handle the error or return it. Do not use `catch unreachable` as a lazy shortcut.

## 5. Control Flow & Cleanup (`defer`)
* **Use `defer` immediately:** The moment you open a file, allocate memory, or acquire a resource, put the `defer close()` or `defer free()` on the very next line.
* **Master `errdefer`:** If you are building a complex state (like initializing a struct with multiple allocations) and it fails halfway through, use `errdefer` to clean up the partially allocated state before the function returns the error.

## 6. Structs vs. Objects
* **No OOP:** Zig is not object-oriented. Do not try to build inheritance, classes, or Go-style interfaces.
* **Data Oriented:** Use simple structs to group data. Attach functions to those structs purely for namespace organization.
* **Optionals (`?T`):** Use optionals heavily instead of pointers that might be null. Always handle the null case explicitly with `if (val) |v| { ... }`.

## 7. Testing
* **Colocate Tests:** Write `test "description" { ... }` blocks directly at the bottom of the file where the logic is defined.
* **Test Allocator:** Inside tests, always use `std.testing.allocator`. It will automatically catch and report memory leaks when you run `zig build test`.
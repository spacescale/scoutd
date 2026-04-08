//! This module serves as the entry point and orchestrates core system services.

const std = @import("std");
const linux = std.os.linux;

/// Custom panic implementation to handle system-wide crashes gracefully.
   const panic_impl = @import("panic.zig");

/// Handles mounting and unmounting of local and network filesystems.
   const mounts = @import("mounts.zig");

/// Responsible for reaping "zombie" child processes in the PID 1 namespace.
   const reaper = @import("reaper.zig");

/// Manages system power states (shutdown, reboot, suspend).
   const power = @import("power.zig");

pub fn main() !void {
    // Check if we are running as the init process (PID 1).
    // The getpid() system call returns the Process ID of the current process.
    // In a container or a real Linux system, PID 1 has special responsibilities
    // like reaping orphan processes and managing system initialization.
    if (linux.getpid() != 1) {
        return error.MustRunasPid1;
    }

    try mounts.moundEssential();
    // Issue 2 stops here on purpose.
    // We are proving the PID 1 foundation before networking or MMDS.
    try reaper.idleLoop();

}

pub fn  panic(msg: []const u8, st: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    panic_impl.panic(msg, st, addr);
}

// This test block acts as a "Recursive Test Runner."
// In Zig, imports are lazy—if a module isn't used, the compiler ignores it completely.
// By using the discard operator (_ =), we force the compiler to "touch" these modules
// during 'zig test', which triggers it to find and run any 'test' blocks inside them.
test {
    _ = mounts;
    _ = reaper;
    _ = power;
}

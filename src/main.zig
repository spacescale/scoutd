//! This module serves as the entry point and orchestrates core system services.

const std = @import("std");
const linux = std.os.linux;

const panic_impl = @import("panic.zig");
const mounts = @import("mounts.zig");
const reaper = @import("reaper.zig");
const power = @import("power.zig");


pub fn main() !void {
    if (linux.getpid() != 1) {
        return error.MustRunAsPid1;
    }

    try mounts.mountEssential();
    reaper.supervise();
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

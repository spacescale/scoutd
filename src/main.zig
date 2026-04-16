//! This module serves as the entry point and orchestrates core system services.

const std = @import("std");
const linux = std.os.linux;

const panic_impl = @import("panic.zig");
const mounts = @import("mounts.zig");
const reaper = @import("reaper.zig");
const power = @import("power.zig");
const cmdline = @import("cmdline.zig");
const vsock = @import("vsock.zig");

pub fn main() !void {
    if (linux.getpid() != 1) {
        return error.MustRunAsPid1;
    }

    // Bring up the host control path before anything else in userland.
    //
    // Why this comes before mounts and cmdline parsing:
    // - if any later boot phase panics, we want the panic handler to already
    //   have a real host-visible transport
    // - once `connectChannels()` returns, the control FD has already been
    //   registered inside `vsock.zig`
    // - from that point on, panics can report over vsock and we no longer need
    //   stderr as a backup path
    const channels = vsock.connectChannels() catch @panic("scoutd: fatal vsock bootstrap error");
    vsock.sendHello(channels.control_fd) catch @panic("scoutd: fatal control hello failure");

    try mounts.mountEssential();
    const bootstrap = cmdline.readBootstrap() catch @panic("scoutd: fatal cmdline bootstrap error");
    _ = bootstrap;

    vsock.writeLog(channels.log_fd, "scoutd: log channel ready\n") catch @panic("scoutd: fatal log channel bootstrap failure");

    reaper.supervise();
}

pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
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
    _ = cmdline;
    _ = vsock;
}

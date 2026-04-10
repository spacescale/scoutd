const std = @import("std");
const linux = std.os.linux;
const power = @import("power.zig");

pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    _ = st;
    _ = addr;

    // Log the error message to the system console (STDERR)
    bestEffortWrite(msg);
    bestEffortWrite("\n");

    power.powerOffNow();
}

fn bestEffortWrite(msg: []const u8) void {
    _ = linux.write(linux.STDERR_FILENO, msg.ptr, msg.len);
}
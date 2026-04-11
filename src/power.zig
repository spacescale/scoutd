const std = @import("std");
const linux = std.os.linux;

/// Shuts down the system immediately.
/// This function is marked 'noreturn' because it either succeeds in powering off
/// the machine or triggers a CPU trap to halt execution.
pub fn powerOffNow() noreturn {
    linux.sync();
   _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
    @trap();
}
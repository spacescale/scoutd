const std = @import("std");
const linux = std.os.linux;

/// Shuts down the system immediately.
/// This function is marked 'noreturn' because it either succeeds in powering off
/// the machine or triggers a CPU trap to halt execution.
pub fn powerOffNow() noreturn {
    // Before we pull the power, we must ensure all data is safely written to disk.
    // linux.sync() tells the kernel to flush all "dirty" memory buffers to the 
    // physical storage device. Without this, your logs or files might be corrupted.
    linux.sync();

   _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);

    // If we are still here, it means the 'reboot' syscall failed (e.g., lack of permissions).
    // Since this function is 'noreturn', we CANNOT simply return to the caller.
    // @trap() triggers a platform-specific "Illegal Instruction" (like UD2 on x86).
    // This forces the CPU to halt or crash right here, ensuring we never return.
    @trap();
}
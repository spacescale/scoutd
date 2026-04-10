const std = @import("std");
const linux = std.os.linux;

/// Reaps all child processes until none are left.
/// As PID 1, we must reap orphans to prevent the process table from filling with zombies.
pub fn idleLoop() !void {
    while (true) {
        // A 4-byte buffer on the stack to hold the child's exit status.
        var status: u32 = 0;

        // linux.waitpid: 
        // -1: Wait for ANY child.
        // &status: Pointer to our local buffer where the kernel writes the exit status.
        // 0: Block (sleep) until a child dies.
        switch (std.posix.errno(linux.waitpid(-1, &status, 0))) {
            // Case 1: A child was successfully reaped.
            .SUCCESS => {},

            // Case 2: The syscall was interrupted by a signal. Just try again.
            .INTR => continue,

            // Case 3: No more children left to reap (ECHILD). We are done!
            .CHILD => return,

            // Case 4: Any other kernel error (e.g., .EFAULT or .EINVAL).
            else => |err| return errnoToError(err),
        }
    }
}

/// Maps raw Linux kernel error codes (errno) to semantically meaningful Zig errors.
fn errnoToError(err: linux.E) error{ Interrupted, NoChildren, Unexpected } {
    return switch (err) {
        .INTR => error.Interrupted,
        .CHILD => error.NoChildren,
        else => error.Unexpected,
    };
}

// Unit test to verify our error mapping logic is correct.
// This validates our "Translation Dictionary" from Linux-speak to Zig-speak.
test "errno mapping for wait loop is correct" {
    try std.testing.expectEqual(error.NoChildren, errnoToError(linux.E.CHILD));
    try std.testing.expectEqual(error.Interrupted, errnoToError(linux.E.INTR));
    try std.testing.expectEqual(error.Unexpected, errnoToError(linux.E.PERM));
}

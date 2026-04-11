const std = @import("std");
const linux = std.os.linux;
const power = @import("power.zig");

/// This is scoutd's permanent PID 1 supervision loop.
///
/// Why we need this:
/// - scoutd runs as PID 1 inside the guest.
/// - PID 1 is not a normal process. If it exits, the guest is effectively dead.
/// - That means we cannot write code that says "no children exist, so return".
/// - We must stay alive forever and let the kernel wake us only when work exists.
///
/// The core design here is synchronous signal handling.
///
/// Instead of installing asynchronous signal handlers, we do this:
/// 1. Tell the kernel to block the signals we care about.
/// 2. Sleep in `sigwaitinfo`.
/// 3. Wake up only when one of those signals is pending.
/// 4. Handle it from normal control flow.
///
/// This is safer because we are not executing arbitrary logic from an async signal
/// context. That keeps the code deterministic and avoids a whole category of hard
/// to reason about memory bugs.
pub fn supervise() noreturn {
    const set = blockHandledSignals();

    while (true) {
        const signo = waitForSignal(&set);
        handleSignal(signo);
    }
}

/// Build the set of signals scoutd wants to handle itself and then block them.
///
/// Linux concept:
/// - A signal is a tiny kernel notification delivered to a process.
/// - `SIGCHLD` means a child changed state, usually that it exited.
/// - `SIGTERM`, `SIGINT`, and `SIGQUIT` are termination-style requests.
///
/// By blocking these signals with `sigprocmask`, we tell the kernel:
/// "Do not interrupt my code asynchronously when these arrive. Queue them up and I will
/// fetch them explicitly with `sigwaitinfo`."
///
/// If this setup fails, PID 1 is not in a trustworthy state, so we fail fast by powering off.
fn blockHandledSignals() linux.sigset_t {
    // A signal set is a kernel bitset. Each bit corresponds to one signal number.
    // Starting from zero means: no signals are selected yet.
    var set = std.mem.zeroes(linux.sigset_t);

    // Add the signals that define Issue 2's process model.
    // `SIGCHLD` lets us reap zombies.
    // The termination signals give us an explicit shutdown path.
    linux.sigaddset(&set, linux.SIG.CHLD);
    linux.sigaddset(&set, linux.SIG.INT);
    linux.sigaddset(&set, linux.SIG.TERM);
    linux.sigaddset(&set, linux.SIG.QUIT);

    //sigprocmask is a system call used to tell the Linux kernel which signals (like interrupts or kills)
    // your program should temporarily block from being delivered so that it can finish a critical task
    // without being interrupted.
    switch (std.posix.errno(linux.sigprocmask(linux.SIG.BLOCK, &set, null))) {
        .SUCCESS => return set,
        else => power.powerOffNow(),
    }
}

/// Sleep until one of the blocked signals becomes pending.
///
/// `sigwaitinfo` is the key syscall here:
/// - it puts the process to sleep without burning CPU
/// - it wakes only when a signal in `set` arrives
/// - it returns the signal number so we can decide what to do next
///
/// If something transient interrupts the wait (`EINTR`), we simply try again.
/// Any other failure means the supervision loop is compromised, so we power off.
fn waitForSignal(set: *const linux.sigset_t) u6 {
    while (true) {
        var info = std.mem.zeroes(linux.siginfo_t);
        const rc = linux.sigwaitinfo(set, &info); // return code from linux not more than 63

        // On success, the kernel returns the signal number directly.
        if (rc >= 0) {
            return @intCast(rc);
        }

        switch (std.posix.errno(rc)) {
            .INTR => continue,
            else => power.powerOffNow(),
        }
    }
}

/// Apply scoutd's current signal policy.
///
/// - `SIGCHLD`: one or more children exited, so drain zombies now
/// - `SIGINT`, `SIGTERM`, `SIGQUIT`: shut the guest down immediately
/// - everything else: ignore for now
fn handleSignal(signo: u6) void {
    switch (signo) {
        linux.SIG.CHLD => reapChildren(),
        linux.SIG.INT, linux.SIG.TERM, linux.SIG.QUIT => power.powerOffNow(),
        else => {},
    }
}

/// Drain all exited children so they do not remain as zombies.
///
/// Linux concept:
/// - When a child process exits, the kernel keeps a tiny record for the parent.
/// - That record holds the exit status and some accounting info.
/// - Until the parent performs a wait syscall, the child remains a zombie.
/// - PID 1 must reap zombies or they accumulate forever.
///
/// We use `waitpid(-1, ..., WNOHANG)` because:
/// - `-1` means "reap any child"
/// - `WNOHANG` means "do not block if none are ready right now"
///
/// The raw `waitpid` return value matters more than `errno` here:
/// - `> 0` means one child was reaped, so loop and try again
/// - `0` means no exited children are waiting right now, so stop draining
/// - `-1` means an error, and only then do we inspect `errno`
fn reapChildren() void {
    while (true) {
        // The kernel writes the child's exit status into this variable when a child is reaped.
        // We do not use the status yet in Issue 2, but we will need it later for workload exit reporting.
        var status: u32 = 0;
        const rc = linux.waitpid(-1, &status, linux.W.NOHANG);

        // We successfully reaped one child. Keep looping because there may be more zombies queued.
        if (rc > 0) {
            continue;
        }

        // No more exited children are ready right now.
        // This is the normal non-blocking stopping condition for this drain pass.
        if (rc == 0) {
            return;
        }

        // Only a negative return is an error case.
        // `ECHILD` means we currently have no children at all.
        // `EINTR` means the syscall was interrupted, so just retry.
        // Any other error ends this drain pass; the next signal will wake us again.
        switch (std.posix.errno(rc)) {
            .CHILD => return,
            .INTR => continue,
            else => return,
        }
    }
}

test "supervision symbols compile" {
    _ = supervise;
}

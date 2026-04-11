//! Mount management for scoutd.
//!
//! This module provides the infrastructure for mounting filesystems (like /proc, /sys, /dev)

const std = @import("std");
const linux = std.os.linux;

/// A specification for a Linux filesystem mount.
///
/// Fields:
/// - dir: The target directory (e.g., "/proc"). Must be null-terminated ([:0]).
/// - fstype: The filesystem type (e.g., "proc", "sysfs"). Optional.
/// - source: The source device or "none". Optional.
/// - flags: Mount flags (MS_NOSUID, MS_NODEV, etc.).
/// - data: Filesystem-specific options (e.g., "mode=0755"). Optional.
///
/// This struct uses sentinel-terminated slices ([:0]) to ensure zero-copy
/// compatibility with the Linux Kernel's C-based API.
pub const MountSpec = struct {
    dir: [:0]const u8,
    fstype: ?[:0]const u8,
    source: ?[:0]const u8,
    flags: u32,
    data: ?[:0]const u8 = null,
};

/// The 'Essential Six': The minimal virtual filesystem roster required for a
/// high-performance, multi-tenant Linux environment.
///
/// In a Firecracker microVM, these mounts serve as the primary interface
/// between the guest's isolated memory and the host's physical hardware.
/// Missing any of these will cause standard runtimes (Go, Node, Python)
/// or "Serious Workloads" PostgreSQL, PyTorch to crash on boot.
const essential_mounts = [_]MountSpec{
    .{
        // Role: Exposes kernel process tables and system-wide telemetry.
        // Critical for: Process management, 'ps', 'top', and runtimes that
        // need to calculate CPU/Memory limits dynamically
        .dir = "/proc",
        .fstype = "proc",
        .source = "proc",
        .flags = linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC,
    },
    // Role: An interface to the kernel's object hierarchy.
    // Critical for: Hardware discovery. scoutd reads from /sys to find
    // network interfaces (eth0) and block devices provided by Firecracker
    .{
        .dir = "/sys",
        .fstype = "sysfs",
        .source = "sysfs",
        .flags = linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC,
    },
    // Role: Populates virtual device files.
    // Critical for: Basic system operations. Provides /dev/null for silencing
    // output and /dev/urandom for the high-quality entropy required by
    // TLS/SSL and cryptographic workloads.
    .{
        .dir = "/dev",
        .fstype = "devtmpfs",
        .source = "devtmpfs",
        .flags = linux.MS.NOSUID,
        .data = "mode=0755",
    },
    .{
        .dir = "/dev/pts",
        .fstype = "devpts",
        .source = "devpts",
        .flags = linux.MS.NOSUID | linux.MS.NOEXEC,
        .data = "mode=620,ptmxmode=666",
    },
    // Role: POSIX shared memory implementation using a RAM-backed tmpfs.
    // Critical for: High-performance IPC. AI Inference (PyTorch) and
    // Databases (PostgreSQL) use this to share data between threads at
    // memory speeds. Without this, PyTorch will fatal error on boot.
    .{
        .dir = "/dev/shm",
        .fstype = "tmpfs",
        .source = "tmpfs",
        .flags = linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC,
        .data = "mode=1777,size=64M",
    },
    // Role: A volatile location for early-boot state and system-wide sockets.
    // Critical for: Storing PID files, lock files, and ephemeral data that
    // must not survive a reboot but must be available to all processes.
    .{
        .dir = "/run",
        .fstype = "tmpfs",
        .source = "tmpfs",
        .flags = linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC,
        .data = "mode=0755,size=16M",
    },

    .{
        .dir = "/tmp",
        .fstype = "tmpfs",
        .source = "tmpfs",
        .flags = linux.MS.NOSUID | linux.MS.NODEV,
        .data = "mode=1777,size=64M",
    },
};

/// Orchestrates the mounting of all filesystems required for a functional Linux environment.
/// This is the "Bootstrap" phase of scoutd: it sets up the "Utilities" (/proc, /sys, /dev, /run)
/// that every Linux workload expects to find.
///
/// Returns: !void (Success, or returns the first error encountered during the process).
pub fn mountEssential() !void {
    // We use 'inline for' to iterate over our static 'essential_mounts' array.
    // This is "Comptime Expansion": the compiler copy-pastes the body of this loop
    // 4 times into the final binary. This removes the "Jump" and "Counter" overhead
    // of a normal loop, making our boot process as fast as possible.
    inline for (essential_mounts) |spec| {
        // 1. Prepare the mount point.
        // Before we can mount a filesystem to a folder (like "/proc"), that folder
        // must actually exist on the disk. 'ensureDir' checks for the folder
        // and creates it if it is missing.
        try ensureDir(spec.dir);

        // 2. Execute the mount.
        // Once the folder is ready, 'mountOne' calls the raw Linux 'mount' syscall.
        // We use 'try' here because if any single mount fails, the whole system
        // is in a broken state, and we should stop immediately (fail-fast).
        try mountOne(spec);
    }
}

/// Ensures a directory exists before a mount operation.
/// If the directory is missing, it is created with standard permissions (0755).
/// If it already exists, we consider it a success (Idempotent behavior).
fn ensureDir(path: [:0]const u8) !void {
    // We call the raw 'mkdir' system call directly.
    // 0o755: Octal permissions (drwxr-xr-x). Owner can R/W/X, others can R/X.
    // linux.errno: Converts the raw syscall return integer into a human-readable Enum.
    switch (std.posix.errno(linux.mkdir(path.ptr, 0o755))) {
        .SUCCESS => {},
        .EXIST => {},
        else => |err| return errnoToError(err),
    }
}

/// Mounts a single filesystem based on the provided specification.
///
/// This function translates the high-level 'MountSpec' struct into the
/// raw memory pointers required by the Linux kernel's 'mount' system call.
///
/// Returns: !void (Success, or a mapped Zig error).
fn mountOne(spec: MountSpec) !void {
    // The Linux kernel is written in C and expects 'NULL' for missing arguments.
    // We check if each optional field (like 'source' or 'fstype') has a value;
    // if it does, we take its memory address (.ptr). If not, we pass 'null'.
    const source_ptr = if (spec.source) |v| v.ptr else null;
    const fstype_ptr = if (spec.fstype) |v| v.ptr else null;
    const data_ptr = if (spec.data) |v| @intFromPtr(v.ptr) else 0;

    switch (std.posix.errno(linux.mount(
        source_ptr,
        spec.dir.ptr,
        fstype_ptr,
        spec.flags,
        data_ptr,
    ))) {
        .SUCCESS => {},
        .BUSY => {},
        else => |err| return errnoToError(err),
    }
}

/// Maps raw Linux kernel error codes (errno) to semantically meaningful Zig errors.
///
/// In the Linux kernel, errors are returned as integers (e.g., 13 for EACCES).
/// This function translates those cryptic codes into a strict, human-readable
/// Zig Error Set.
///
/// Returns: One of the five specific errors defined in the inline error set.
fn errnoToError(err: linux.E) error{ PermissionDenied, NotFound, InvalidArgument, Busy, Unexpected } {
    return switch (err) {
        .ACCES, .PERM => error.PermissionDenied,
        .NOENT => error.NotFound,
        .INVAL => error.InvalidArgument,
        .BUSY => error.Busy,
        else => error.Unexpected,
    };
}

test "mount spec const is stable" {
    try std.testing.expectEqual(@as(usize, 7), essential_mounts.len);
}

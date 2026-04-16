const std = @import("std");
const linux = std.os.linux;

/// The virtual socket (VSOCK) Context ID (CID) for the Firecracker host.
/// In the VSOCK address space, CID 3 is always the guest, and CID 2 is always the host.
pub const HostCid: u32 = 2;

/// The VSOCK port on the host used for control plane communication.
/// scoutd sends  messages and status reports to this port.
pub const ControlPort: u32 = 10000;

/// The VSOCK port on the host used for high-speed logging.
pub const LogPort: u32 = 10001;

/// The version number of the scoutd control protocol.
/// This allows the host to handle different versions of scoutd in the future.
pub const ProtocolVersion: u8 = 1;

/// A 4-byte magic number ('SCDT') that must start every control frame.
/// This is a simple handshake to ensure the host is talking to a real scoutd agent.
pub const ControlMagic: [4]u8 = .{ 'S', 'C', 'D', 'T' };

/// The fixed size in bytes of the protocol header for every frame.
pub const HeaderSize: usize = 10;

/// The set of valid message types that can be sent over the control protocol.
/// Using an enum provides compile-time safety, preventing unknown frame types.
pub const FrameKind = enum(u8) {
    hello = 1,
    fatal = 2,
};

/// Once the control channel is connected, we store its file descriptor here so
/// the panic path can still reach the host without needing to thread that FD
/// through every call in the boot path.
///
/// This is intentionally tiny global state:
/// - scoutd is single-threaded during early boot
/// - the control FD is established exactly once
/// - the panic path needs immediate access to it from anywhere in the process
var registered_control_fd: ?i32 = null;

/// Manages the two VSOCK file descriptors for communicating with the host.
///
/// This struct acts as a "Resource Handle." It bundles the file descriptors (FDs)
/// for the control and log channels into a single, managed object. By attaching
/// a 'close' method directly to the struct, we create a clear and safe pattern
/// for resource cleanup, preventing FD leaks.
pub const Channels = struct {
    control_fd: i32, //  The file descriptor for the control channel (port 10000).
    log_fd: i32, // / The file descriptor for the high-speed logging channel (port 10001).

    // We call the raw 'close' syscall for each file descriptor.
    // The result is discarded (_ =) because we are in a "best-effort"
    // cleanup path. If closing fails, there's little we can do.
    pub fn close(self: Channels) void {
        _ = linux.close(self.control_fd);
        _ = linux.close(self.log_fd);
    }
};

/// Errors that can occur when connecting to a single VSOCK port.
const PortConnectError = error{
    SocketFailed, // The kernel refused to give us a socket (FD).
    ConnectFailed, //  We got a socket, but couldn't connect to the host port.
};

/// Errors that can occur during the entire host channel setup process.
pub const ConnectError = error{
    ControlConnectFailed, // We failed to connect to the main control port.
    LogConnectFailed, // We failed to connect to the logging port.
};

pub const WriteError = error{
    WriteFailed,
    ZeroWrite,
};

/// Establishes VSOCK connections to the host for both control and logging.
///
/// The ordering here is deliberately asymmetric.
///
/// 1. We connect the control channel first.
/// 2. The moment it succeeds, we register that FD globally.
/// 3. Only then do we attempt the log channel.
///
/// Why this matters:
/// - The control channel is scoutd's only structured emergency reporting path.
/// - If a later boot phase panics, the panic handler needs immediate access to
///   a live control socket so it can push a final `fatal` frame to the host.
/// - That means the control channel is more foundational than the log channel.
///
/// Important consequence:
/// - If the log connection fails after control is already live, we do *not*
///   tear the control socket down here.
/// - We return an error to the caller, the caller panics, and the panic path
///   uses the already-registered control FD to report the failure.
pub fn connectChannels() ConnectError!Channels {
    const control_fd = connectPort(ControlPort) catch return error.ControlConnectFailed;

    // The control FD becomes process-global state immediately because every
    // later panic depends on it. From this point on, panic reporting no longer
    // needs stderr as a fallback transport.
    registerControlFd(control_fd);

    const log_fd = connectPort(LogPort) catch return error.LogConnectFailed;
    return .{
        .control_fd = control_fd,
        .log_fd = log_fd,
    };
}

/// Records the control FD for later panic reporting.
///
/// This helper is intentionally tiny and private. The only invariant it owns is
/// "the most recent successfully connected control socket is the one panic
/// reporting should use."
fn registerControlFd(fd: i32) void {
    registered_control_fd = fd;
}

/// Best-effort fatal reporting for the panic path.
///
/// By the time we are panicking, there is no recovery path left. So this helper
/// is intentionally silent on failure:
/// - if no control FD was ever registered, there is nowhere to send the report
/// - if the write fails, the process is already on its way down anyway
///
/// In both cases we still proceed directly to guest power off.
pub fn bestEffortSendRegisteredFatal(message: []const u8) void {
    const fd = registered_control_fd orelse return;
    sendFatal(fd, message) catch {};
}

pub fn sendHello(fd: i32) WriteError!void {
    try writeFrame(fd, .hello, "");
}

pub fn sendFatal(fd: i32, message: []const u8) WriteError!void {
    try writeFrame(fd, .fatal, message);
}

pub fn writeLog(fd: i32, message: []const u8) WriteError!void {
    try writeAll(fd, message);
}


/// Connects to a single VSOCK port on the host.
fn connectPort(port: u32) PortConnectError!i32 {
    // We ask the kernel for a streaming VSOCK socket.
    // - AF_VSOCK: The address family for VM-Host communication.
    // - SOCK_STREAM: A reliable, TCP-like connection.
    // - SOCK_CLOEXEC: A critical security flag. Prevents this file descriptor
    //   from being leaked to child processes.

    const socket_type: u32 = linux.SOCK.STREAM | linux.SOCK.CLOEXEC; //   | bitwise OR is used to merge the  bits of the two numbers
    const socket_rc = linux.socket(linux.AF.VSOCK, socket_type, 0);

    if (std.posix.errno(socket_rc) != .SUCCESS) {
        return error.SocketFailed;
    }

    // On success, the return code is our new file descriptor.
    // We cast it to the correct i32 type
    const fd: i32 = @intCast(socket_rc);
    errdefer _ = linux.close(fd);

    // We create a C-style 'sockaddr_vm' struct that specifies the
    // host's CID (Context ID = 2) and the target port.
    var addr = linux.sockaddr.vm{
        .port = port,
        .cid = HostCid,
        .flags = 0,
    };

    // This is the raw C API for the 'connect' syscall. It requires us to
    // cast our typed address struct into a raw, untyped memory pointer.
    const connect_rc = linux.connect(fd, @as(*const anyopaque, @ptrCast(&addr)), @as(linux.socklen_t, @intCast(@sizeOf(linux.sockaddr.vm))));

    // If the connect call fails, the host is likely not listening on that port.
    if (std.posix.errno(connect_rc) != .SUCCESS) {
        return error.ConnectFailed;
    }

    return fd;
}

/// The core "serializer" for the control protocol.
/// It builds the 10-byte frame header, then writes both the header and the
/// payload to the socket as two separate, sequential writes.
fn writeFrame(fd: i32, kind: FrameKind, payload: []const u8) WriteError!void {
    const header = encodeHeader(kind, @as(u32, @intCast(payload.len)));
    try writeAll(fd, header[0..]);
    try writeAll(fd, payload);
}

/// Serializes the frame metadata into a 10-byte, network-ready header.
///
/// This is a "Binary Packer." It takes high-level Zig types (enums, integers)
/// and packs them into a raw byte array according to the strict rules of the
/// scoutd control protocol.
///
/// Returns: A [10]u8 array containing the fully serialized header.
fn encodeHeader(kind: FrameKind, payload_len: u32) [HeaderSize]u8 {
    //  Allocate a 10-byte buffer on the stack.
    // '= undefined' is a critical optimization: we are about to overwrite every
    // byte, so we tell the compiler not to waste cycles zeroing the memory.
    var header: [HeaderSize]u8 = undefined;

    //  Write the "Magic Number" (Bytes 0-3).
    // '@memcpy' is a compiler intrinsic that generates the fastest possible
    // code to copy the 4-byte 'SCDT' magic number into the start of the header.
    @memcpy(header[0..4], ControlMagic[0..]);

    //  Write the Protocol Version (Byte 4).
    header[4] = ProtocolVersion;

    //  Write the Frame Kind (Byte 5).
    // '@intFromEnum' converts the typed 'FrameKind.hello' into its raw
    // underlying integer value (e.g., 1).
    header[5] = @intFromEnum(kind);

    //  Write the Payload Length (Bytes 6-9).
    // To send a 4-byte integer over a network, we must serialize it into
    // a standard byte order (Endianness).
    var len_bytes: [4]u8 = undefined;

    // std.mem.writeInt takes our u32 'payload_len', converts it to 4 raw bytes,
    // and writes them into our temporary 'len_bytes' buffer.
    // '.big' specifies Big-Endian byte order, which is the standard for
    // all network protocols.
    std.mem.writeInt(u32, &len_bytes, payload_len, .big);

    // Finally, copy the 4 serialized length bytes into the header.
    @memcpy(header[6..10], len_bytes[0..]);

    //  Return the completed 10-byte header.
    // Because the header is a fixed-size array, it is copied by value and
    // lives on the stack, requiring no heap allocation.
    return header;
}

/// A "resilient" and "blocking" writer that guarantees all bytes are sent.
///
/// ## The Core Problem: The Unreliable Kernel
///
/// The raw 'linux.write' syscall is a primitive building block. It offers no
/// guarantees. When you ask it to write 100 bytes, it might only write 10 due
/// to a full network buffer (a "Partial Write"), or it might be interrupted by
/// a hardware signal (.INTR).
///
/// This function transforms that "unreliable" primitive into a "reliable" tool.
/// It creates a blocking API that promises to not return until every single byte
/// has been sent, or a permanent error has occurred.
///
fn writeAll(fd: i32, bytes: []const u8) WriteError!void {
    // 'offset' is the "Odometer." It tracks our total progress from 0 up to
    // the final destination (bytes.len).
    var offset: usize = 0;

    // The journey continues as long as our odometer hasn't reached the destination.
    while (offset < bytes.len) {
        // --- The Core Syscall: Instructions for the Next Leg of the Journey ---
        //
        // We are telling the Linux kernel exactly what to do for the next chunk.
        //
        //  The "Starting Point" (`bytes[offset..].ptr`):
        //    This is a zero-copy "view" into our data. We get the raw memory
        //    address of where we left off.
        //
        //  The "Remaining Distance" (`bytes.len - offset`):
        //    This is the "countdown." It calculates how many bytes are left to
        //    send. This value decreases with each successful write.
        const rc = linux.write(fd, bytes[offset..].ptr, bytes.len - offset);

        // --- Result Handling: Did we make progress? ---
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                // Critical Edge Case: A return of 0 means we made no progress,
                // which would cause an infinite loop. We must treat this as a
                // fatal error for this connection.
                if (rc == 0) return error.ZeroWrite;

                // Success! We advance our "Odometer" by the number of bytes
                // the kernel just wrote for us.
                offset += @as(usize, @intCast(rc));
            },

            // The journey was interrupted by a temporary "roadblock" (a signal).
            // We 'continue' to immediately retry sending the same chunk.
            .INTR => continue,

            // A permanent "road closure" (.EPIPE, .EBADF). The journey is over.
            else => return error.WriteFailed,
        }
    }
}

test "encode hello header" {
    const header = encodeHeader(.hello, 0);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        'S', 'C', 'D', 'T',
        1,   1,   0,   0,
        0,   0,
    }, header[0..]);
}

test "encode fatal header" {
    const header = encodeHeader(.fatal, 5);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        'S', 'C', 'D', 'T',
        1,   2,   0,   0,
        0,   5,
    }, header[0..]);
}

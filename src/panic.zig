const std = @import("std");
const power = @import("power.zig");
const vsock = @import("vsock.zig");

/// Panic payloads must stay small and stack-only.
///
/// We want enough room for:
/// - the panic message itself
/// - a short label for each section
/// - a best-effort stack trace dump
///
/// This buffer is only used during panic, so a fixed stack allocation is the
/// safest and simplest design. If the trace does not fit, Zig's fixed writer
/// will stop accepting more bytes, but we will still keep and send everything
/// that already fit into the buffer.
const MaxPanicPayloadBytes = 4096;

pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    // Build one structured panic payload in memory first.
    //
    // Why not stream directly to vsock line by line?
    // Because the control channel is framed. The host expects a single `fatal`
    // control frame with a known payload length, not a sequence of ambiguous raw
    // writes. So we serialize the full panic report into a fixed buffer, then
    // send it as one best-effort fatal frame.
    var payload_buffer: [MaxPanicPayloadBytes]u8 = undefined;
    const payload = buildPanicPayload(&payload_buffer, msg, st, addr);

    // Panic reporting is now vsock-only.
    //
    // The control channel is established before mounts, cmdline parsing, and
    // the rest of guest bootstrap, so almost every meaningful runtime failure
    // now has a real host-visible reporting path. If the control channel never
    // came up at all, there is nothing left to talk to, so we fail closed and
    // power off without falling back to stderr.
    if (payload.len != 0) {
        vsock.bestEffortSendRegisteredFatal(payload);
    }

    power.powerOffNow();
}

/// Serializes the panic report into one byte slice that can be carried inside a
/// single framed control message.
///
/// The writer is fixed-size on purpose:
/// - no heap allocation during panic
/// - deterministic memory usage
/// - if we run out of space, the already-written prefix is still preserved
///
/// That means the host will at least receive the panic message and usually a
/// useful prefix of the stack trace, even in the truncated case.
fn buildPanicPayload(
    buffer: []u8,
    msg: []const u8,
    st: ?*std.builtin.StackTrace,
    addr: ?usize,
) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);

    writer.writeAll("panic: ") catch {};
    writer.writeAll(msg) catch {};
    writer.writeAll("\n") catch {};

    // Zig may provide an error return trace in `st`. If it exists, it is often
    // the most precise "how did we get here" breadcrumb we have, so we emit it
    // first.
    if (st) |stack_trace| {
        writer.writeAll("error return trace:\n") catch {};
        appendCapturedStackTrace(&writer, stack_trace.*);
    }

    // After the optional error return trace, dump the live call stack from the
    // current panic site. This mirrors Zig's default panic behavior closely,
    // just routed into our own framed transport instead of stderr.
    writer.writeAll("stack trace:\n") catch {};
    appendCurrentStackTrace(&writer, addr);

    return writer.buffered();
}

/// Writes the captured Zig stack trace into our fixed panic buffer.
///
/// `writeStackTrace` needs debug info to symbolize addresses into readable file
/// names and line numbers. If symbolization is unavailable, we still write a
/// human-readable explanation into the payload so the host does not receive an
/// empty or mysterious trace section.
fn appendCapturedStackTrace(writer: *std.Io.Writer, stack_trace: std.builtin.StackTrace) void {
    const debug_info = std.debug.getSelfDebugInfo() catch |err| {
        writer.print("Unable to dump stack trace: Unable to open debug info: {s}\n", .{@errorName(err)}) catch {};
        return;
    };

    std.debug.writeStackTrace(stack_trace, writer, debug_info, .no_color) catch |err| {
        writer.print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch {};
    };
}

/// Writes the current live stack trace into the fixed panic buffer.
///
/// We pass the panic address through so the dump starts from the actual panic
/// site rather than from some deeper helper frame inside this module.
fn appendCurrentStackTrace(writer: *std.Io.Writer, addr: ?usize) void {
    std.debug.dumpCurrentStackTraceToWriter(addr orelse @returnAddress(), writer) catch {};
}

test "panic payload includes message" {
    var buffer: [256]u8 = undefined;
    const payload = buildPanicPayload(&buffer, "boom", null, null);

    try std.testing.expect(std.mem.startsWith(u8, payload, "panic: boom\nstack trace:\n"));
}

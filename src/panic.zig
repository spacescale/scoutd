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

/// We deliberately cap how many frames we serialize during panic.
///
/// Reasons:
/// - the payload lives in a fixed stack buffer
/// - panic reporting must stay bounded and deterministic
/// - a short raw-address trace is already enough for host-side debugging when
///   paired with the original binary and symbols outside the guest
const MaxTraceFrames = 32;

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
    //
    // Important design choice:
    // We no longer symbolize stack traces here. Symbolization reaches into lazy
    // debug-info state that may allocate. Instead, we dump raw instruction
    // addresses. That keeps the panic path allocator-free while still giving the
    // host enough data to symbolize offline later if needed.
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

/// Writes the captured Zig stack trace into our fixed panic buffer as raw
/// instruction addresses.
///
/// Why raw addresses instead of file names and line numbers?
/// - symbolization depends on debug info
/// - opening and querying that debug info can allocate
/// - allocator-free panic reporting is more important than in-guest prettiness
///
/// The host can still symbolize these addresses later using the matching build
/// artifacts, which is the correct place to spend that extra complexity.
fn appendCapturedStackTrace(writer: *std.Io.Writer, stack_trace: std.builtin.StackTrace) void {
    var frame_index: usize = 0;
    var frames_left: usize = @min(stack_trace.index, stack_trace.instruction_addresses.len);
    var emitted: usize = 0;

    while (frames_left != 0 and emitted < MaxTraceFrames) : ({
        frames_left -= 1;
        frame_index = (frame_index + 1) % stack_trace.instruction_addresses.len;
    }) {
        const return_address = stack_trace.instruction_addresses[frame_index];
        appendRawAddress(writer, return_address);
        emitted += 1;
    }

    if (stack_trace.index > stack_trace.instruction_addresses.len) {
        const dropped_frames = stack_trace.index - stack_trace.instruction_addresses.len;
        writer.print("({d} additional captured frames skipped)\n", .{dropped_frames}) catch {};
    }

    if (emitted == MaxTraceFrames and frames_left != 0) {
        writer.writeAll("(panic trace truncated)\n") catch {};
    }
}

/// Writes the current live stack trace into the fixed panic buffer as raw
/// instruction addresses.
///
/// This uses Zig's frame-pointer based `StackIterator.init`, which avoids the
/// debug-info allocator path entirely. The tradeoff is that the trace may be
/// less complete on builds or architectures that omit frame pointers, but the
/// panic path stays simple and deterministic.
///
/// We pass the panic address through so the dump starts from the actual panic
/// site rather than from some deeper helper frame inside this module.
fn appendCurrentStackTrace(writer: *std.Io.Writer, addr: ?usize) void {
    var it = std.debug.StackIterator.init(addr orelse @returnAddress(), null);
    defer it.deinit();

    var emitted: usize = 0;
    while (emitted < MaxTraceFrames) : (emitted += 1) {
        const return_address = it.next() orelse break;
        appendRawAddress(writer, return_address);
    }

    if (emitted == MaxTraceFrames) {
        writer.writeAll("(current stack trace truncated)\n") catch {};
    }
}

/// Serializes one raw return address as a printable line.
///
/// We subtract one using saturating subtraction to mirror how symbolized stack
/// traces usually point at the call site rather than the next instruction after
/// the call. With raw addresses this is still useful because it makes offline
/// symbolization line up more naturally with the source location.
fn appendRawAddress(writer: *std.Io.Writer, return_address: usize) void {
    const address = return_address -| 1;
    writer.print("0x{x}\n", .{address}) catch {};
}

test "panic payload includes message" {
    var buffer: [256]u8 = undefined;
    const payload = buildPanicPayload(&buffer, "boom", null, null);

    try std.testing.expect(std.mem.startsWith(u8, payload, "panic: boom\nstack trace:\n"));
}

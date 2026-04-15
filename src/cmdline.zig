const std = @import("std");

/// The absolute maximum number of bytes we are willing to read from /proc/cmdline.
///
/// In a standard Linux environment, the kernel command line is typically limited
/// If the cmdline exceeds 1KB, it implies
/// either a configuration error by the host or a malicious payload injection.
/// Capping this at 1024 bytes ensures our parser uses a tiny, fixed-size stack buffer
/// (zero heap allocation) and prevents buffer overflow attacks.
pub const MaxCmdlineBytes = 1024;

/// The essential network configuration required to bring up eth0 and reach MMDS.
/// injected via the kernel cmdline so that scoutd can configure the network interface.
/// Once the network is up, scoutd can reach out to the Firecracker Metadata Service
/// Memory Layout (13 bytes total, zero padding):
/// This is heavily optimized for zero-allocation parsing.
pub const Bootstrap = struct {
    ipv4_addr: [4]u8, // the ipv4 address assigned to the microvm
    prefix_len: u8,
    gateway: [4]u8,
    mmds_addr: [4]u8,
};

/// Represents a parsed IPv4 address and its associated subnet mask in CIDR notation.
///
/// When scoutd reads the kernel command line, network settings are provided as
/// strings (e.g., "169.254.0.2/24"). This intermediate struct holds the result
/// of successfully converting that text into the raw bytes required by the Linux
/// networking stack.
const ParsedIpv4 = struct {
    // The four raw bytes of the IPv4 address (e.g., {169, 254, 0, 2}).
    addr: [4]u8,

    // The network prefix length (e.g., 24), which defines the subnet mask.
    // This is used later to configure the routing table for the eth0 interface.
    prefix_len: u8,
};

/// The exhaustive list of failures that can occur while parsing the kernel cmdline.
///
/// Because scoutd is PID 1, we cannot simply say "Error: Bad Config". We must
/// know exactly *why* the bootstrap failed so we can log it before shutting down.
/// This explicit error set forces the compiler to ensure we handle every single
/// edge case (Missing, Duplicate, Invalid) during the parsing phase.
pub const ParseError = error{
    EmptyCmdline, // /proc/cmdline had no text.
    CmdlineTooLong, // The text exceeded our 1024-byte safety limit.
    MissingIpv4, // No 'scoutd.ipv4=' was provided.
    MissingGateway, // No 'scoutd.gateway=' was provided.
    MissingMmds, // No 'scoutd.mmds=' was provided.
    DuplicateIpv4, // 'scoutd.ipv4=' appeared twice (Ambiguous).
    DuplicateGateway, // 'scoutd.gateway=' appeared twice.
    InvalidGateway, // gateway is malformed
    DuplicateMmds, // 'scoutd.mmds=' appeared twice.
    EmptyValue, // e.g., 'scoutd.ip=' with nothing after the equals sign.
    MissingPrefixLen, // e.g., '10.0.0.2' instead of '10.0.0.2/24'.
    InvalidPrefixLen, // The prefix was not a number between 0 and 32.
    InvalidIpv4, // The IP address had letters or numbers > 255.
    InvalidMmds, // The MMDS IP address was malformed.
};

/// Reads and parses the kernel command line from /proc/cmdline to extract
/// the essential network configuration.
///
/// This function acts as the "Entry Point" for our bootstrap contract. It is
/// responsible for reading the raw text from the kernel, performing critical
/// safety checks, and then passing the sanitized data to the parser.
///
/// Returns: !Bootstrap (The fully built Bootstrap struct, or a ParseError).
pub fn readBootstrap() !Bootstrap {
    var file = try std.fs.openFileAbsolute("/proc/cmdline", .{});
    defer file.close();

    var buffer: [MaxCmdlineBytes]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);

    if (bytes_read == buffer.len) {
        var extra: [1]u8 = undefined;
        if (try file.readAll(&extra) != 0) {
            return error.CmdlineTooLong;
        }
    }

    const raw = std.mem.trim(u8, buffer[0..bytes_read], " \n\r\t");
    if (raw.len == 0) {
        return error.EmptyCmdline;
    }

    return parse(raw);
}

/// The core command-line parser.
/// It takes the raw, sanitized byte slice from /proc/cmdline and transforms it
/// into the structured 'Bootstrap' config.
pub fn parse(raw: []const u8) ParseError!Bootstrap {
    const trimmed = std.mem.trim(u8, raw, " \n\r\t");
    if (trimmed.len == 0) {
        return error.EmptyCmdline;
    }

    // Using Optionals (?) lets the compiler track whether we've found each value yet.
    var ipv4: ?ParsedIpv4 = null;
    var gateway: ?[4]u8 = null;
    var mmds: ?[4]u8 = null;

    //  The Tokenizer
    // std.mem.tokenizeAny skips repeated whitespace for us, so we only see real
    // tokens and do not need a separate empty-token check in the loop.
    var tokens = std.mem.tokenizeAny(u8, trimmed, " \n\r\t");

    // 'while (tokens.next()) |token|' says: "Give me the next word. If there are
    // no more words, stop." This is the most efficient way to loop over text.
    while (tokens.next()) |token| {
        //  Split Key from Value
        // We look for the '=' sign. If it's not there, this isn't a key-value
        // pair, so we ignore it ('orelse continue').
        const eq_index = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        const key = token[0..eq_index]; // The text before '='
        const value = token[eq_index + 1 ..]; // The text after '='

        //  Filter for our Namespace
        // We only care about keys that start with "scoutd.". This allows the
        // kernel cmdline to contain other boot arguments without confusing us.
        if (!std.mem.startsWith(u8, key, "scoutd.")) continue;

        // Safety Check: 'scoutd.ip=' with nothing after it is an error.
        if (value.len == 0) return error.EmptyValue;

        //  The "State Machine" Logic
        // We use 'std.mem.eql' (equals) to check which key we've found.

        // Is it the IP address?
        if (std.mem.eql(u8, key, "scoutd.ipv4")) {
            // Error if we've already found it. Prevents ambiguous config.
            if (ipv4 != null) return error.DuplicateIpv4;
            // Parse the 'value' (e.g., "10.0.0.2/24") into our 'ParsedIpv4' struct.
            ipv4 = try parseIpv4WithPrefix(value);
            continue; // Go to the next token.
        }

        // Is it the Gateway?
        if (std.mem.eql(u8, key, "scoutd.gateway")) {
            if (gateway != null) return error.DuplicateGateway;
            // Parse the 'value' (e.g., "10.0.0.1") into a raw [4]u8.
            // 'catch return error.InvalidGateway' is a Zig shortcut for:
            // "If parsing fails, return this specific error."
            gateway = parseIpv4Bytes(value) catch return error.InvalidGateway;
            continue;
        }

        // Is it the MMDS server?
        if (std.mem.eql(u8, key, "scoutd.mmds")) {
            if (mmds != null) return error.DuplicateMmds;
            mmds = parseIpv4Bytes(value) catch return error.InvalidMmds;
            continue;
        }

        // Note: We ignore any other 'scoutd.*' keys. This is for forward
        // compatibility, so a future version of scoutd can use new keys
        // without breaking this older version.
    }

    const parsed_ipv4 = ipv4 orelse return error.MissingIpv4;
    const parsed_gateway = gateway orelse return error.MissingGateway;
    const parsed_mmds = mmds orelse return error.MissingMmds;

    return .{
        .ipv4_addr = parsed_ipv4.addr,
        .prefix_len = parsed_ipv4.prefix_len,
        .gateway = parsed_gateway,
        .mmds_addr = parsed_mmds,
    };
}

/// Parses a string containing an IPv4 address with a CIDR prefix (e.g., "10.0.0.2/24").
///
/// This is a critical helper for parsing the 'scoutd.ipv4' cmdline argument. It
/// validates the format and separates the IP address from its subnet mask length.
///
/// Returns: ParseError!ParsedIpv4 (The structured result, or a specific ParseError).
fn parseIpv4WithPrefix(value: []const u8) ParseError!ParsedIpv4 {
    //  Find the CIDR prefix separator ('/').
    // We expect the input to be in the format "A.B.C.D/L". This line finds the
    // position of the '/'. If it's not found, the prefix is missing.
    const slash_index = std.mem.indexOfScalar(u8, value, '/') orelse return error.MissingPrefixLen;

    //  Split the string into two slices (IP and prefix).
    // We create "views" into the original string without allocating any new memory.
    const ip_text = value[0..slash_index]; // The part before the '/'
    const prefix_text = value[slash_index + 1 ..]; // The part after the '/'

    // An input like "/24" or "10.0.0.2/" is malformed.
    if (ip_text.len == 0 or prefix_text.len == 0) {
        return error.MissingPrefixLen;
    }

    //  Parse the Prefix Length.
    // 'std.fmt.parseUnsigned' converts a string of digits into a number.
    // 'catch' is another Zig shortcut: if 'parseUnsigned' fails (e.g., the text
    // is "abc" instead of "24"), it immediately returns our custom error.
    const prefix = std.fmt.parseUnsigned(u8, prefix_text, 10) catch return error.InvalidPrefixLen;

    //  Validate the Prefix Range.
    // An IPv4 prefix length MUST be between 0 and 32.
    if (prefix > 32) {
        return error.InvalidPrefixLen;
    }

    //  Construct and Return the Final Struct.
    // We now have the two valid components. We parse the 'ip_text' using another
    // helper ('parseIpv4Bytes') and assemble the final 'ParsedIpv4' struct.
    return .{
        .addr = parseIpv4Bytes(ip_text) catch return error.InvalidIpv4,
        .prefix_len = prefix,
    };
}

/// Parses a "A.B.C.D" string into a raw 4-byte array.
fn parseIpv4Bytes(value: []const u8) ParseError![4]u8 {
    var result: [4]u8 = undefined;
    var octet_index: u8 = 0;

    // Split the string by the '.' character.
    var octets = std.mem.splitScalar(u8, value, '.');

    // Loop through each octet (e.g., "10", "0", "0", "2").
    while (octets.next()) |octet_str| {
        // If we have more than 4 parts, it's an invalid IP.
        if (octet_index > 3) return error.InvalidIpv4;

        // Convert the text to a number (0-255).
        const num = std.fmt.parseUnsigned(u8, octet_str, 10) catch return error.InvalidIpv4;

        // Save it in our result array.
        result[octet_index] = num;
        octet_index += 1;
    }

    // If we didn't find exactly 4 parts, it's an invalid IP.
    if (octet_index != 4) return error.InvalidIpv4;

    return result;
}

test "parse valid bootsrap" {
    const parsed = try parse(
        "ro quiet scoutd.ipv4=172.16.0.2/30 scoutd.gateway=172.16.0.1 scoutd.mmds=169.254.169.254",
    );
    try std.testing.expectEqualDeep(Bootstrap{
        .ipv4_addr = .{ 172, 16, 0, 2 },
        .prefix_len = 30,
        .gateway = .{ 172, 16, 0, 1 },
        .mmds_addr = .{ 169, 254, 169, 254 },
    }, parsed);
}


test "parse ignores unrelated kernel args" {
    const parsed = try parse(
        "ro console=ttyS0 panic=-1 scoutd.ipv4=10.0.0.2/24 scoutd.gateway=10.0.0.1 scoutd.mmds=169.254.169.254",
    );
    try std.testing.expectEqualDeep(Bootstrap{
        .ipv4_addr = .{ 10, 0, 0, 2 },
        .prefix_len = 24,
        .gateway = .{ 10, 0, 0, 1 },
        .mmds_addr = .{ 169, 254, 169, 254 },
    }, parsed);
}



test "parse rejects missing ipv4" {
    try std.testing.expectError(
        error.MissingIpv4,
        parse("scoutd.gateway=172.16.0.1 scoutd.mmds=169.254.169.254"),
    );
}


test "parse rejects duplicate gateway" {
    try std.testing.expectError(
        error.DuplicateGateway,
        parse("scoutd.ipv4=172.16.0.2/30 scoutd.gateway=172.16.0.1 scoutd.gateway=172.16.0.3 scoutd.mmds=169.254.169.254"),
    );
}
test "parse rejects invalid prefix" {
    try std.testing.expectError(
        error.InvalidPrefixLen,
        parse("scoutd.ipv4=172.16.0.2/99 scoutd.gateway=172.16.0.1 scoutd.mmds=169.254.169.254"),
    );
}
test "parse rejects invalid mmds" {
    try std.testing.expectError(
        error.InvalidMmds,
        parse("scoutd.ipv4=172.16.0.2/30 scoutd.gateway=172.16.0.1 scoutd.mmds=999.1.1.1"),
    );
}

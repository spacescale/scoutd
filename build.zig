const std = @import("std");

pub fn build(b: *std.Build) !void {
    // Determine the platform we are building for. We default to Linux x86
    // with musl to ensure the binary is statically linked and portable.
    const target = b.standardTargetOptions(. {
       .default_target =  .{
           .cpu_arch =  .x86_64,
           .os_tag = .linux,
           .abi =  .musl
       }
    });

    // Set how the compiler should optimize the output. ReleaseSmall is 
    // chosen to keep the agent's binary size to a minimum. it doesnt bundle test files along with binary
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall
    });

    // Create the core module representing our application source code,
    // ensuring it is single-threaded for predictable edge performance.
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });

    // Define the executable binary and name it scoutd.
    const exe = b.addExecutable(.{
       .name = "scoutd",
        .root_module = root_module,
    });

    exe.root_module.strip = true; // This removes all debug symbols for a tiny binary

    // Tell the build system to save the finished binary to the output folder.
    b.installArtifact(exe);

    // Set up a run command to execute the agent directly from the terminal.
    const run_cmd = b.addRunArtifact(exe);
    
    // Pass through any command-line arguments to the running program.
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    
    // Register the run command so we can type zig build run.
    const run_step = b.step("run", "Run scoutd");
    run_step.dependOn(&run_cmd.step);


    // Instruct the compiler to find and prepare the test blocks in our code.
    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });

    // Create an action to execute the compiled tests.
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Register the test command so we can type zig build test.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

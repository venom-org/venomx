const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.dependency("venom_std", .{ .target = target, .optimize = optimize });
    const term = b.dependency("venom_term", .{ .target = target, .optimize = optimize, .headless = true });
    // The daemon test seam is compiled only into test builds.
    const test_seams = b.option(bool, "test-seams", "Compile the daemon test seam (integration builds only)") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "test_seams", test_seams);
    const no_seams = b.addOptions();
    no_seams.addOption(bool, "test_seams", false);
    const with_seams = b.addOptions();
    with_seams.addOption(bool, "test_seams", true);
    const mod = b.addModule("pane-stream", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    mod.addOptions("build_options", no_seams);
    mod.addImport("proto", shared.module("proto"));
    mod.addImport("vt", term.module("vt"));
    mod.addImport("term_chrome", term.module("chrome"));
    inline for (.{ "cli", "cfg", "log", "supervisor", "xdg" }) |name| mod.addImport(name, shared.module(name));
    // The binary also hosts the attach client, which needs the renderer. Its
    // Vt and pane_stream come from the same venom-term instance, so there is
    // one ghostty and one Vt type.
    const term_full = b.dependency("venom_term", .{ .target = target, .optimize = optimize });
    const executable = b.addExecutable(.{ .name = "venomx", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    executable.root_module.addImport("vt", term_full.module("vt"));
    executable.root_module.addImport("pane_stream", term_full.module("pane_stream"));
    executable.root_module.addImport("venom-term", term_full.module("venom-term"));
    executable.root_module.addImport("term_chrome", term_full.module("chrome"));
    inline for (.{ "proto", "cli", "cfg", "log", "supervisor", "xdg" }) |name| executable.root_module.addImport(name, shared.module(name));
    executable.root_module.addOptions("build_options", options);
    b.installArtifact(executable);
    // The same binary with the seam, for the integration cases.
    const seamed = b.addExecutable(.{ .name = "venomx-seam", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    seamed.root_module.addImport("vt", term_full.module("vt"));
    seamed.root_module.addImport("pane_stream", term_full.module("pane_stream"));
    seamed.root_module.addImport("venom-term", term_full.module("venom-term"));
    seamed.root_module.addImport("term_chrome", term_full.module("chrome"));
    inline for (.{ "proto", "cli", "cfg", "log", "supervisor", "xdg" }) |name| seamed.root_module.addImport(name, shared.module(name));
    seamed.root_module.addOptions("build_options", with_seams);
    b.installArtifact(seamed);
    const tests = b.addTest(.{ .root_module = mod });
    b.default_step.dependOn(&tests.step);
    const test_step = b.step("test", "Run unit, leak, headless socket and agent-contract tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // Attach client unit tests drive the client against the real stream server.
    const attach_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/attach_tests.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    attach_tests.root_module.addImport("vt", term_full.module("vt"));
    attach_tests.root_module.addImport("pane_stream", term_full.module("pane_stream"));
    attach_tests.root_module.addImport("venom-term", term_full.module("venom-term"));
    attach_tests.root_module.addImport("term_chrome", term_full.module("chrome"));
    inline for (.{ "proto", "cli", "cfg", "log", "supervisor", "xdg" }) |name| attach_tests.root_module.addImport(name, shared.module(name));
    // The presentation client tests drive a real Product.
    attach_tests.root_module.addOptions("build_options", no_seams);
    b.default_step.dependOn(&attach_tests.step);
    test_step.dependOn(&b.addRunArtifact(attach_tests).step);
    // Test-only terminal model used by the attach end-to-end test to read
    // what each real client drew on its host terminal.
    const screen = b.addExecutable(.{ .name = "vt-screen", .root_module = b.createModule(.{ .root_source_file = b.path("test/screen.zig"), .target = target, .optimize = optimize }) });
    screen.root_module.addImport("vt", term_full.module("vt"));
    const attach_e2e = b.addSystemCommand(&.{"python3"});
    attach_e2e.addFileArg(b.path("test/attach.py"));
    attach_e2e.addArtifactArg(executable);
    attach_e2e.addArtifactArg(screen);
    attach_e2e.has_side_effects = true;
    attach_e2e.expectExitCode(0);
    test_step.dependOn(&attach_e2e.step);
    b.step("test-attach", "Run the two-client attach end-to-end test").dependOn(&attach_e2e.step);
    const integration = b.addSystemCommand(&.{"python3"});
    integration.addFileArg(b.path("test/daemon.py"));
    integration.addArtifactArg(executable);
    integration.has_side_effects = true;
    integration.expectExitCode(0);
    test_step.dependOn(&integration.step);
    // `shell init` snippets in real zsh, bash and fish panes.
    const shell_init = b.addSystemCommand(&.{"python3"});
    shell_init.addFileArg(b.path("test/shell_init.py"));
    shell_init.addArtifactArg(executable);
    shell_init.has_side_effects = true;
    shell_init.expectExitCode(0);
    test_step.dependOn(&shell_init.step);
    const termination = b.addSystemCommand(&.{"python3"});
    termination.addFileArg(b.path("test/terminate.py"));
    termination.addArtifactArg(seamed);
    termination.has_side_effects = true;
    termination.expectExitCode(0);
    test_step.dependOn(&termination.step);
    b.step("test-terminate", "Run the termination and recursive removal cases").dependOn(&termination.step);
    // grants.isolation off (the default) and on.
    const isolation = b.addSystemCommand(&.{"python3"});
    isolation.addFileArg(b.path("test/isolation.py"));
    isolation.addArtifactArg(executable);
    isolation.has_side_effects = true;
    isolation.expectExitCode(0);
    test_step.dependOn(&isolation.step);
    // On-demand startup/shutdown matrix; the seam injects startup faults.
    const lifecycle = b.addSystemCommand(&.{"python3"});
    lifecycle.addFileArg(b.path("test/lifecycle.py"));
    lifecycle.addArtifactArg(seamed);
    lifecycle.has_side_effects = true;
    lifecycle.expectExitCode(0);
    test_step.dependOn(&lifecycle.step);
    b.step("test-lifecycle", "Run the on-demand lifecycle cases").dependOn(&lifecycle.step);
    const spawn_cases = b.addSystemCommand(&.{"python3"});
    spawn_cases.addFileArg(b.path("test/spawn.py"));
    spawn_cases.addArtifactArg(seamed);
    spawn_cases.addArtifactArg(shared.artifact("venom-echo"));
    spawn_cases.has_side_effects = true;
    spawn_cases.expectExitCode(0);
    test_step.dependOn(&spawn_cases.step);
    b.step("test-spawn", "Run the pane cwd and environment cases").dependOn(&spawn_cases.step);
    const tmux_cases = b.addSystemCommand(&.{"python3"});
    tmux_cases.addFileArg(b.path("test/tmux.py"));
    tmux_cases.addArtifactArg(executable);
    tmux_cases.has_side_effects = true;
    tmux_cases.expectExitCode(0);
    test_step.dependOn(&tmux_cases.step);
    b.step("test-tmux", "Replay Claude Code's tmux subcommands against the shim").dependOn(&tmux_cases.step);
    const rows = b.addSystemCommand(&.{"python3"});
    rows.addFileArg(b.path("test/capture_rows.py"));
    rows.addArtifactArg(seamed);
    rows.has_side_effects = true;
    rows.expectExitCode(0);
    test_step.dependOn(&rows.step);
    b.step("test-capture-rows", "Run the history-range capture cases").dependOn(&rows.step);
    // Durable restore matrix; the seam injects write faults and clock offsets.
    const recovery = b.addSystemCommand(&.{"python3"});
    recovery.addFileArg(b.path("test/recovery.py"));
    recovery.addArtifactArg(seamed);
    recovery.has_side_effects = true;
    recovery.expectExitCode(0);
    test_step.dependOn(&recovery.step);
    b.step("test-recovery", "Run the durable restore and crash recovery cases").dependOn(&recovery.step);
    // pane.relaunch cases on real restored archives.
    const relaunch = b.addSystemCommand(&.{"python3"});
    relaunch.addFileArg(b.path("test/relaunch.py"));
    relaunch.addArtifactArg(seamed);
    relaunch.has_side_effects = true;
    relaunch.expectExitCode(0);
    test_step.dependOn(&relaunch.step);
    b.step("test-relaunch", "Run the pane.relaunch cases").dependOn(&relaunch.step);
    // The standalone entry point (bare `venomx`, `new`, `attach`) on PTYs.
    const standalone = b.addSystemCommand(&.{"python3"});
    standalone.addFileArg(b.path("test/standalone.py"));
    standalone.addArtifactArg(executable);
    standalone.has_side_effects = true;
    standalone.expectExitCode(0);
    test_step.dependOn(&standalone.step);
    b.step("test-standalone", "Run the standalone entry point cases").dependOn(&standalone.step);
    const run_cases = b.addSystemCommand(&.{"python3"});
    run_cases.addFileArg(b.path("test/run.py"));
    run_cases.addArtifactArg(seamed);
    run_cases.has_side_effects = true;
    run_cases.expectExitCode(0);
    test_step.dependOn(&run_cases.step);
    b.step("test-run", "Run the trusted run/wait cases").dependOn(&run_cases.step);
    // docs/site/reference/commands.md is `venomx docs`; `test` fails when it is stale.
    const site_docs_check = b.addSystemCommand(&.{ "python3", "-I" });
    site_docs_check.addFileArg(b.path("test/site_docs.py"));
    site_docs_check.addArtifactArg(executable);
    site_docs_check.has_side_effects = true;
    site_docs_check.expectExitCode(0);
    test_step.dependOn(&site_docs_check.step);
    const site_docs = b.addSystemCommand(&.{ "python3", "-I" });
    site_docs.addFileArg(b.path("test/site_docs.py"));
    site_docs.addArtifactArg(executable);
    site_docs.addArg("--write");
    site_docs.has_side_effects = true;
    b.step("site-docs", "Regenerate docs/site/reference/commands.md from the verb schema").dependOn(&site_docs.step);
    // Key-to-echo latency through an emulating attach client.
    // Timing-based, so not part of `test`; `-- --max-ms 5` gates it.
    const echo_bench = b.addSystemCommand(&.{"python3"});
    echo_bench.addFileArg(b.path("test/echo_bench.py"));
    echo_bench.addArtifactArg(executable);
    echo_bench.addPassthruArgs();
    echo_bench.has_side_effects = true;
    b.step("bench-echo", "Measure attach --session key-to-echo latency").dependOn(&echo_bench.step);
    // The built venomx against the tmux, zellij and tuios on PATH.
    // Timing-based, so not part of `test`; run it with -Doptimize=ReleaseFast.
    const mux_bench = b.addSystemCommand(&.{ "python3", "-I" });
    mux_bench.addFileArg(b.path("test/muxbench.py"));
    mux_bench.addArg("--venomx");
    mux_bench.addArtifactArg(executable);
    mux_bench.addPassthruArgs();
    mux_bench.has_side_effects = true;
    b.step("bench-compare", "Benchmark venomx against tmux, zellij and tuios").dependOn(&mux_bench.step);
    const conformance = @import("venom_std").addConformance(b, .{ .suite = shared.path("conformance/agent_contract.py"), .exe = executable, .profile = b.path("conformance/venomx.json") });
    b.step("test-conformance", "Run packaged venom-std conformance against venomx").dependOn(&conformance.step);
    test_step.dependOn(&conformance.step);
}

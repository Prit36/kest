const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const diagnostics = b.option(bool, "diagnostics", "Include headless snapshots and the UI self-test harness") orelse false;
    const c_optimization = switch (optimize) {
        .fast => "-O3",
        .small => "-Os",
        .debug, .safe => "-O2",
    };
    const c_flags: []const []const u8 = &.{ "-std=c99", c_optimization, "-ffunction-sections", "-fdata-sections" };
    if (target.result.os.tag != .windows) @panic("The CUI host is currently Windows-only; the Zig engine remains portable.");
    const dep = b.dependency("cui", .{});
    const bindings = b.addTranslateC(.{ .root_source_file = b.path("src/host.h"), .target = target, .optimize = optimize });
    bindings.addIncludePath(dep.path("CUI-d0383c4d3c00b7769f6b11cefdf581e1800f2da3/include"));
    const cui = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    cui.addIncludePath(dep.path("CUI-d0383c4d3c00b7769f6b11cefdf581e1800f2da3/include"));
    cui.addIncludePath(dep.path("CUI-d0383c4d3c00b7769f6b11cefdf581e1800f2da3/src"));
    cui.addIncludePath(dep.path("CUI-d0383c4d3c00b7769f6b11cefdf581e1800f2da3/"));
    cui.addCSourceFiles(.{ .root = dep.path("CUI-d0383c4d3c00b7769f6b11cefdf581e1800f2da3/"), .files = &.{
        "src/cui_core.c",         "src/cui_theme.c",            "src/cui_draw.c",               "src/cui_text.c",
        "src/cui_layout.c",       "src/cui_widgets.c",          "src/cui_controls.c",           "src/cui_textedit.c",
        "src/cui_overlay.c",      "src/cui_data.c",             "src/cui_actions.c",            "src/cui_disclosure.c",
        "src/cui_extras.c",       "src/cui_grid.c",             "src/cui_treetable.c",          "src/cui_markdown.c",
        "src/cui_editor.c",       "src/cui_diff.c",             "src/cui_code.c",               "src/cui_tools.c",
        "src/cui_hex.c",          "src/cui_chrome.c",           "src/cui_charts.c",             "src/cui_image.c",
        "src/cui_font_data.c",    "src/cui_inflate.c",          "src/render/cui_render_sw.c",   "src/render/cui_render_gl.c",
        "src/platform/cui_app.c", "src/platform/cui_dialogs.c", "src/platform/cui_app_win32.c",
    }, .flags = c_flags });
    cui.addCSourceFile(.{ .file = b.path("src/host.c"), .flags = c_flags });
    cui.addCSourceFile(.{ .file = b.path("src/controls.c"), .flags = c_flags });
    cui.addCSourceFile(.{ .file = b.path("src/image.c"), .flags = c_flags });
    cui.addIncludePath(b.path("src"));
    for ([_][]const u8{ "user32", "gdi32", "opengl32", "shell32", "imm32", "dwmapi", "comdlg32", "ole32" }) |name|
        cui.linkSystemLibrary(name, .{});
    const cui_lib = b.addLibrary(.{ .name = "cui", .root_module = cui, .linkage = .static });
    const cui_bindings = bindings.createModule();
    const exe = appExecutable(b, "kest", target, optimize, cui_lib, cui_bindings, diagnostics);
    b.installArtifact(exe);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("LICENSE"), "licenses/Retort-MIT.txt").step);
    b.getInstallStep().dependOn(&b.addInstallFile(dep.path("CUI-d0383c4d3c00b7769f6b11cefdf581e1800f2da3/LICENSE"), "licenses/CUI-MIT.txt").step);
    b.getInstallStep().dependOn(&b.addInstallFile(dep.path("CUI-d0383c4d3c00b7769f6b11cefdf581e1800f2da3/THIRD_PARTY.md"), "licenses/CUI-THIRD-PARTY.md").step);
    for ([_][]const u8{ "Inter", "Geist", "Lucide" }) |font|
        b.getInstallStep().dependOn(&b.addInstallFile(dep.path(b.fmt("CUI-d0383c4d3c00b7769f6b11cefdf581e1800f2da3/assets/fonts/LICENSE-{s}.txt", .{font})), b.fmt("licenses/LICENSE-{s}.txt", .{font})).step);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Open Kest").dependOn(&run.step);

    const lib = b.createModule(.{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = optimize });
    lib.addAnonymousImport("fixtures", .{ .root_source_file = b.path("tests/fixtures/fixtures.zig") });
    const server = b.createModule(.{ .root_source_file = b.path("tests/integration/test_server.zig"), .target = target, .optimize = optimize });
    exe.root_module.addImport("demo_server", server);
    if (diagnostics) exe.root_module.addImport("test_server", server);
    const test_step = b.step("test", "Run engine, HTTP and CUI headless tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lib })).step);
    const http = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/integration/http_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "retort", .module = lib }, .{ .name = "test_server", .module = server } },
    }) });
    test_step.dependOn(&b.addRunArtifact(http).step);
    const check_exe = appExecutable(b, "kest-check", target, optimize, cui_lib, cui_bindings, true);
    check_exe.root_module.addImport("test_server", server);
    check_exe.root_module.addImport("demo_server", server);
    const check = b.addRunArtifact(check_exe);
    check.addArg("--self-test");
    check.setEnvironmentVariable("RETORT_DATA", "test-output/workspace");
    test_step.dependOn(&check.step);
    const demo_check = b.addRunArtifact(check_exe);
    demo_check.addArgs(&.{ "--demo", "--snapshot=test-output/demo-test.png" });
    demo_check.setEnvironmentVariable("RETORT_DATA", "test-output/demo-test-workspaces");
    test_step.dependOn(&demo_check.step);
    const bench = b.addExecutable(.{ .name = "bench", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/performance/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "retort", .module = lib }, .{ .name = "test_server", .module = server } },
    }) });
    b.step("bench", "Measure engine and storage").dependOn(&b.addRunArtifact(bench).step);
    const smoke = b.addExecutable(.{ .name = "smoke", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/integration/smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "retort", .module = lib }},
    }) });
    const sr = b.addRunArtifact(smoke);
    sr.addPassthruArgs();
    b.step("smoke", "Send a request from the command line").dependOn(&sr.step);
}

fn appExecutable(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, cui_lib: *std.Build.Step.Compile, cui_bindings: *std.Build.Module, diagnostics: bool) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption(bool, "diagnostics", diagnostics);
    const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize == .fast or optimize == .small,
    }) });
    exe.root_module.addOptions("build_options", options);
    exe.root_module.linkLibrary(cui_lib);
    exe.root_module.addImport("cui", cui_bindings);
    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/kest.rc") });
    exe.subsystem = .windows;
    return exe;
}

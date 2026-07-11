const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const harfbuzz = b.dependency("harfbuzz", .{});
    const sheenbidi = b.dependency("sheenbidi", .{});
    const libunibreak = b.dependency("libunibreak", .{});
    const harfbuzz_flags = &.{
        "-std=c++17",
        "-Oz",
        "-fno-exceptions",
        "-fno-rtti",
        "-DHB_TINY",
        "-Dhb_malloc_impl=html2realpdf_hb_malloc",
        "-Dhb_calloc_impl=html2realpdf_hb_calloc",
        "-Dhb_realloc_impl=html2realpdf_hb_realloc",
        "-Dhb_free_impl=html2realpdf_hb_free",
    };
    const native_harfbuzz_object = buildHarfBuzzObject(
        b,
        target.query.zigTriple(b.allocator) catch @panic("OOM"),
        harfbuzz.path("src"),
        harfbuzz_flags,
        "harfbuzz-native.o",
    );
    const wasm_harfbuzz_object = buildHarfBuzzObject(
        b,
        "wasm32-wasi",
        harfbuzz.path("src"),
        harfbuzz_flags,
        "harfbuzz-wasm.o",
    );
    const sheenbidi_flags = &.{
        "-std=c11",
        "-Oz",
        "-DSB_CONFIG_UNITY",
        "-DSB_CONFIG_DISABLE_SCRATCH_MEMORY",
        "-Dmalloc=html2realpdf_sb_malloc",
        "-Drealloc=html2realpdf_sb_realloc",
        "-Dfree=html2realpdf_sb_free",
    };
    const native_sheenbidi_object = buildSheenBidiObject(
        b,
        target.query.zigTriple(b.allocator) catch @panic("OOM"),
        sheenbidi.path(""),
        sheenbidi_flags,
        "sheenbidi-native.o",
    );
    const wasm_sheenbidi_object = buildSheenBidiObject(
        b,
        "wasm32-wasi",
        sheenbidi.path(""),
        sheenbidi_flags,
        "sheenbidi-wasm.o",
    );
    const native_libunibreak_object = buildLibunibreakObject(
        b,
        target.query.zigTriple(b.allocator) catch @panic("OOM"),
        libunibreak.path("src"),
        "libunibreak-native.o",
    );
    const wasm_libunibreak_object = buildLibunibreakObject(
        b,
        "wasm32-wasi",
        libunibreak.path("src"),
        "libunibreak-wasm.o",
    );

    // ------------------------------------------------------------
    // Native CLI build: src/main.zig
    // ------------------------------------------------------------

    const native_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    native_lib_mod.addObjectFile(native_harfbuzz_object);
    native_lib_mod.addObjectFile(native_sheenbidi_object);
    native_lib_mod.addObjectFile(native_libunibreak_object);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "html2realpdf", .module = native_lib_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "html2realpdf",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the CLI app");
    run_step.dependOn(&run_cmd.step);

    // ------------------------------------------------------------
    // WASM build: src/wasm.zig
    // ------------------------------------------------------------

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    wasm_lib_mod.addObjectFile(wasm_harfbuzz_object);
    wasm_lib_mod.addObjectFile(wasm_sheenbidi_object);
    wasm_lib_mod.addObjectFile(wasm_libunibreak_object);

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "html2realpdf", .module = wasm_lib_mod },
        },
    });

    wasm_mod.export_symbol_names = &.{
        "html2realpdf_abi_version",
        "pdf_context_create",
        "pdf_context_free",
        "pdf_context_register_font",
        "alloc",
        "free",
        "tokenize_html",
        "dom_tree_html",
        "dom_tree_output_len",
        "box_tree_html",
        "box_tree_output_len",
        "cascade_tree_html",
        "cascade_tree_output_len",
        "render_html_to_pdf",
        "render_html_to_pdf_with_options",
        "render_html_to_pdf_with_json_options",
        "render_html_to_pdf_with_context_json_options",
        "pdf_result_status",
        "pdf_result_data_ptr",
        "pdf_result_data_len",
        "pdf_result_page_count",
        "pdf_result_error_ptr",
        "pdf_result_error_len",
        "pdf_result_diagnostics_ptr",
        "pdf_result_diagnostics_len",
        "pdf_result_free",
    };

    const wasm = b.addExecutable(.{
        .name = "libhtml2realpdf",
        .root_module = wasm_mod,
    });

    wasm.entry = .disabled;

    if (@hasField(@TypeOf(wasm.*), "export_memory")) {
        wasm.export_memory = true;
    }

    const install_wasm = b.addInstallArtifact(wasm, .{});

    const wasm_step = b.step("wasm", "Build the WebAssembly module");
    wasm_step.dependOn(&install_wasm.step);

    const harfbuzz_test_mod = b.createModule(.{
        .root_source_file = b.path("src/harfbuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    harfbuzz_test_mod.addObjectFile(native_harfbuzz_object);
    const harfbuzz_tests = b.addTest(.{ .root_module = harfbuzz_test_mod });
    const run_harfbuzz_tests = b.addRunArtifact(harfbuzz_tests);
    const harfbuzz_test_step = b.step("test-harfbuzz", "Run the linked HarfBuzz shaping tests");
    harfbuzz_test_step.dependOn(&run_harfbuzz_tests.step);

    const bidi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/bidi_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    bidi_test_mod.addObjectFile(native_sheenbidi_object);
    const bidi_tests = b.addTest(.{ .root_module = bidi_test_mod });
    const run_bidi_tests = b.addRunArtifact(bidi_tests);
    const bidi_test_step = b.step("test-bidi", "Run the linked Unicode bidi tests");
    bidi_test_step.dependOn(&run_bidi_tests.step);

    const line_break_test_mod = b.createModule(.{
        .root_source_file = b.path("src/line_break_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    line_break_test_mod.addObjectFile(native_libunibreak_object);
    const line_break_tests = b.addTest(.{ .root_module = line_break_test_mod });
    const run_line_break_tests = b.addRunArtifact(line_break_tests);
    const line_break_test_step = b.step("test-line-break", "Run the linked Unicode line-breaking tests");
    line_break_test_step.dependOn(&run_line_break_tests.step);

    const bidi_integration_mod = b.createModule(.{
        .root_source_file = b.path("src/bidi_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    bidi_integration_mod.addObjectFile(native_harfbuzz_object);
    bidi_integration_mod.addObjectFile(native_sheenbidi_object);
    bidi_integration_mod.addObjectFile(native_libunibreak_object);
    const bidi_integration = b.addExecutable(.{
        .name = "html2realpdf-bidi-integration",
        .root_module = bidi_integration_mod,
    });
    const run_bidi_integration = b.addRunArtifact(bidi_integration);
    const bidi_integration_step = b.step("test-bidi-integration", "Run production shaping and bidi layout integration");
    bidi_integration_step.dependOn(&run_bidi_integration.step);
}

fn buildHarfBuzzObject(
    b: *std.Build,
    target_triple: []const u8,
    include_directory: std.Build.LazyPath,
    flags: []const []const u8,
    output_name: []const u8,
) std.Build.LazyPath {
    const command = b.addSystemCommand(&.{ "zig", "c++", "-target", target_triple });
    command.addArgs(flags);
    command.addArg("-I");
    command.addDirectoryArg(include_directory);
    command.addArg("-c");
    command.addFileArg(b.path("src/harfbuzz.cc"));
    command.addArg("-o");
    return command.addOutputFileArg(output_name);
}

fn buildSheenBidiObject(
    b: *std.Build,
    target_triple: []const u8,
    root_directory: std.Build.LazyPath,
    flags: []const []const u8,
    output_name: []const u8,
) std.Build.LazyPath {
    const command = b.addSystemCommand(&.{ "zig", "cc", "-target", target_triple });
    command.addArgs(flags);
    command.addArg("-I");
    command.addDirectoryArg(root_directory.path(b, "Headers"));
    command.addArg("-I");
    command.addDirectoryArg(root_directory.path(b, "Source"));
    command.addArg("-c");
    command.addFileArg(root_directory.path(b, "Source/SheenBidi.c"));
    command.addArg("-o");
    return command.addOutputFileArg(output_name);
}

fn buildLibunibreakObject(
    b: *std.Build,
    target_triple: []const u8,
    include_directory: std.Build.LazyPath,
    output_name: []const u8,
) std.Build.LazyPath {
    const command = b.addSystemCommand(&.{ "zig", "cc", "-target", target_triple });
    command.addArgs(&.{ "-std=c11", "-Oz", "-I" });
    command.addDirectoryArg(include_directory);
    command.addArg("-c");
    command.addFileArg(b.path("src/libunibreak.c"));
    command.addArg("-o");
    return command.addOutputFileArg(output_name);
}

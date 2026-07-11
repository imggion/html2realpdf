const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ------------------------------------------------------------
    // Native CLI build: src/main.zig
    // ------------------------------------------------------------

    const native_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

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
}

const std = @import("std");

const tree_sitter_flags = &.{"-fno-sanitize=undefined"};

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const tree_sitter_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    const tree_sitter_lib = b.addLibrary(.{
        .name = "mdr-tree-sitter",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tree_sitter_lib.root_module.addIncludePath(tree_sitter_dep.path("tree-sitter/lib/include"));
    tree_sitter_lib.root_module.addIncludePath(tree_sitter_dep.path("tree-sitter/lib/src"));
    tree_sitter_lib.root_module.addCSourceFiles(.{
        .root = tree_sitter_dep.path("tree-sitter/lib/src"),
        .files = &.{"lib.c"},
        .flags = tree_sitter_flags,
    });
    addTreeSitterParser(tree_sitter_lib, tree_sitter_dep, .{ .source_dir = "tree-sitter-bash/src", .has_scanner = true });
    addTreeSitterParser(tree_sitter_lib, tree_sitter_dep, .{ .source_dir = "tree-sitter-c/src" });
    addTreeSitterParser(tree_sitter_lib, tree_sitter_dep, .{ .source_dir = "tree-sitter-cpp/src", .has_scanner = true });
    addTreeSitterParser(tree_sitter_lib, tree_sitter_dep, .{ .source_dir = "tree-sitter-javascript/src", .has_scanner = true });
    addTreeSitterParser(tree_sitter_lib, tree_sitter_dep, .{ .source_dir = "tree-sitter-go/src" });
    addTreeSitterParser(tree_sitter_lib, tree_sitter_dep, .{ .source_dir = "tree-sitter-json/src" });
    addTreeSitterParser(tree_sitter_lib, tree_sitter_dep, .{ .source_dir = "tree-sitter-python/src", .has_scanner = true });
    addTreeSitterParser(tree_sitter_lib, tree_sitter_dep, .{ .source_dir = "tree-sitter-rust/src", .has_scanner = true });
    addTreeSitterParser(tree_sitter_lib, tree_sitter_dep, .{ .source_dir = "tree-sitter-typescript/typescript/src", .has_scanner = true });
    addTreeSitterParser(tree_sitter_lib, tree_sitter_dep, .{ .source_dir = "tree-sitter-typescript/tsx/src", .has_scanner = true });
    addTreeSitterParser(tree_sitter_lib, tree_sitter_dep, .{ .source_dir = "tree-sitter-zig/src" });
    const treez_mod = b.createModule(.{
        .root_source_file = tree_sitter_dep.path("treez/treez.zig"),
    });
    treez_mod.linkLibrary(tree_sitter_lib);
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("mdr", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });
    mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    mod.addImport("treez", treez_mod);
    addSyntaxQuery(mod, tree_sitter_dep, "bash");
    addSyntaxQuery(mod, tree_sitter_dep, "c");
    addSyntaxQuery(mod, tree_sitter_dep, "cpp");
    addSyntaxQuery(mod, tree_sitter_dep, "javascript");
    addSyntaxQuery(mod, tree_sitter_dep, "go");
    addSyntaxQuery(mod, tree_sitter_dep, "json");
    addSyntaxQuery(mod, tree_sitter_dep, "python");
    addSyntaxQuery(mod, tree_sitter_dep, "rust");
    addSyntaxQuery(mod, tree_sitter_dep, "typescript");
    addSyntaxQuery(mod, tree_sitter_dep, "zig");

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "mdr",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "mdr" is the name you will use in your source code to
                // import this module (e.g. `@import("mdr")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "mdr", .module = mod },
            },
        }),
    });
    // Work around https://github.com/zigimg/zigimg/issues/318.
    exe.use_llvm = true;

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.use_llvm = true;

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.use_llvm = true;

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const bombadil_step = b.step("bombadil", "Run Bombadil terminal property tests");
    bombadil_step.dependOn(&addBombadilTest(b, exe).step);

    const benchmark = b.addExecutable(.{
        .name = "benchmark-mermaid",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark_mermaid.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vaxis", .module = vaxis_dep.module("vaxis") }},
        }),
    });
    const benchmark_step = b.step("benchmark-mermaid", "Benchmark Mermaid parsing and layout");
    benchmark_step.dependOn(&b.addRunArtifact(benchmark).step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

fn addTreeSitterParser(
    lib: *std.Build.Step.Compile,
    dep: *std.Build.Dependency,
    options: struct {
        source_dir: []const u8,
        has_scanner: bool = false,
    },
) void {
    lib.root_module.addIncludePath(dep.path(options.source_dir));
    lib.root_module.addCSourceFiles(.{
        .root = dep.path(options.source_dir),
        .files = if (options.has_scanner) &.{ "parser.c", "scanner.c" } else &.{"parser.c"},
        .flags = tree_sitter_flags,
    });
}

fn addSyntaxQuery(mod: *std.Build.Module, dep: *std.Build.Dependency, comptime language: []const u8) void {
    mod.addAnonymousImport("syntax_" ++ language, .{
        .root_source_file = dep.path("tree-sitter-" ++ language ++ "/queries/highlights.scm"),
    });
}

fn addBombadilTest(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const output_path = b.getInstallPath(.prefix, "bombadil");
    const run = b.addSystemCommand(&.{
        "bombadil",
        "terminal",
        "test",
        "--specification",
    });
    run.addFileArg(b.path("bombadil/mdr.ts"));
    run.addArgs(&.{
        "--time-limit",
        "5m",
        "--exit-on-violation",
        "--columns",
        "120",
        "--rows",
        "24",
        "--quiescence-timeout-ms",
        "250",
        "--output-path",
        output_path,
        "--output-path-overwrite",
        "--",
    });
    run.addArtifactArg(exe);
    run.addFileArg(b.path("bombadil/fixture.md"));
    run.has_side_effects = true;
    return run;
}

const std = @import("std");

const Base = struct {
    crypto_c: []const []const u8 = &.{},
    jitter_c: []const []const u8 = &.{},
    ssl_cc: []const []const u8 = &.{},
};

const Tests = struct {
    cxx_std: []const u8,
    defines: []const []const u8 = &.{},
    includes: []const []const u8 = &.{},
    support: []const []const u8 = &.{},
    crypto_test: []const []const u8 = &.{},
    ssl_test: []const []const u8 = &.{},
};

const TestExe = struct {
    name: []const u8,
    files: []const []const u8,
};

fn loadZon(comptime T: type, b: *std.Build, path: []const u8) !?T {
    const pathx = try b.root.joinString(b.allocator, path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, pathx, b.allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const source = try b.allocator.allocSentinel(u8, bytes.len, 0);
    @memcpy(source, bytes);

    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = source,
        .diagnostics = &diag,
    }) catch |err| switch (err) {
        error.ParseZon => diag.fatal(path),
        error.OutOfMemory => |e| return e,
    };
}

fn cat(b: *std.Build, a: []const []const u8, c: []const []const u8) []const []const u8 {
    return std.mem.concat(b.allocator, []const u8, &.{ a, c }) catch @panic("OOM");
}

fn addAsm(
    b: *std.Build,
    mod: *std.Build.Module,
    upstream: *std.Build.Dependency,
    files: []const []const u8,
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
) ![]const []const u8 {
    var gas: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        if (!std.mem.endsWith(u8, f, ".asm")) {
            try gas.append(b.allocator, f);
            continue;
        }

        if (os != .windows) return error.UnsupportedNasmTarget;
        const format: []const u8 = switch (arch) {
            .x86_64 => "win64",
            .x86 => "win32",
            else => return error.UnsupportedNasmTarget,
        };

        const name = std.fs.path.stem(f);
        const run = if (b.systemIntegrationOption("nasm", .{}))
            b.addSystemCommand(&.{"nasm"})
        else
            b.addRunArtifact((b.lazyDependency("nasm", .{ .optimize = .ReleaseFast }) orelse return gas.items).artifact("nasm"));

        run.addArgs(&.{ "-f", format, "-MD" });
        _ = run.addDepFileOutputArg(b.fmt("{s}.d", .{name}));
        run.addPrefixedDirectoryArg("-I", upstream.path("include"));
        run.addFileArg(upstream.path(f));
        run.addArg("-o");
        mod.addObjectFile(run.addOutputFileArg(b.fmt("{s}.obj", .{name})));
    }
    return gas.items;
}

fn addTestIncludes(mod: *std.Build.Module, upstream: *std.Build.Dependency, paths: []const []const u8) void {
    mod.addIncludePath(upstream.path("."));
    mod.addIncludePath(upstream.path("include"));
    for (paths) |p| mod.addIncludePath(upstream.path(p));
}

fn addTestFiles(
    b: *std.Build,
    mod: *std.Build.Module,
    upstream: *std.Build.Dependency,
    files: []const []const u8,
    c_flags: []const []const u8,
    cc_flags: []const []const u8,
) !void {
    var c_files: std.ArrayList([]const u8) = .empty;
    var cc_files: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        if (std.mem.endsWith(u8, f, ".c")) {
            try c_files.append(b.allocator, f);
        } else {
            try cc_files.append(b.allocator, f);
        }
    }
    mod.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = c_files.items,
        .flags = c_flags,
    });
    mod.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = cc_files.items,
        .flags = cc_flags,
    });
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linkage = b.option(std.builtin.LinkMode, "linkage", "static or dynamic") orelse .static;
    const ssl = b.option(bool, "ssl", "wheter to build libssl") orelse true;
    const crypto = (b.option(bool, "crypto", "wheter to build libcrypto") orelse true) or ssl;
    const strip = b.option(bool, "strip", "wheter to remove debug info") orelse (optimize != .debug);

    const upstream = b.dependency("aws-lc", .{});

    b.addNamedLazyPath("include", upstream.path("include"));

    const vendor = b.addSystemCommand(&.{ "python3", "-u" });
    vendor.addFileArg(b.path("scripts/vendor.py"));
    vendor.addArgs(&.{ "--zig", b.graph.zig_exe });
    if (!b.systemIntegrationOption("nasm", .{})) {
        if (b.lazyDependency("nasm", .{ .optimize = .ReleaseFast })) |nasm_dep| {
            vendor.addArg("--nasm");
            vendor.addArtifactArg(nasm_dep.artifact("nasm"));
        }
    }
    vendor.addArg("--src");
    vendor.addDirectoryArg2(upstream.path("."), .{});
    vendor.addArg("--out");
    vendor.addDirectoryArg2(b.path("generated"), .{});
    vendor.has_side_effects = true;
    vendor.stdio = .inherit;
    b.step("vendor", "Regenerate vendored sources").dependOn(&vendor.step);

    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;

    const base = (try loadZon(Base, b, "generated/generic.zon")) orelse {
        const fail = b.addFail("Missing generic sources!");
        b.getInstallStep().dependOn(&fail.step);
        return;
    };
    const asm_files = try loadZon([]const []const u8, b, b.fmt("generated/{s}_{s}.zon", .{ @tagName(os), @tagName(arch) }));
    const generic = asm_files == null;
    const crypto_asm: []const []const u8 = asm_files orelse &.{};

    var flags: std.ArrayList([]const u8) = .empty;
    try flags.appendSlice(b.allocator, &.{
        "-fvisibility=hidden",
        "-fno-common",
        "-ffunction-sections",
        "-fdata-sections",
        "-fno-sanitize=undefined",
        "-DBORINGSSL_IMPLEMENTATION",
        "-DAWS_LC_STDALIGN_AVAILABLE",
        "-DAWS_LC_BUILTIN_SWAP_SUPPORTED",
        "-DBORINGSSL_RELEASE_BUILD",
        "-DNDEBUG",
        "-DS2N_BN_HIDE_SYMBOLS",
    });
    if (generic) try flags.append(b.allocator, "-DOPENSSL_NO_ASM");
    if (os == .linux) try flags.appendSlice(b.allocator, &.{ "-DHAVE_LINUX_RANDOM_H", "-D_XOPEN_SOURCE=700" });
    if (os == .windows) try flags.appendSlice(b.allocator, &.{ "-DWIN32_LEAN_AND_MEAN", "-DNOMINMAX" });
    if (linkage == .dynamic) try flags.append(b.allocator, "-DBORINGSSL_SHARED_LIBRARY");

    const gnu: []const []const u8 = &.{"-std=gnu11"};
    const jitter: []const []const u8 = &.{ "-DAWSLC", "-fwrapv", "-O0", "-U_FORTIFY_SOURCE", "-fno-stack-protector" };
    const cxx: []const []const u8 = &.{ "-std=c++11", "-fno-exceptions", "-fno-rtti" };

    var crypto_lib: ?*std.Build.Step.Compile = null;
    var ssl_lib: ?*std.Build.Step.Compile = null;

    if (crypto) {
        const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true, .strip = strip });

        const gas = try addAsm(b, mod, upstream, crypto_asm, os, arch);

        mod.addIncludePath(upstream.path("include"));
        mod.addIncludePath(upstream.path("third_party/jitterentropy/jitterentropy-library"));
        mod.addIncludePath(upstream.path("third_party/s2n-bignum/s2n-bignum-imported/include"));

        mod.addCSourceFiles(.{
            .root = upstream.path("."),
            .files = cat(b, base.crypto_c, gas),
            .flags = cat(b, flags.items, gnu),
        });
        mod.addCSourceFiles(.{
            .root = upstream.path("."),
            .files = base.jitter_c,
            .flags = cat(b, cat(b, flags.items, jitter), gnu),
        });

        if (os == .windows) {
            mod.linkSystemLibrary("advapi32", .{});
            mod.linkSystemLibrary("bcrypt", .{});
        }

        const lib = b.addLibrary(.{ .name = "crypto", .linkage = linkage, .root_module = mod });
        b.installArtifact(lib);
        crypto_lib = lib;
    }

    if (ssl) {
        const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true, .pic = true, .strip = strip });

        var c_files: std.ArrayList([]const u8) = .empty;
        var cpp_files: std.ArrayList([]const u8) = .empty;
        for (base.ssl_cc) |f| {
            if (std.mem.endsWith(u8, f, ".cc") or std.mem.endsWith(u8, f, ".cpp")) {
                try cpp_files.append(b.allocator, f);
            } else {
                try c_files.append(b.allocator, f);
            }
        }

        mod.addIncludePath(upstream.path("include"));
        mod.addCSourceFiles(.{
            .root = upstream.path("."),
            .files = cpp_files.items,
            .flags = cat(b, flags.items, cxx),
        });
        mod.addCSourceFiles(.{
            .root = upstream.path("."),
            .files = c_files.items,
            .flags = cat(b, flags.items, gnu),
        });

        if (os == .windows) mod.linkSystemLibrary("ws2_32", .{});
        mod.linkLibrary(crypto_lib.?);

        const lib = b.addLibrary(.{ .name = "ssl", .linkage = linkage, .root_module = mod });
        b.installArtifact(lib);
        ssl_lib = lib;
    }

    const test_step = b.step("test", "Build and run the aws-lc test suites");

    if (linkage != .static or ssl_lib == null) {
        test_step.dependOn(&b.addFail("the test suites need -Dlinkage=static and libssl").step);
        return;
    }

    const t = (try loadZon(Tests, b, "generated/tests.zon")) orelse {
        test_step.dependOn(&b.addFail("Missing test sources, run zig build vendor").step);
        return;
    };
    const test_asm_files = try loadZon([]const []const u8, b, b.fmt("generated/tests_{s}_{s}.zon", .{ @tagName(os), @tagName(arch) }));
    const test_asm: []const []const u8 = test_asm_files orelse &.{};

    if (!generic and test_asm.len == 0) {
        std.log.warn("abi tests are not compiled for {s}-{s}. reason: (N/A)", .{ @tagName(arch), @tagName(os) });
    }

    const test_c = cat(b, cat(b, flags.items, t.defines), gnu);
    const test_cc = cat(b, cat(b, flags.items, t.defines), &.{t.cxx_std});

    const shim = b.addWriteFiles().add("test_data_shim.cc",
        \\#include <stdio.h>
        \\#include <stdlib.h>
        \\#include <string>
        \\
        \\std::string GetTestData(const char *path) {
        \\  FILE *f = fopen(path, "rb");
        \\  if (f == nullptr) {
        \\    perror(path);
        \\    abort();
        \\  }
        \\  std::string out;
        \\  char buf[4096];
        \\  size_t n;
        \\  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        \\    out.append(buf, n);
        \\  }
        \\  fclose(f);
        \\  return out;
        \\}
        \\
    );

    const support_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .strip = strip,
    });
    addTestIncludes(support_mod, upstream, t.includes);
    try addTestFiles(b, support_mod, upstream, t.support, test_c, test_cc);
    support_mod.addCSourceFile(.{ .file = shim, .flags = test_cc });
    support_mod.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = try addAsm(b, support_mod, upstream, test_asm, os, arch),
        .flags = flags.items,
    });
    support_mod.linkLibrary(ssl_lib.?);
    support_mod.linkLibrary(crypto_lib.?);
    const support_lib = b.addLibrary(.{
        .name = "aws_lc_test_support",
        .linkage = .static,
        .root_module = support_mod,
    });

    const exes = [_]TestExe{
        .{ .name = "crypto_test", .files = t.crypto_test },
        .{ .name = "ssl_test", .files = t.ssl_test },
    };

    for (exes) |spec| {
        if (spec.files.len == 0) continue;

        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .strip = strip,
        });
        addTestIncludes(mod, upstream, t.includes);
        try addTestFiles(b, mod, upstream, spec.files, test_c, test_cc);
        mod.linkLibrary(support_lib);
        mod.linkLibrary(ssl_lib.?);
        mod.linkLibrary(crypto_lib.?);

        const exe = b.addExecutable(.{ .name = spec.name, .root_module = mod });

        const run = b.addRunArtifact(exe);
        run.setCwd(upstream.path("."));
        test_step.dependOn(&run.step);
    }
}

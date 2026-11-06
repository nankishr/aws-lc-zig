const std = @import("std");

const Base = struct {
    crypto_c: []const []const u8 = &.{},
    jitter_c: []const []const u8 = &.{},
    ssl_cc: []const []const u8 = &.{},
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

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ });
    const linkage = b.option(std.builtin.LinkMode, "linkage", "static or dynamic") orelse .static;
    const ssl = b.option(bool, "ssl", "wheter to build libssl") orelse true;
    const crypto = (b.option(bool, "crypto", "wheter to build libcrypto") orelse true) or ssl;

    const upstream = b.dependency("aws-lc", .{});

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

    if (crypto) {
        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        });

        var gas: std.ArrayList([]const u8) = .empty;
        for (crypto_asm) |f| {
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
                b.addRunArtifact((b.lazyDependency("nasm", .{ .optimize = .ReleaseFast }) orelse return).artifact("nasm"));

            run.addArgs(&.{ "-f", format, "-MD" });
            _ = run.addDepFileOutputArg(b.fmt("{s}.d", .{name}));
            run.addPrefixedDirectoryArg("-I", upstream.path("include"));
            run.addFileArg(upstream.path(f));
            run.addArg("-o");
            mod.addObjectFile(run.addOutputFileArg(b.fmt("{s}.obj", .{name})));
        }

        mod.addIncludePath(upstream.path("include"));
        mod.addIncludePath(upstream.path("third_party/jitterentropy/jitterentropy-library"));
        mod.addIncludePath(upstream.path("third_party/s2n-bignum/s2n-bignum-imported/include"));

        mod.addCSourceFiles(.{
            .root = upstream.path("."),
            .files = cat(b, base.crypto_c, gas.items),
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
        lib.installHeadersDirectory(upstream.path("include/openssl"), "openssl", .{});
        b.installArtifact(lib);
        crypto_lib = lib;
    }

    if (ssl) {
        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .pic = true,
        });

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

        b.installArtifact(b.addLibrary(.{ .name = "ssl", .linkage = linkage, .root_module = mod }));
    }
}

## AWS-LC ported to zig

This repository packages [aws-lc](https://github.com/aws/aws-lc/) to be used out-of-the box with the zig build system.

### 1. Installation
```sh
zig fetch --save https://github.com/nankishr/aws-lc-zig/archive/refs/tags/v5.12.0.tar.gz
```
### 2. Usage
```zig
const aws_lc = b.dependency("aws_lc_zig", .{
    .target = target,
    .optimize = optimize,
    // other options with defaults:
    //.linkage = .static,
    //.crypto = true
    //.ssl = true
});

your_module.linkLibrary(aws_lc.artifact("crypto"));
your_module.linkLibrary(aws_lc.artifact("ssl"));
```
### 3. For contributors
#### 3.1. Running tests
```sh
zig build test
```
#### 3.2. Regenerating sources
> **Requirements:** Python, CMake, Ninja, and NASM (optional)

Running
```sh
zig build vendor
```
Autogenerates sources and writes to `/generated` folder.

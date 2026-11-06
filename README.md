## AWS-LC ported to zig

This repository packages [aws-lc](https://github.com/aws/aws-lc/) to be used out-of-the box with the zig build system.

### Installation
```
zig fetch --save https://github.com/nankishr/aws-lc-zig/archive/refs/tags/v5.12.0.tar.gz
```
### Usage
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
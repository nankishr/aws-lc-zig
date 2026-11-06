import argparse
import filecmp
import json
import os
import re
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

TARGETS = {
    "linux_x86_64": ("x86_64-linux-gnu", "Linux", "x86_64"),
    "linux_aarch64": ("aarch64-linux-gnu", "Linux", "aarch64"),
    "linux_arm": ("arm-linux-gnueabihf", "Linux", "armv7-a"),
    "linux_x86": ("x86-linux-gnu", "Linux", "i686"),
    "linux_powerpc64le": ("powerpc64le-linux-gnu", "Linux", "ppc64le"),
    "macos_x86_64": ("x86_64-macos", "Darwin", "x86_64"),
    "macos_aarch64": ("aarch64-macos", "Darwin", "arm64"),
    "windows_x86_64": ("x86_64-windows-gnu", "Windows", "AMD64"),
    "windows_aarch64": ("aarch64-windows-gnu", "Windows", "ARM64"),
    "generic": ("x86_64-linux-gnu", "Linux", "generic"),
}

BASE = ("crypto_c", "jitter_c", "ssl_cc")
KEYS = BASE + ("crypto_asm",)
COPY_RE = re.compile(r"Copying platform assembly files from (\S+) to")


def script(path, body):
    path.write_text(f"#!/bin/sh\n{body}\n")
    path.chmod(0o755)
    return path


def base_zon(found):
    out = "".join(
        f"    .{k} = .{{\n" + "".join(f"        {json.dumps(i)},\n" for i in sorted(found[k])) + "    },\n"
        for k in BASE
    )
    return f".{{\n{out}}}\n"


def zon_list(items):
    if not items:
        return None
    return ".{\n" + "".join(f"    {json.dumps(i)},\n" for i in sorted(items)) + "}\n"


def write(path, text):
    if text is None:
        path.unlink(missing_ok=True)
    elif not path.exists() or path.read_text() != text:
        path.write_text(text)


def vendor_target(key, args, src, by_name, tmp):
    triple, system, cpu = TARGETS[key]
    work = Path(tmp) / key
    out = work / "out"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir()
    cc = script(work / "cc", f'exec "{args.zig}" cc -target {triple} "$@"')
    cxx = script(work / "cxx", f'exec "{args.zig}" c++ -target {triple} "$@"')
    cmd = [
        "cmake", "-S", str(src), "-B", str(out), "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        f"-DCMAKE_SYSTEM_NAME={system}",
        f"-DCMAKE_SYSTEM_PROCESSOR={cpu}",
        f"-DCMAKE_C_COMPILER={cc}",
        f"-DCMAKE_CXX_COMPILER={cxx}",
        f"-DCMAKE_ASM_COMPILER={cc}",
        "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
        "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
        "-DBUILD_TESTING=OFF", "-DBUILD_TOOL=OFF", "-DBUILD_LIBSSL=ON",
        "-DDISABLE_GO=ON", "-DDISABLE_PERL=ON",
    ]
    if key == "generic":
        cmd.append("-DOPENSSL_NO_ASM=1")
    env = os.environ.copy()
    if system == "Darwin":
        stubs = work / "stubs"
        stubs.mkdir()
        for name in ("install_name_tool", "otool", "lipo", "libtool"):
            script(stubs / name, "exit 0")
        env["PATH"] = f"{stubs}{os.pathsep}{env['PATH']}"
        cmd.append(f"-DCMAKE_INSTALL_NAME_TOOL={stubs / 'install_name_tool'}")
    nasm_target = system == "Windows" and cpu in ("AMD64", "i686")
    if nasm_target:
        nasm = args.nasm or shutil.which("nasm")
        if not nasm:
            raise ValueError("nasm not found (pass --nasm or put it in PATH)")
        cmd.append(f"-DCMAKE_ASM_NASM_COMPILER={Path(nasm).resolve()}")

    done = subprocess.run(cmd, capture_output=True, text=True, env=env)
    text = done.stdout + done.stderr
    if done.returncode:
        log_note = ""
        if args.log_dir:
            log_dir = Path(args.log_dir).resolve()
            log_dir.mkdir(parents=True, exist_ok=True)
            log_path = log_dir / f"{key}.cmake.log"
            log_path.write_text(" ".join(cmd) + "\n\n" + text)
            log_note = f" (full log: {log_path})"
        lines = [l for l in text.splitlines() if l.strip()]
        start = next((i for i, l in enumerate(lines) if "Error" in l), 0)
        raise ValueError(
            f"cmake failed{log_note}\n"
            + "\n".join(f"        {l}" for l in lines[start:start + 8])
        )
    origins = [Path(a).resolve() for a in COPY_RE.findall(text)]

    entries = json.loads((out / "compile_commands.json").read_text())
    paths = {(Path(e["directory"]) / e["file"]).resolve() for e in entries}
    if nasm_target:
        ninja = subprocess.run(["ninja", "-C", str(out), "-t", "inputs", "crypto"], capture_output=True, text=True)
        if ninja.returncode == 0:
            paths |= {(out / l.strip()).resolve() for l in ninja.stdout.splitlines() if l.strip().endswith(".asm")}

    found = {k: set() for k in KEYS}
    for path in paths:
        if path.is_relative_to(src):
            rel = path.relative_to(src)
        else:
            same = [c for c in by_name.get(path.name, []) if filecmp.cmp(c, path, shallow=False)]
            if len(same) > 1:
                same = [c for c in same if any(c.is_relative_to(o) for o in origins)] or same
            if len(same) != 1:
                raise ValueError(f"{len(same)} matches in generated-src for {path}")
            rel = same[0].relative_to(src)
        if "test" in rel.parts or rel.stem.endswith("_test"):
            continue
        top, ext = rel.parts[0], rel.suffix
        if top == "ssl" and ext in (".c", ".cc", ".cpp"):
            kind = "ssl_cc"
        elif top in ("crypto", "generated-src", "third_party") and ext in (".S", ".s", ".asm"):
            kind = "crypto_asm"
        elif top in ("crypto", "generated-src", "third_party") and ext == ".c":
            kind = "jitter_c" if "jitterentropy" in rel.parts else "crypto_c"
        else:
            raise ValueError(f"cannot classify {rel}")
        found[kind].add(rel.as_posix())
    if not found["crypto_c"]:
        raise ValueError("no crypto sources found")
    return found


def run(key, *a):
    try:
        found = vendor_target(key, *a)
        print(f"finished {key}", flush=True)
        return found
    except (ValueError, OSError, KeyError) as e:
        print(f"failed {key}: {e}", flush=True)
        return None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--zig", default="zig")
    p.add_argument("--nasm")
    p.add_argument("--src", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--log-dir", help="write the full cmake output of failed targets here")
    p.add_argument("-j", "--jobs", type=int, default=0)
    args = p.parse_args()

    for tool in ("cmake", "ninja"):
        if not shutil.which(tool):
            raise SystemExit(f"{tool} not found in PATH")

    keys = list(TARGETS)
    src = Path(args.src).resolve()
    gen = Path(args.out).resolve()
    gen.mkdir(parents=True, exist_ok=True)
    by_name = {}
    for f in (src / "generated-src").rglob("*"):
        if f.is_file():
            by_name.setdefault(f.name, []).append(f)

    jobs = args.jobs or min(len(keys), os.cpu_count() or 1)
    with tempfile.TemporaryDirectory() as tmp, ThreadPoolExecutor(max_workers=jobs) as pool:
        results = dict(zip(keys, pool.map(lambda k: run(k, args, src, by_name, tmp), keys)))

        for key in keys:
            if results[key] is None:
                # reason for this is cause I suspect a race error which caused compiling x86 linux error sometimes
                # too lazy to look into it further so this does the trick for now.
                print(f"retrying {key} serially", flush=True)
                results[key] = run(key, args, src, by_name, tmp)

    base = results["generic"]
    if not base:
        raise SystemExit("generic failed, cannot vendor")

    for stale in ("common.zon", "shared.zon"):
        (gen / stale).unlink(missing_ok=True)

    clean = True
    for key, found in results.items():
        dest = gen / f"{key}.zon"
        if not found:
            dest.unlink(missing_ok=True)
            clean = False
            continue
        if key == "generic":
            write(dest, base_zon(found))
            print("generic: " + ", ".join(f"{len(found[k])} {k}" for k in BASE))
            continue
        drift = [k for k in BASE if found[k] != base[k]]
        if drift:
            print(f"{key}: {', '.join(drift)} differ from generic", flush=True)
            clean = False
        write(dest, zon_list(found["crypto_asm"]))
        print(f"{key}: {len(found['crypto_asm'])} crypto_asm")
    raise SystemExit(0 if clean else 1)


if __name__ == "__main__":
    main()
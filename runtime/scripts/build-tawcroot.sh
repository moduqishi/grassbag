#!/usr/bin/env bash
# Reproducibly cross-compile MIT-licensed tawcroot (`wmww/tawc`) for Android arm64-v8a
# into `app/android/app/src/main/jniLibs/arm64-v8a/libtawcroot.so` using Android NDK.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
NDK_DIR="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"
if [[ ! -d "$NDK_DIR" ]]; then
  NDK_DIR="$(ls -d "$HOME/Library/Android/sdk/ndk/"* 2>/dev/null | sort -V | tail -n 1 || true)"
fi
if [[ ! -d "$NDK_DIR" ]]; then
  echo "ERROR: Android NDK not found. Set ANDROID_NDK_HOME." >&2
  exit 1
fi

export ROOT_DIR NDK_DIR
python3 - <<'PY'
import hashlib, os, platform, shutil, subprocess, sys, tempfile, urllib.request, zipfile
from pathlib import Path

ROOT = Path(os.environ["ROOT_DIR"])
NDK = Path(os.environ["NDK_DIR"])
host_tag = {"darwin": "darwin-x86_64", "linux": "linux-x86_64"}.get(sys.platform, "darwin-x86_64")
CLANG = NDK / "toolchains/llvm/prebuilt" / host_tag / "bin/clang"
STRIP = NDK / "toolchains/llvm/prebuilt" / host_tag / "bin/llvm-strip"
assert CLANG.is_file(), f"missing clang at {CLANG}"

CACHE = ROOT / "runtime/.staging/dl"
CACHE.mkdir(parents=True, exist_ok=True)
COMMIT = "a49a4075228f4801dadc1eee584aed33fe8ea4ce"
WANT_SHA = "74487243bde86c303e786e79cd4a13e98c3279cae4ab7725dcf5fa51c0b530c1"
ZIP_PATH = CACHE / f"tawc-{COMMIT}.zip"
if not ZIP_PATH.exists():
    print(f"[tawcroot] downloading wmww/tawc@{COMMIT[:12]}...")
    urllib.request.urlretrieve(f"https://github.com/wmww/tawc/archive/{COMMIT}.zip", ZIP_PATH)
got_sha = hashlib.sha256(ZIP_PATH.read_bytes()).hexdigest()
assert got_sha == WANT_SHA, f"SHA-256 mismatch: {got_sha} != {WANT_SHA}"

SOURCES = [
    "src/main.c","src/io.c","src/strings.c","src/filter.c","src/filter_build.c",
    "src/handler.c","src/dispatch.c","src/rescue.c","src/path.c","src/path_scratch.c",
    "src/path_fold.c","src/path_orchestrate.c","src/path_resolve.c","src/proc_rewrite.c",
    "src/proc_shadow.c","src/identity.c","src/syscalls_fs.c","src/syscalls_fs_legacy.c",
    "src/syscalls_link.c","src/syscalls_stat.c","src/syscalls_xattr.c","src/syscalls_fd.c",
    "src/linkstore.c","src/dirent_filter.c","src/syscalls_control.c","src/chroot.c",
    "src/shm.c","src/signal_shadow.c","src/sigalt.c","src/syscalls_socket.c",
    "src/rtnl_emu.c","src/usercopy.c","src/loader_elf.c","src/loader_map.c",
    "src/loader_stack.c","src/loader_io_prod.c","src/loader_exec.c","src/proctitle.c",
    "src/exec_state.c","src/exec_handler.c","src/syscalls_exec.c","src/supervisor.c",
    "src/arch/aarch64_stub.S","src/arch/aarch64_loader_jump.S",
]

with tempfile.TemporaryDirectory() as tmp:
    tmp_path = Path(tmp)
    prefix = f"tawc-{COMMIT}/"
    with zipfile.ZipFile(ZIP_PATH) as zf:
        for m in zf.infolist():
            if not m.filename.startswith(prefix) or m.is_dir():
                continue
            rel = m.filename[len(prefix):]
            if rel != "LICENSE.MIT" and not rel.startswith(("tawcroot/src/", "tawcroot/include/")):
                continue
            dst = tmp_path / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(m) as src, dst.open("wb") as out:
                shutil.copyfileobj(src, out)

    tawc_dir = tmp_path / "tawcroot"
    path_c = tawc_dir / "src/path.c"
    text = path_c.read_text()
    needle = "\tif (tawcroot_rootfs_fd < 0)    return TAWC_EBADF;\n"
    assert text.count(needle) == 1
    patch = needle + (
        "\tfor (size_t i = 0; i < tawcroot_n_binds; i++) {\n"
        "\t\tconst struct tawcroot_bind *b = &tawcroot_binds[i];\n"
        "\t\tif (b->active && tawc_starts_with(suffix, b->dst) &&\n"
        "\t\t    (suffix[b->dst_len] == 0 || suffix[b->dst_len] == '/'))\n"
        "\t\t\treturn TAWC_ENOENT;\n"
        "\t}\n"
    )
    path_c.write_text(text.replace(needle, patch, 1))

    obj_dir = tmp_path / "obj"
    obj_dir.mkdir()
    cflags = [
        "--target=aarch64-linux-android29",
        "-O2", "-fno-strict-aliasing", "-fno-stack-protector",
        "-fvisibility=hidden", "-fno-exceptions",
        "-fno-asynchronous-unwind-tables", "-ffreestanding",
        "-mno-outline-atomics",
        "-Wall", "-Wextra", "-Werror", "-Wframe-larger-than=1024",
        f"-I{tawc_dir / 'include'}",
    ]
    objs = []
    for s in SOURCES:
        o = obj_dir / (s.replace("/", "_") + ".o")
        subprocess.run([str(CLANG)] + cflags + ["-c", str(tawc_dir / s), "-o", str(o)], check=True)
        objs.append(str(o))

    out_so = ROOT / "app/android/app/src/main/jniLibs/arm64-v8a/libtawcroot.so"
    out_so.parent.mkdir(parents=True, exist_ok=True)
    lflags = [
        "--target=aarch64-linux-android29", "-fuse-ld=lld",
        "-static", "-nostdlib", "-nostartfiles", "-Wl,--build-id=none",
        "-Wl,-z,noexecstack", "-Wl,-z,relro", "-Wl,-z,max-page-size=16384",
        "-Wl,--image-base=0x2000000000", "-Wl,-soname,libtawcroot.so",
    ]
    subprocess.run([str(CLANG)] + lflags + objs + ["-o", str(out_so)], check=True)
    subprocess.run([str(STRIP), "--strip-all", str(out_so)], check=True)
    os.chmod(out_so, 0o755)
    shutil.copy2(tmp_path / "LICENSE.MIT", ROOT / "runtime/THIRD_PARTY_TAWCROOT_LICENSE.MIT")
    print(f"[tawcroot] built {out_so} ({out_so.stat().st_size} bytes)")
PY

#!/usr/bin/env python3
"""Build pinned Android libmpv and MPVUI JNI on macOS/Linux, never publish remotely."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_inputs import LOCK_PATH, fingerprint, inputs_for, load
from Android import swift_core

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / ".build/android"
LOCK = ROOT / LOCK_PATH
ABI = {"arm64-v8a": ("arm64", "aarch64-linux-android"), "x86_64": ("x86_64", "x86_64-linux-android")}


def run(*args, cwd=ROOT, env=None):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def native_fingerprint(lock):
    """Identify native dependencies independently of the Swift compiler and core."""
    return fingerprint({key: value for key, value in lock.items() if key != "swift"})


def require_native_inputs(scripts, abi, lock):
    """Prevent package-only builds from relabeling stale native dependencies."""
    stamp = scripts / "prefix" / ABI[abi][0] / ".mpvui-inputs.sha256"
    if not stamp.is_file() or stamp.read_text().strip() != native_fingerprint(lock):
        raise RuntimeError(f"Rebuild {abi} without --package-only: native dependency inputs changed")


def checkout(path, url, commit):
    if not (path / ".git").exists():
        path.mkdir(parents=True, exist_ok=True)
        run("git", "init", path)
        run("git", "remote", "add", "origin", url, cwd=path)
    current = subprocess.run(["git", "rev-parse", "HEAD"], cwd=path, capture_output=True, text=True)
    if current.stdout.strip() != commit:
        run("git", "fetch", "--depth", "1", "origin", commit, cwd=path)
        if current.returncode == 0:
            # These private generated sources may still have the previous pin's patches.
            run("git", "restore", "--source=HEAD", "--worktree", ".", cwd=path)
        run("git", "checkout", "--detach", commit, cwd=path)
    if (path / ".gitmodules").exists():
        run("git", "submodule", "update", "--init", "--recursive", "--depth", "1", cwd=path)


def download(item):
    cache = WORK / "downloads" / item["url"].rsplit("/", 1)[1]
    cache.parent.mkdir(parents=True, exist_ok=True)
    if not cache.exists() or digest(cache) != item["sha256"]:
        temporary = cache.with_suffix(cache.suffix + ".tmp")
        run("curl", "-fLsS", "--retry", "3", item["url"], "-o", temporary)
        if digest(temporary) != item["sha256"]:
            raise RuntimeError(f"Checksum mismatch: {item['url']}")
        temporary.replace(cache)
    return cache


def prepare(lock, sdk, ndk):
    upstream = WORK / "upstream"
    checkout(upstream, "https://github.com/mpv-android/mpv-android.git", lock["recipe"])
    scripts = upstream / "buildscripts"
    for name, source in {**lock["git"], **{s["id"]: s for s in lock["sources"]}}.items():
        checkout(scripts / "deps" / name, source["url"], source["commit"])
    archives = list(lock["archives"].items())
    with ThreadPoolExecutor(max_workers=4) as pool:
        downloads = list(pool.map(download, [value for _, value in archives]))
    for (name, _), archive in zip(archives, downloads):
        target = scripts / "deps" / name
        if target.exists():
            continue
        target.mkdir(parents=True)
        with tarfile.open(archive) as source:
            # Downloaded archives are checksum pinned, strip their enclosing directory.
            for member in source.getmembers():
                parts = Path(member.name).parts[1:]
                if not parts:
                    continue
                member.name = str(Path(*parts))
                source.extract(member, target, filter="data")
    patched_sources = lock["sources"] + [{"id": name, **source} for name, source in lock["git"].items() if "patches" in source]
    for locked_source in patched_sources:
        source = scripts / "deps" / locked_source["id"]
        patches = locked_source["patches"]
        patch_fingerprint = json.dumps({"commit": locked_source["commit"], "patches": patches}, sort_keys=True)
        stamp = source / ".mpvui-patches.json"
        for patch in patches:
            if digest(ROOT / patch["path"]) != patch["sha256"]:
                raise RuntimeError(f"Update Build/Inputs.lock.json after editing {patch['path']}")
        if not stamp.exists() or stamp.read_text() != patch_fingerprint:
            # This checkout is private generated build output; never the user's working tree.
            run("git", "restore", "--source=HEAD", "--worktree", ".", cwd=source)
            for patch in patches:
                run("git", "apply", ROOT / patch["path"], cwd=source)
            stamp.write_text(patch_fingerprint)
    sdk_links = scripts / "sdk"
    sdk_links.mkdir(exist_ok=True)
    for name, target in [("android-ndk-r30", ndk), ("android-sdk-mac" if platform.system() == "Darwin" else "android-sdk-linux", sdk)]:
        link = sdk_links / name
        if not link.exists():
            link.symlink_to(target)
        if link.resolve() != target.resolve():
            raise RuntimeError(f"{link} points to a different SDK/NDK")
    # Preserve errors from nested dependency builds in the upstream recipe.
    script = scripts / "buildall.sh"
    original = subprocess.check_output(["git", "show", f"{lock['recipe']}:buildscripts/buildall.sh"], cwd=upstream).decode()
    script.write_text(
        original.replace("$BUILDSCRIPT build", "$BUILDSCRIPT build || return $?")
        .replace("build $dep\n", "build $dep || return $?\n")
        .replace("build $target\n", "build $target || exit $?\n")
        .replace("local apilvl=23", f"local apilvl={lock['minimumAPI']}")
    )
    recipe = scripts / "scripts/mpv.sh"
    original = subprocess.check_output(["git", "show", f"{lock['recipe']}:buildscripts/scripts/mpv.sh"], cwd=upstream).decode()
    # libcurl was added after the shared Apple/Android mpv revision.
    recipe.write_text(original.replace("-D{lua,libcurl}=enabled", "-Dlua=enabled"))
    recipe = scripts / "scripts/ffmpeg.sh"
    original = subprocess.check_output(["git", "show", f"{lock['recipe']}:buildscripts/scripts/ffmpeg.sh"], cwd=upstream).decode()
    recipe.write_text(
        original.replace(
            "--disable-static --enable-shared", "--enable-libdovi --pkg-config-flags=--static --disable-static --enable-shared"
        ).replace('--extra-ldflags="-L$prefix_dir/lib"', '--extra-ldflags="-L$prefix_dir/lib -Wl,-z,defs"')
    )
    return scripts


def build_dovi(scripts, ndk, abi, lock, environment, jobs):
    """Install a pinned, PIC static libdovi into the ABI's dependency prefix."""
    rust = lock["toolchain"]["rust"]
    installed = subprocess.check_output(["rustup", "toolchain", "list"], text=True)
    if not any(line.startswith(rust + "-") for line in installed.splitlines()):
        run("rustup", "toolchain", "install", rust, "--profile", "minimal")
    arch, triple = ABI[abi]
    run("rustup", "target", "add", "--toolchain", rust, triple)
    tools = WORK / "tools"
    cargo_c = tools / "bin/cargo-cinstall"
    version = subprocess.check_output([cargo_c, "cinstall", "--version"], text=True) if cargo_c.exists() else ""
    if lock["toolchain"]["cargoC"] not in version:
        run(
            "cargo", f"+{rust}", "install", "cargo-c", "--version", lock["toolchain"]["cargoC"], "--locked", "--root", tools, "--jobs", jobs
        )
    toolchain = next((ndk / "toolchains/llvm/prebuilt").iterdir()) / "bin"
    env = dict(environment, RUSTUP_TOOLCHAIN=rust, RUSTFLAGS="-C relocation-model=pic", CARGO_BUILD_JOBS=str(jobs))
    env[f"CARGO_TARGET_{triple.upper().replace('-', '_')}_LINKER"] = str(toolchain / f"{triple}{lock['minimumAPI']}-clang")
    env[f"CC_{triple.replace('-', '_')}"] = str(toolchain / f"{triple}{lock['minimumAPI']}-clang")
    env[f"AR_{triple.replace('-', '_')}"] = str(toolchain / "llvm-ar")
    # The dependency prefix is a pkg-config sysroot, not part of target paths.
    run(
        cargo_c,
        "cinstall",
        "--locked",
        "--release",
        "--library-type",
        "staticlib",
        "--target",
        triple,
        "--prefix",
        "/",
        "--destdir",
        scripts / "prefix" / arch,
        "--manifest-path",
        scripts / "deps/libdovi/dolby_vision/Cargo.toml",
        env=env,
    )
    # Keep transitive Rust source/license material with the native release.
    manifest = scripts / "deps/libdovi/dolby_vision/Cargo.toml"
    vendor_stamp = WORK / "rust-vendor.sha256"
    fingerprint = digest(manifest.with_name("Cargo.lock"))
    if not vendor_stamp.exists() or vendor_stamp.read_text().strip() != fingerprint:
        run("cargo", f"+{rust}", "vendor", "--locked", "--versioned-dirs", "--manifest-path", manifest, WORK / "rust-vendor")
        vendor_stamp.write_text(fingerprint + "\n")


def package(scripts, ndk, abi, lock, environment):
    arch, triple = ABI[abi]
    prefix = scripts / "prefix" / arch
    stamp = prefix / ".mpvui-inputs.sha256"
    if not stamp.exists() or stamp.read_text().strip() != fingerprint({key: value for key, value in lock.items() if key != "swift"}):
        raise RuntimeError(f"Native inputs changed for {abi}; rebuild without --package-only")
    toolchain = next((ndk / "toolchains/llvm/prebuilt").iterdir())
    destination = WORK / "native/jniLibs" / abi
    destination.mkdir(parents=True, exist_ok=True)
    # Recreate the package from the ELF dependency closure, excluding stale runtimes.
    for stale in destination.glob("*.so"):
        stale.unlink()
    swift_core.build(abi, product="MPVCoreAndroid")
    core_library = WORK / "swift" / abi / f"out/Products/Release-android-{swift_core.ARCHITECTURES[abi]}" / "libMPVCoreAndroid.so"
    swift_core.stage_dependencies(abi, [core_library], destination)
    run(
        toolchain / "bin" / f"{triple}{lock['minimumAPI']}-clang++",
        "-std=c++17",
        "-fPIC",
        "-shared",
        "-O2",
        "-g",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wl,-z,max-page-size=16384",
        "-Wl,-z,defs",
        "-Wl,-soname,libmpvui.so",
        f"-I{prefix}/include",
        f"-I{ROOT}/Sources/CMPV/include",
        ROOT / "Android/mpvui/src/main/cpp/mpvui.cpp",
        f"-L{destination}",
        f"-L{prefix}/lib",
        "-lMPVCoreAndroid",
        "-lmpv",
        "-lavcodec",
        "-llog",
        "-landroid",
        "-o",
        destination / "libmpvui.so",
        env=environment,
    )
    swift_core.stage_dependencies(abi, [destination / "libmpvui.so"], destination)
    for library in destination.glob("*.so"):
        run(toolchain / "bin/llvm-strip", "--strip-unneeded", library)
        headers = subprocess.check_output([str(toolchain / "bin/llvm-readelf"), "-lW", str(library)], text=True)
        for line in headers.splitlines():
            if line.strip().startswith("LOAD") and int(line.split()[-1], 16) < 16384:
                raise RuntimeError(f"{library} is not 16 KB page compatible")
    assets = WORK / "native/assets/mpvui"
    assets.mkdir(parents=True, exist_ok=True)
    shutil.copy2(LOCK, assets / "Inputs.lock.json")
    notices = assets / "licenses/android-ndk"
    notices.mkdir(parents=True, exist_ok=True)
    for notice in (ndk / "NOTICE", ndk / "NOTICE.toolchain", toolchain / "NOTICE"):
        if notice.exists():
            shutil.copy2(notice, notices / ("LLVM-NOTICE" if notice.parent == toolchain else notice.name))
    swift_core.stage_licenses(assets / "licenses")
    swift_license = assets / "licenses/swift"
    swift_license.mkdir(parents=True, exist_ok=True)
    shutil.copy2(swift_core.sdk_root() / "swift-resources/usr/share/swift/LICENSE.txt", swift_license)
    recipe_license = assets / "licenses/mpv-android"
    recipe_license.mkdir(parents=True, exist_ok=True)
    shutil.copy2(scripts.parent / "LICENSE", recipe_license / "LICENSE")
    manifest = {
        "abi": abi,
        "ndk": lock["toolchain"]["ndk"],
        "inputs": fingerprint(lock),
        "jniSource": digest(ROOT / "Android/mpvui/src/main/cpp/mpvui.cpp"),
        "swift": swift_core.provenance(abi),
        "libraries": {p.name: digest(p) for p in sorted(destination.glob("*.so"))},
    }
    (assets / f"build-{abi}.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for source in (scripts / "deps").iterdir():
        for license in source.glob("*"):
            if license.is_file() and license.name.upper().startswith(("COPYING", "LICENSE", "COPYRIGHT")):
                folder = assets / "licenses" / source.name
                folder.mkdir(parents=True, exist_ok=True)
                shutil.copy2(license, folder)
    for crate in (WORK / "rust-vendor").iterdir():
        for license in crate.iterdir():
            if license.is_file() and license.name.upper().startswith(("LICENSE", "COPYING", "COPYRIGHT", "NOTICE")):
                folder = assets / "licenses/rust-crates" / crate.name
                folder.mkdir(parents=True, exist_ok=True)
                shutil.copy2(license, folder)
    sysroot = Path(subprocess.check_output(["rustc", "+" + lock["toolchain"]["rust"], "--print", "sysroot"], text=True).strip())
    rust_licenses = sysroot / "share/doc/rust"
    if (rust_licenses / "licenses").exists():
        shutil.copytree(rust_licenses / "licenses", assets / "licenses/rust/licenses", dirs_exist_ok=True)
    for notice in rust_licenses.glob("*COPYRIGHT*"):
        folder = assets / "licenses/rust"
        folder.mkdir(parents=True, exist_ok=True)
        shutil.copy2(notice, folder)
    for notice in rust_licenses.glob("*LICENSE*"):
        folder = assets / "licenses/rust"
        folder.mkdir(parents=True, exist_ok=True)
        shutil.copy2(notice, folder)
    print(f"Packaged {abi}: {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--abi", choices=ABI, action="append", help="Repeat to build both supported ABIs; default arm64-v8a")
    parser.add_argument("--sdk", type=Path, default=os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk")))
    parser.add_argument("--ndk", type=Path, default=os.environ.get("ANDROID_NDK_HOME"))
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 4, 8))
    parser.add_argument("--clean", action="store_true", help="Clean native compilation directories before building")
    parser.add_argument("--package-only", action="store_true", help="Recompile JNI and package existing native outputs")
    args = parser.parse_args()
    lock = inputs_for(load(ROOT), "android")
    ndk = args.ndk or args.sdk / "ndk" / lock["toolchain"]["ndk"]
    if not (ndk / "source.properties").exists() or lock["toolchain"]["ndk"] not in (ndk / "source.properties").read_text():
        parser.error(f"Install NDK {lock['toolchain']['ndk']} under {args.sdk}, or set --ndk")
    environment = dict(os.environ, cores=str(args.jobs))
    venv = WORK / "venv"
    if not (venv / "bin/meson").exists():
        run("python3", "-m", "venv", venv)
        run(venv / "bin/pip", "install", "meson==1.12.0", "ninja==1.13.0")
    environment["PATH"] = str(venv / "bin") + os.pathsep + environment["PATH"]
    scripts = prepare(lock, args.sdk, ndk)
    for abi in args.abi or ["arm64-v8a"]:
        if not args.package_only:
            build_dovi(scripts, ndk, abi, lock, environment, args.jobs)
            stamp = scripts / "prefix" / ABI[abi][0] / ".mpvui-inputs.sha256"
            expected = native_fingerprint(lock)
            # Cached configure results and Meson compiler paths depend on the minimum API.
            options = ["--clean"] if args.clean or not stamp.exists() or stamp.read_text().strip() != expected else []
            run(shutil.which("bash"), "buildall.sh", *options, "--arch", ABI[abi][0], "mpv", cwd=scripts, env=environment)
            stamp.write_text(expected + "\n")
        require_native_inputs(scripts, abi, lock)
        package(scripts, ndk, abi, lock, environment)


if __name__ == "__main__":
    main()

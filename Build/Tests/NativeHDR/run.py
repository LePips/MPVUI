#!/usr/bin/env python3
"""Compile and exercise the production headers from the locked native patch."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import io
import tarfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_test_media import prepare

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--libplacebo-include", type=Path)
parser.add_argument("--ffmpeg-prefix", type=Path)
args = parser.parse_args()
lock = json.loads((root / "Build/Inputs.lock.json").read_text())
source = next(s for s in lock["sources"] if s["id"] == "mpv")
for locked_source in lock["sources"]:
    for patch in locked_source["patches"]:
        assert hashlib.sha256((root / patch["path"]).read_bytes()).hexdigest() == patch["sha256"], "Native patch checksum drift"

developer = Path(os.environ["DEVELOPER_DIR"]) if "DEVELOPER_DIR" in os.environ else None
if developer is None:
    for app in Path("/Applications").glob("Xcode*.app"):
        version = plistlib.loads((app / "Contents/version.plist").read_bytes())
        if version.get("ProductBuildVersion") == lock["toolchain"]["xcode"]["build"]:
            developer = app / "Contents/Developer"
            break
if developer is None:
    raise SystemExit("Install the Xcode version pinned in Build/Inputs.lock.json or set DEVELOPER_DIR")
clang = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
sdk = developer / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
include = args.libplacebo_include
if include is None:
    include = next((root / ".build/mpvbuild/products/dependencies/libplacebo/macos-arm64").glob("*/include"), None)
if include is None:
    raise SystemExit("Run Build/mpvbuild build --profile dev first, or pass --libplacebo-include")
ffmpeg = args.ffmpeg_prefix
if ffmpeg is None:
    candidates = list((root / ".build/mpvbuild/products/ffmpeg/macos-arm64").glob("*/lib/libavutil.a"))
    ffmpeg = max(candidates, key=lambda p: p.stat().st_mtime).parents[1] if candidates else None
if ffmpeg is None:
    raise SystemExit("Build the native macOS slice first, or pass --ffmpeg-prefix")

media = root / ".build/native-hdr-media"
prepare(media, groups=("native-dovi",))

with tempfile.TemporaryDirectory(prefix="mpv-native-hdr-tests-") as tmp:
    work = Path(tmp)
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(work.parent))
    # Apply the actual added headers, not copies of production implementations.
    for patch in source["patches"]:
        subprocess.run(["git", "apply", "--allow-empty", "--include=video/out/avfoundation_color.h",
                        "--include=video/out/avfoundation_color_math.h",
                        "--include=video/out/avfoundation_hdr10plus.h", str(root / patch["path"])],
                       cwd=work, env=env, check=True)
    # Compile the actual locked FFmpeg parser and patched serializer under the
    # sanitizers, not an uninstrumented cached serializer or a test reimplementation.
    ffsource = next(s for s in lock["sources"] if s["id"] == "ffmpeg")
    cache = root / ".build/mpvbuild/git" / (hashlib.sha256(ffsource["url"].encode()).hexdigest() + ".git")
    archive = subprocess.check_output(["git", "--git-dir", str(cache), "archive", ffsource["commit"]])
    ffwork = work / "ffmpeg"
    ffwork.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(ffwork, filter="data")
    for patch in ffsource["patches"]:
        subprocess.run(["git", "apply", str(root / patch["path"])], cwd=ffwork, env=env, check=True)
    vt_source = (ffwork / "libavcodec/videotoolbox.c").read_text()
    dovi_functions = []
    for function in ["videotoolbox_dovi_is_apple_hevc", "videotoolbox_dovi_p7_allowed",
                     "videotoolbox_dovi_rpu_matches"]:
        start = vt_source.index("static int " + function + "(")
        end = vt_source.index("\n}", start) + 2
        dovi_functions.append(vt_source[start:end])
    # The parser's allocation helper lives in utils.c alongside codec registry
    # code. Extract this unchanged function to avoid linking every decoder into
    # the standalone metadata test.
    utils_source = (ffwork / "libavcodec/utils.c").read_text()
    start = utils_source.index("void av_fast_padded_malloc(")
    end = utils_source.index("\n}", start) + 2
    dovi_functions.append(utils_source[start:end])
    (work / "video/out/native_dovi_functions.h").write_text("\n\n".join(dovi_functions))
    configured = subprocess.run([str(ffwork / "configure"), "--disable-everything",
                                 "--disable-autodetect", "--disable-programs", "--disable-doc",
                                 "--disable-asm", f"--cc={clang}", f"--sysroot={sdk}",
                                 f"--host-cc={clang}", f"--host-cflags=-isysroot {sdk}",
                                 f"--host-ldflags=-isysroot {sdk}"],
                                cwd=ffwork, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if configured.returncode:
        raise SystemExit(configured.stdout)
    ffobject = work / "hdr_dynamic_metadata.o"
    subprocess.run([str(clang), "-isysroot", str(sdk), "-I", str(ffwork),
                    "-I", str(ffmpeg / "include"), "-fsanitize=address,undefined", "-g",
                    "-c", str(ffwork / "libavutil/hdr_dynamic_metadata.c"), "-o", str(ffobject)], check=True)
    dovi_objects = []
    for name in ["dovi_rpu", "dovi_rpudec", "golomb"]:
        output = work / (name + ".o")
        subprocess.run([str(clang), "-isysroot", str(sdk), "-I", str(ffwork),
                        "-I", str(ffmpeg / "include"), "-fsanitize=address,undefined", "-g",
                        "-DHAVE_AV_CONFIG_H", "-Wno-switch",
                        "-c", str(ffwork / "libavcodec" / (name + ".c")), "-o", str(output)], check=True)
        dovi_objects.append(str(output))
    for name, ext in [("color", "c"), ("metadata", "m"), ("hdr10plus", "m"), ("dovi", "c")]:
        output = work / name
        command = [str(clang), "-isysroot", str(sdk), "-I", str(work / "video/out"),
                   "-I", str(include), "-I", str(ffwork), "-I", str(ffmpeg / "include"),
                   "-Wall", "-Wextra", "-Werror",
                   "-Wno-deprecated-declarations", "-fsanitize=address,undefined",
                   str(Path(__file__).parent / f"{name}.{ext}"), "-o", str(output)]
        if name == "hdr10plus":
            command += [str(ffobject), str(ffmpeg / "lib/libavutil.a")]
        if name == "dovi":
            command += dovi_objects + ["-Wl,-dead_strip", str(ffmpeg / "lib/libavutil.a")]
        if ext == "m":
            for framework in ["Foundation", "CoreVideo", "CoreMedia", "CoreGraphics", "CoreImage"]:
                command += ["-framework", framework]
        subprocess.run(command, check=True)
        arguments = [str(output)]
        if name == "dovi":
            arguments.append(str(media / "profile5.rpu"))
        subprocess.run(arguments, check=True)

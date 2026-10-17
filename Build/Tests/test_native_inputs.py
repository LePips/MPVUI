"""Keep source selection, patch isolation and native update provenance consistent."""

import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_inputs import LOCK_PATH, fingerprint, inputs_for, load, sources_for
import update_dependencies
from Android.release import configured_version, verify_native
from Android.swift_core import source_fingerprint
from Android.build import native_fingerprint, require_native_inputs

ROOT = Path(__file__).resolve().parents[2]


class NativeInputTests(unittest.TestCase):
    def setUp(self):
        self.lock = load(ROOT)

    def test_shared_source_changes_reach_both_builders(self):
        for source in self.lock["sources"]:
            source["commit"] = "a" * 40
        for platform in ("apple", "android"):
            self.assertEqual([source["commit"] for source in sources_for(self.lock, platform)], ["a" * 40] * 2)

    def test_platform_changes_only_invalidate_their_own_build(self):
        for platform, change in (
            ("android", lambda lock: lock["android"]["toolchain"].update(ndk="new-ndk")),
            ("android", lambda lock: lock["android"].update(minimumAPI=lock["android"]["minimumAPI"] + 1)),
            ("apple", lambda lock: lock["apple"]["dependencies"][0].update(sha256="a" * 64)),
            ("android", lambda lock: lock["android"]["git"]["libplacebo"]["patches"][0].update(sha256="c" * 64)),
            (
                "android",
                lambda lock: next(p for s in lock["sources"] for p in s["patches"] if p["platforms"] == ["android"]).update(
                    sha256="b" * 64
                ),
            ),
        ):
            with self.subTest(platform=platform):
                changed = copy.deepcopy(self.lock)
                change(changed)
                for target in ("apple", "android"):
                    self.assertEqual(
                        fingerprint(inputs_for(changed, target)) == fingerprint(inputs_for(self.lock, target)), target != platform
                    )

    def test_registered_patches_match_bytes_and_platform_selection(self):
        for source in self.lock["sources"] + list(self.lock["android"]["git"].values()):
            for patch_record in source.get("patches", []):
                self.assertEqual(patch_record["sha256"], hashlib.sha256((ROOT / patch_record["path"]).read_bytes()).hexdigest())
        android = sources_for(self.lock, "android")
        self.assertEqual(
            [Path(p["path"]).name for p in android[0]["patches"]],
            [
                "0003-text-subtitle-interception.patch",
                "0012-text-subtitle-queries.patch",
                "0013-subtitle-roles.patch",
                "0014-webp-animation-duration.patch",
                "0006-mpv-dovi-yuv.patch",
                "0008-mpv-gles-bitmap-subtitles.patch",
                "0020-unavailable-pixel-aspect-ratio.patch",
            ],
        )
        self.assertTrue(all(p["path"].startswith("Build/Android/Patches/") for p in android[1]["patches"]))
        self.assertTrue(
            all(not p["path"].startswith("Build/Android/") for source in sources_for(self.lock, "apple") for p in source["patches"])
        )

    def test_invalid_shared_overrides_and_patch_scopes_are_rejected(self):
        mutations = [
            lambda lock: lock["android"]["git"].update(mpv={"commit": "a" * 40}),
            lambda lock: lock["sources"].append(copy.deepcopy(lock["sources"][0])),
            lambda lock: lock["sources"][0]["patches"][0].update(platforms=[]),
            lambda lock: lock["sources"][0]["patches"][0].update(platforms=["windows"]),
        ]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Build").mkdir()
            for mutate in mutations:
                invalid = copy.deepcopy(self.lock)
                mutate(invalid)
                (root / LOCK_PATH).write_text(json.dumps(invalid))
                with self.assertRaises(ValueError):
                    load(root)

    def test_source_update_writes_one_lock_and_checks_both_patch_sets(self):
        class Upstream:
            def source_release(self, source):
                return "n99.0.0", "a" * 40

        with patch.object(update_dependencies, "verify_patches") as verify:
            outputs, changes = update_dependencies.prepare_update(ROOT, "ffmpeg", Upstream())
        self.assertEqual(list(outputs), [LOCK_PATH])
        updated = json.loads(outputs[LOCK_PATH])
        self.assertEqual(updated["android"], self.lock["android"])
        for platform in ("apple", "android"):
            source = next(s for s in sources_for(updated, platform) if s["id"] == "ffmpeg")
            self.assertEqual(source["commit"], "a" * 40)
        self.assertEqual(set(verify.call_args.args[2]), {"apple", "android"})
        self.assertEqual(len(changes), 1)
        self.assertEqual(load(ROOT), self.lock)

    def test_failed_patch_validation_does_not_write_an_update(self):
        class Upstream:
            def source_release(self, source):
                return "v99.0.0", "a" * 40

        with patch.object(update_dependencies, "verify_patches", side_effect=ValueError("patch failed")):
            with self.assertRaisesRegex(ValueError, "patch failed"):
                update_dependencies.prepare_update(ROOT, "mpv", Upstream())
        self.assertEqual(load(ROOT), self.lock)

    def test_sdk_update_preserves_shared_and_android_inputs(self):
        dependencies = update_dependencies.sdk_groups(self.lock)["sdk-mpvkit-openssl-build"]
        assets = []
        for dependency in dependencies:
            for asset in [dependency] + dependency["runtime"]:
                repository, _, name = update_dependencies.release_url(asset["url"])
                assets.append({"name": name, "browser_download_url": f"https://github.com/{repository}/releases/download/99.0.0/{name}"})

        class Upstream:
            def releases(self, repository):
                return [{"tag_name": "99.0.0", "draft": False, "prerelease": False, "assets": assets}]

            def asset_digest(self, asset):
                return "a" * 64

        outputs, changes = update_dependencies.prepare_update(ROOT, "sdk-mpvkit-openssl-build", Upstream())
        self.assertEqual(list(outputs), [LOCK_PATH])
        updated = json.loads(outputs[LOCK_PATH])
        self.assertEqual(inputs_for(updated, "android"), inputs_for(self.lock, "android"))
        self.assertEqual(updated["sources"], self.lock["sources"])
        self.assertEqual(changes[0].version, "99.0.0")

    def test_android_release_rejects_changed_inputs_and_binary_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Build").mkdir()
            (root / LOCK_PATH).write_text(json.dumps(self.lock))
            (root / "Package.swift").write_text("// fixture manifest")
            jni = root / "Android/mpvui/src/main/cpp/mpvui.cpp"
            jni.parent.mkdir(parents=True)
            jni.write_bytes(b"native source")
            native = root / ".build/android/native"
            (native / "assets/mpvui").mkdir(parents=True)
            for abi in ("arm64-v8a", "x86_64"):
                binary = native / "jniLibs" / abi / "libmpv.so"
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"native library")
                manifest = {
                    "inputs": fingerprint(inputs_for(self.lock, "android")),
                    "jniSource": hashlib.sha256(jni.read_bytes()).hexdigest(),
                    "swift": {"sources": source_fingerprint(root)},
                    "libraries": {binary.name: hashlib.sha256(binary.read_bytes()).hexdigest()},
                }
                (native / "assets/mpvui" / f"build-{abi}.json").write_text(json.dumps(manifest))
            verify_native(root)
            self.lock["apple"]["metadataVersion"] = "new-metadata"
            (root / LOCK_PATH).write_text(json.dumps(self.lock))
            verify_native(root)
            changed = copy.deepcopy(self.lock)
            changed["sources"][0]["commit"] = "a" * 40
            (root / LOCK_PATH).write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError, "native sources changed"):
                verify_native(root)
            (root / LOCK_PATH).write_text(json.dumps(self.lock))
            binary.write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                verify_native(root)

    def test_android_publication_uses_the_gradle_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Android").mkdir()
            properties = root / "Android/gradle.properties"
            properties.write_text("# mpvuiVersion=old\nmpvuiVersion = 1.2.3-rc.1\n")
            self.assertEqual(configured_version(root), "1.2.3-rc.1")
            properties.write_text("# mpvuiVersion=old\n")
            with self.assertRaisesRegex(ValueError, "Set mpvuiVersion"):
                configured_version(root)

    def test_package_only_rejects_stale_native_dependencies(self):
        lock = inputs_for(self.lock, "android")
        with tempfile.TemporaryDirectory() as temporary:
            scripts = Path(temporary)
            for abi, arch in (("arm64-v8a", "arm64"), ("x86_64", "x86_64")):
                with self.subTest(abi=abi):
                    with self.assertRaisesRegex(RuntimeError, "without --package-only"):
                        require_native_inputs(scripts, abi, lock)
                    stamp = scripts / "prefix" / arch / ".mpvui-inputs.sha256"
                    stamp.parent.mkdir(parents=True)
                    stamp.write_text(native_fingerprint(lock) + "\n")
                    require_native_inputs(scripts, abi, lock)
                    changed = copy.deepcopy(lock)
                    changed["swift"]["version"] = "updated-compiler"
                    require_native_inputs(scripts, abi, changed)
                    changed["sources"][0]["commit"] = "a" * 40
                    with self.assertRaisesRegex(RuntimeError, "native dependency inputs changed"):
                        require_native_inputs(scripts, abi, changed)


if __name__ == "__main__":
    unittest.main()

import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import update_dependencies as updater


def asset(name, tag="2.0.0", payload=b"archive"):
    return {
        "name": name,
        "browser_download_url": f"https://github.com/mpvkit/example-build/releases/download/{tag}/{name}",
        "size": len(payload),
        "digest": "sha256:" + hashlib.sha256(payload).hexdigest(),
    }


def release(tag="2.0.0", **overrides):
    return dict({"tag_name": tag, "draft": False, "prerelease": False,
                 "assets": [asset("example-all.zip", tag), asset("Example.xcframework.zip", tag)]}, **overrides)


def dependency(name="example"):
    return {"id": name, "version": "1.0.0", "kind": "prebuilt-sdk", "sha256": "a" * 64,
            "url": asset("example-all.zip", "1.0.0")["browser_download_url"],
            "runtime": [{"target": "Example", "sha256": "b" * 64,
                         "url": asset("Example.xcframework.zip", "1.0.0")["browser_download_url"]}]}


class SDKUpdateTests(unittest.TestCase):
    def upstream(self, releases):
        return Mock(releases=Mock(return_value=releases), asset_digest=Mock(return_value="c" * 64))

    def test_selects_highest_stable_version_not_publication_order(self):
        upstream = self.upstream([release("1.5.0"), release("3.0.0", prerelease=True),
                                  release("4.0.0", draft=True), release("2.0.0"), release("5.0.0-rc1")])
        dependencies = [dependency()]
        updater.update_sdk(dependencies, upstream)
        self.assertEqual(dependencies[0]["version"], "2.0.0")
        for item in [dependencies[0], *dependencies[0]["runtime"]]:
            self.assertIn("/2.0.0/", item["url"])
            self.assertEqual(item["sha256"], "c" * 64)
        self.assertEqual(upstream.asset_digest.call_count, 2)

    def test_updates_all_libraries_shipped_in_one_release(self):
        dependencies = [dependency("first"), dependency("second")]
        updater.update_sdk(dependencies, self.upstream([release()]))
        self.assertEqual([item["version"] for item in dependencies], ["2.0.0", "2.0.0"])
        self.assertEqual(len(updater.sdk_groups({"dependencies": dependencies})), 1)

    def test_missing_runtime_asset_leaves_whole_bundle_unchanged(self):
        dependencies = [dependency()]
        before = copy.deepcopy(dependencies)
        upstream = self.upstream([release(assets=[asset("example-all.zip")])])
        with self.assertRaisesRegex(ValueError, "Missing or unexpected asset"):
            updater.update_sdk(dependencies, upstream)
        self.assertEqual(dependencies, before)
        upstream.asset_digest.assert_not_called()

    def test_download_failure_does_not_partially_update_bundle(self):
        dependencies = [dependency()]
        before = copy.deepcopy(dependencies)
        upstream = self.upstream([release()])
        upstream.asset_digest.side_effect = ["c" * 64, ValueError("bad checksum")]
        with self.assertRaisesRegex(ValueError, "bad checksum"):
            updater.update_sdk(dependencies, upstream)
        self.assertEqual(dependencies, before)

    def test_mixed_bundle_versions_and_runtime_origins_rejected(self):
        cases = [dependency(), dependency()]
        cases[0]["version"] = "0.9.0"
        cases[1]["runtime"][0]["url"] = asset("Example.xcframework.zip", "0.9.0")["browser_download_url"]
        for item in cases:
            with self.subTest(item=item), self.assertRaises(ValueError):
                updater.update_sdk([item], self.upstream([release()]))

    def test_equal_or_older_release_never_downloads_or_downgrades(self):
        for tag in ("1.0.0", "0.9.0"):
            upstream = self.upstream([release(tag)])
            dependencies = [dependency()]
            self.assertEqual(updater.update_sdk(dependencies, upstream), [])
            self.assertEqual(dependencies, [dependency()])
            upstream.asset_digest.assert_not_called()

    def test_assets_download_without_auth_and_match_digest_and_size(self):
        upstream = updater.Upstream()
        with patch.dict(updater.os.environ, {"GH_TOKEN": "test-token"}), \
                patch.object(updater, "urlopen", return_value=io.BytesIO(b"archive")) as download:
            self.assertEqual(upstream.asset_digest(asset("example-all.zip")), hashlib.sha256(b"archive").hexdigest())
        self.assertEqual(download.call_args.args, (asset("example-all.zip")["browser_download_url"],))
        for bad_asset in (dict(asset("example-all.zip"), size=99),
                          dict(asset("example-all.zip"), digest="sha256:" + "0" * 64)):
            with patch.object(updater, "urlopen", return_value=io.BytesIO(b"archive")), self.assertRaises(ValueError):
                upstream.asset_digest(bad_asset)

    def test_release_api_paginates(self):
        page = [release()] * 100
        with patch.object(updater, "urlopen", side_effect=[io.BytesIO(json.dumps(page).encode()), io.BytesIO(b"[]")]) as api:
            self.assertEqual(len(updater.Upstream().releases("mpvkit/example-build")), 100)
        self.assertIn("page=2", api.call_args.args[0].full_url)

    def test_version_order_and_packaging_suffixes(self):
        for tag in ("n9.1-dev", "v0.42.0-rc1", "nightly", "3.3.2-xcode26"):
            self.assertIsNone(updater.version(tag))
        self.assertGreater(updater.version("9.10"), updater.version("9.9.1"))
        self.assertGreater(updater.version("2.1.0-fix"), updater.version("2.1.0"))
        self.assertGreater(updater.version("4.15.13-2512"), updater.version("4.15.13-2412"))


class SourceUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.upstream = self.root / "upstream"
        self.upstream.mkdir()
        self.git("init", "--quiet")
        (self.upstream / "file.txt").write_text("original\n")
        self.commit()
        self.old_commit = self.git("rev-parse", "HEAD")
        self.git("tag", "n9.0.1")
        (self.upstream / "release.txt").write_text("new release\n")
        self.commit()
        self.new_commit = self.git("rev-parse", "HEAD")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.com", "tag", "-a", "n9.0.2", "-m", "release")
        self.git("tag", "n10.0-dev")
        (self.root / "Build/Android").mkdir(parents=True)
        first = self.make_patch("first", "apple\n")
        second = self.make_patch("second", "apple second\n")
        self.git("reset", "--hard", "HEAD")
        android_patch = self.make_patch("android", "android\n")
        self.git("reset", "--hard", "HEAD")
        self.source = {"id": "ffmpeg", "url": str(self.upstream), "ref": "n9.0.1", "version": "9.0.1",
                       "commit": self.old_commit, "patches": [first, second]}
        self.android = {"git": {"ffmpeg": {"url": str(self.upstream), "commit": self.old_commit}},
                        "ffmpegPatches": [android_patch]}
        self.apple = {"sources": [self.source], "dependencies": []}
        for path, value in ((updater.APPLE_LOCK, self.apple), (updater.ANDROID_LOCK, self.android)):
            (self.root / path).write_text(json.dumps(value, indent=2) + "\n")

    def git(self, *args):
        return updater.run("git", *args, cwd=self.upstream)

    def commit(self):
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--quiet", "-m", "fixture")

    def make_patch(self, name, text):
        # Diff the second patch against the first patch's result.
        self.git("add", ".")
        (self.upstream / "file.txt").write_text(text)
        content = self.git("diff") + "\n"
        path = self.root / f"Build/{name}.patch"
        path.write_text(content)
        return {"path": str(path.relative_to(self.root)), "sha256": hashlib.sha256(content.encode()).hexdigest()}

    def test_annotated_release_is_peeled_and_development_tag_ignored(self):
        self.assertEqual(updater.Upstream().source_release(self.source), ("n9.0.2", self.new_commit))

    def test_update_verifies_both_patch_chains_and_keeps_platform_pins_together(self):
        outputs, changes = updater.prepare_update(self.root, "ffmpeg", updater.Upstream())
        apple = json.loads(outputs[updater.APPLE_LOCK])
        android = json.loads(outputs[updater.ANDROID_LOCK])
        self.assertEqual(apple["sources"][0]["commit"], self.new_commit)
        self.assertEqual(apple["sources"][0]["version"], "9.0.2")
        self.assertEqual(android["git"]["ffmpeg"]["commit"], self.new_commit)
        self.assertIn("both ordered patch sets applied", "\n".join(changes))
        self.assertEqual(json.loads((self.root / updater.APPLE_LOCK).read_text()), self.apple)

    def test_patch_conflict_leaves_both_lockfiles_unchanged(self):
        self.android["ffmpegPatches"] = [self.source["patches"][1]]
        (self.root / updater.ANDROID_LOCK).write_text(json.dumps(self.android))
        before = {path: (self.root / path).read_bytes() for path in (updater.APPLE_LOCK, updater.ANDROID_LOCK)}
        with self.assertRaisesRegex(ValueError, "Android patch failed"):
            updater.prepare_update(self.root, "ffmpeg", updater.Upstream())
        for path, content in before.items():
            self.assertEqual((self.root / path).read_bytes(), content)

    def test_patch_checksum_drift_rejected(self):
        (self.root / self.source["patches"][0]["path"]).write_text("changed")
        with self.assertRaisesRegex(ValueError, "checksum drift"):
            updater.prepare_update(self.root, "ffmpeg", updater.Upstream())

    def test_apple_only_checkout_does_not_require_android(self):
        (self.root / updater.ANDROID_LOCK).unlink()
        outputs, changes = updater.prepare_update(self.root, "ffmpeg", updater.Upstream())
        self.assertEqual(set(outputs), {updater.APPLE_LOCK})
        self.assertIn("ordered Apple patch set applied", "\n".join(changes))

    def test_divergent_android_pin_rejected(self):
        self.android["git"]["ffmpeg"]["commit"] = "0" * 40
        with self.assertRaisesRegex(ValueError, "pins differ"):
            updater.update_source(self.root, self.source, self.android, updater.Upstream())

    def test_moved_tag_requires_manual_review(self):
        upstream = Mock(source_release=Mock(return_value=("n9.0.1", self.new_commit)))
        with self.assertRaisesRegex(ValueError, "tag moved"):
            updater.update_source(self.root, self.source, self.android, upstream)

    def test_no_downgrade(self):
        upstream = Mock(source_release=Mock(return_value=("n8.0", self.new_commit)))
        self.assertEqual(updater.update_source(self.root, self.source, self.android, upstream), [])
        self.assertEqual(self.source["commit"], self.old_commit)

    def test_cli_dry_run_and_repeated_update_are_idempotent(self):
        before = (self.root / updater.APPLE_LOCK).read_bytes()
        with patch.object(updater, "ROOT", self.root), contextlib.redirect_stdout(io.StringIO()):
            with patch.object(sys, "argv", ["update", "--component", "ffmpeg", "--dry-run"]):
                updater.main()
            self.assertEqual((self.root / updater.APPLE_LOCK).read_bytes(), before)
            with patch.object(sys, "argv", ["update", "--component", "ffmpeg"]):
                updater.main()
            after = {path: (self.root / path).read_bytes() for path in (updater.APPLE_LOCK, updater.ANDROID_LOCK)}
            with patch.object(sys, "argv", ["update", "--component", "ffmpeg"]):
                updater.main()
            for path, content in after.items():
                self.assertEqual((self.root / path).read_bytes(), content)


if __name__ == "__main__":
    unittest.main()

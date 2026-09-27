import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import generate_device_test_project as project


class DeviceTestProjectTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repository = Path(self.directory.name).resolve()
        (self.repository / "Package.swift").write_text("manifest remains untouched")
        (self.repository / "Tests").mkdir()
        self.output = self.repository / ".build/device-tests"

    def test_project_references_live_checkout_and_owns_generated_bundle_resources(self):
        with patch.object(project.shutil, "which", return_value="/bin/xcodegen"), patch.object(
            project.subprocess, "run"
        ) as run:
            result = project.generate(self.repository, self.output, "ABC123DE45")
        self.assertEqual((self.repository / "Package.swift").read_text(), "manifest remains untouched")
        self.assertEqual(result.parent, self.output)
        spec = json.loads((self.output / "project.json").read_text())
        self.assertEqual(spec["packages"]["MPVUI"]["path"], str(self.repository))
        target = spec["targets"]["MPVUITests"]
        self.assertEqual(target["type"], "bundle.unit-test")
        self.assertEqual(target["sources"][0]["path"], str(self.repository / "Tests"))
        self.assertEqual(target["sources"][2], {"path": str(self.output / "GeneratedMedia"), "buildPhase": "resources"})
        self.assertEqual(target["settings"]["base"]["DEVELOPMENT_TEAM"], "ABC123DE45")
        self.assertFalse(spec["schemes"][project.SCHEME]["test"]["parallelizable"])
        self.assertEqual(run.call_args_list[0].args[0][-1], str(self.output / "GeneratedMedia"))
        self.assertEqual(run.call_count, 2)

    def test_device_test_bundle_has_an_application_host_and_matching_signing(self):
        with patch.object(project.shutil, "which", return_value="/bin/xcodegen"), patch.object(
            project.subprocess, "run"
        ):
            project.generate(self.repository, self.output, "ABC123DE45")
        spec = json.loads((self.output / "project.json").read_text())
        host = spec["targets"][project.HOST_TARGET]
        tests = spec["targets"]["MPVUITests"]
        self.assertEqual(host["type"], "application")
        self.assertIn({"target": project.HOST_TARGET}, tests["dependencies"])
        self.assertTrue((self.output / "TestHost.swift").is_file())
        self.assertIn("WindowGroup", (self.output / "TestHost.swift").read_text())
        self.assertEqual(host["settings"]["base"]["INFOPLIST_KEY_UIApplicationSceneManifest_Generation"], "YES")
        self.assertEqual(tests["settings"]["base"]["BUNDLE_LOADER"], "$(TEST_HOST)")
        self.assertEqual(
            tests["settings"]["base"]["TEST_HOST"],
            f"$(BUILT_PRODUCTS_DIR)/{project.HOST_TARGET}.app/{project.HOST_TARGET}",
        )
        for target in [host, tests]:
            self.assertEqual(target["settings"]["base"]["DEVELOPMENT_TEAM"], "ABC123DE45")
            self.assertEqual(target["settings"]["base"]["CODE_SIGN_STYLE"], "Automatic")
        self.assertEqual(spec["schemes"][project.SCHEME]["build"]["targets"][project.HOST_TARGET], ["test"])

    def test_host_permissions_allow_local_networking_without_global_http_exception(self):
        spec = project.project_spec(self.repository, self.output, None)
        info = spec["targets"][project.HOST_TARGET]["info"]
        self.assertEqual(info["path"], str(self.output / "TestHost-Info.plist"))
        self.assertTrue(info["properties"]["NSLocalNetworkUsageDescription"])
        self.assertEqual(info["properties"]["NSAppTransportSecurity"], {"NSAllowsLocalNetworking": True})
        self.assertNotIn("info", spec["targets"]["MPVUITests"])

    def test_foreground_host_retains_and_restores_prior_idle_timer_state(self):
        # The generated host prevents lock only while active. SDK typechecking
        # validates the SwiftUI scene lifecycle hook separately.
        source = project.HOST_SOURCE
        self.assertIn("onChange(of: scenePhase, initial: true)", source)
        self.assertIn("if phase == .active", source)
        self.assertIn("priorIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled", source)
        self.assertIn("UIApplication.shared.isIdleTimerDisabled = previous", source)
        self.assertIn("priorIdleTimerDisabled = nil", source)

    def test_rejects_checkout_or_symlink_escape_before_writing(self):
        for output in [self.repository, self.repository / ".build", self.repository / "Tests"]:
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, "subdirectory"):
                project.generate(self.repository, output)
        (self.repository / ".build").mkdir()
        (self.repository / ".build/escape").symlink_to(self.repository / "Tests", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "subdirectory"):
            project.generate(self.repository, self.repository / ".build/escape")
        self.assertEqual(list((self.repository / "Tests").iterdir()), [])

    def test_missing_generator_and_unsigned_mode_are_explicit(self):
        with patch.object(project.shutil, "which", return_value=None), self.assertRaisesRegex(
            RuntimeError, "brew install xcodegen"
        ):
            project.generate(self.repository, self.output)
        self.assertFalse(self.output.exists())
        settings = project.project_spec(self.repository, self.output, None)["targets"]["MPVUITests"]["settings"]["base"]
        self.assertEqual(settings["CODE_SIGNING_ALLOWED[sdk=iphoneos*]"], "NO")
        self.assertNotIn("DEVELOPMENT_TEAM", settings)


if __name__ == "__main__":
    unittest.main()

.DEFAULT_GOAL := help
SHELL := /bin/sh
MAKEFLAGS += --no-print-directory
# Validation shares build directories and benchmark hardware. Native compilation
# manages its own worker count; make must not overlap validation phases with -j.
.NOTPARALLEL:

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
PYTHON ?= python3
PROFILE ?= dev
JSON ?= 0
ARGS ?=
BUILD_ARGS ?=
TEST_ARGS ?=
BENCHMARK_ARGS ?=
# Frontend options and jobserver flags must not alter upstream dependency makefiles.
unexport MAKEFLAGS MFLAGS MAKEOVERRIDES MAKELEVEL ARGS BUILD_ARGS TEST_ARGS BENCHMARK_ARGS PROFILE TARGET PYTHON JSON

# Quote executable/root paths, including checkouts with spaces or apostrophes.
quote = '$(subst ','"'"',$(1))'
python = $(call quote,$(PYTHON))

BUILD_TARGETS := build-core-android build-android build-android-package build-android-example release-android-candidate build build-swift dev release-candidate artifacts repro native-coverage
TEST_TARGETS := test-apple-consumer test-android-consumer test-core-android test-core test-android test-android-device test-android-example test-android-example-release test-android-profile7 test-android-dovi-gpu check test test-unit test-integration test-system coverage test-swift test-build test-python test-benchmark-tools test-native test-artifact test-device test-simulator
BENCHMARK_TARGETS := benchmark benchmark-compare benchmark-device device-regression benchmark-ab profile-capture profile-analyze profile-system-trace sync-prepare sync-probe
TOOL_TARGETS := doctor status clean use-local use-remote generate native-update update-dependencies release-publish release-adopt package-publish media rendering-media device-project format format-check
COMMAND_TARGETS := $(BUILD_TARGETS) $(TEST_TARGETS) $(BENCHMARK_TARGETS) $(TOOL_TARGETS)
DISCOVERY_TARGETS := devices

COMMAND_test-android-consumer = $(python) Build/Android/consumer.py
COMMAND_test-apple-consumer = $(python) Build/Tests/apple_consumer.py
COMMAND_test-core-android = $(python) Build/Android/swift_core.py --test
COMMAND_build-core-android = $(python) Build/Android/swift_core.py
COMMAND_test-core = caffeinate -disu $(python) Build/Tests/run_swift_tests.py --filter MPVCoreTests

COMMAND_build-android = $(python) Build/Android/build.py
COMMAND_build-android-package = Android/gradlew -p Android :mpvui:assembleRelease
COMMAND_build-android-example = Example/Android/gradlew -p Example/Android :app:assembleDebug
COMMAND_release-android-candidate = $(python) Build/Android/release.py
COMMAND_test-android = Android/gradlew -p Android :mpvui:testDebugUnitTest :mpvui:lintRelease
COMMAND_test-android-device = Android/gradlew -p Android :mpvui:connectedDebugAndroidTest
COMMAND_test-android-example = Example/Android/gradlew -p Example/Android :app:connectedDebugAndroidTest
COMMAND_test-android-example-release = Example/Android/gradlew -p Example/Android :app:connectedReleaseAndroidTest -PmpvuiTestBuildType=release
COMMAND_test-android-profile7 = $(python) Build/Android/test_profile7.py
COMMAND_test-android-dovi-gpu = $(python) Build/Android/test_dovi_gpu.py

COMMAND_build = $(python) Build/mpvbuild build --profile $(call quote,$(PROFILE))
COMMAND_build-swift = swift build --package-path .
COMMAND_dev = $(python) Build/mpvbuild build --profile dev
COMMAND_release-candidate = $(python) Build/mpvbuild release candidate --profile release
COMMAND_artifacts = $(COMMAND_release-candidate)
COMMAND_repro = $(python) Build/mpvbuild repro --profile $(call quote,$(PROFILE))
COMMAND_native-coverage = $(python) Build/mpvbuild coverage
COMMAND_doctor = $(python) Build/mpvbuild doctor --bootstrap
COMMAND_status = $(python) Build/mpvbuild status
COMMAND_clean = $(python) Build/mpvbuild clean
COMMAND_use-local = $(python) Build/mpvbuild use local
COMMAND_use-remote = $(python) Build/mpvbuild use remote
COMMAND_generate = $(python) Build/mpvbuild generate
COMMAND_native-update = $(python) Build/mpvbuild update
COMMAND_update-dependencies = $(python) Build/update_dependencies.py
COMMAND_release-publish = $(python) Build/mpvbuild release publish
COMMAND_release-adopt = $(python) Build/mpvbuild release adopt
COMMAND_package-publish = $(python) Build/mpvbuild release publish-package
COMMAND_check = $(python) Build/mpvbuild check

COMMAND_test = $(python) Build/Tests/coverage.py
COMMAND_test-unit = $(COMMAND_test) --lane unit
COMMAND_test-integration = $(COMMAND_test) --lane integration
COMMAND_test-system = $(COMMAND_test) --lane system
COMMAND_coverage = $(COMMAND_test) --check
COMMAND_test-swift = caffeinate -disu $(python) Build/Tests/run_swift_tests.py
COMMAND_test-build = swift test --package-path Build --no-parallel
COMMAND_test-python = $(python) -m unittest discover -s Build/Tests -p 'test_*.py'
COMMAND_test-benchmark-tools = $(python) -m unittest discover -s Build/Benchmarks -p 'test_*.py'
COMMAND_test-native = $(python) Build/Tests/NativeHDR/run.py
COMMAND_test-artifact = $(python) Build/mpvbuild test
COMMAND_test-device = caffeinate -disu $(python) Build/Tests/run_xcode_tests.py --platform device
COMMAND_test-simulator = $(python) Build/Tests/run_xcode_tests.py --platform simulator

COMMAND_benchmark = $(python) Build/benchmark run
COMMAND_benchmark-compare = $(python) Build/benchmark compare
COMMAND_benchmark-device = $(python) Build/benchmark device
COMMAND_device-regression = $(python) Build/benchmark device-regression
COMMAND_benchmark-ab = $(python) Build/Benchmarks/run_device_ab.py
COMMAND_profile-capture = $(python) Build/Benchmarks/capture_device_profile.py
COMMAND_profile-analyze = $(python) Build/Benchmarks/analyze_device_profile.py
COMMAND_profile-system-trace = $(python) Build/Benchmarks/analyze_device_system_trace.py
COMMAND_sync-prepare = $(python) Build/Benchmarks/prepare_sync_probe.py
COMMAND_sync-probe = $(python) Build/Benchmarks/run_device_sync_probe.py
COMMAND_media = $(python) Build/Tests/prepare_test_media.py
COMMAND_rendering-media = $(python) Build/Tests/RenderingValidation/generate.py
COMMAND_device-project = $(python) Build/Tests/generate_device_test_project.py
COMMAND_devices = xcrun devicectl list devices
COMMAND_format = pre-commit run --all-files
COMMAND_format-check = pre-commit run --all-files --hook-stage manual

.PHONY: help verify test-tools test-android-native $(COMMAND_TARGETS) $(DISCOVERY_TARGETS)

# Stream tool output by default. JSON=1 emits one JSON result per step instead.
# Both modes retain logs and results; make's own errors stay on stderr.
$(BUILD_TARGETS): KIND = build
$(BUILD_TARGETS): PHASE_ARGS = $(BUILD_ARGS)
$(TEST_TARGETS): KIND = test
$(TEST_TARGETS): PHASE_ARGS = $(TEST_ARGS)
$(BENCHMARK_TARGETS): KIND = benchmark
$(BENCHMARK_TARGETS): PHASE_ARGS = $(BENCHMARK_ARGS)
$(TOOL_TARGETS): KIND = command
$(COMMAND_TARGETS):
	@cd $(call quote,$(ROOT)) && $(python) Build/validation.py --kind $(KIND) $(if $(filter 1,$(JSON)),--json) -- $(COMMAND_$@) $(PHASE_ARGS) $(ARGS)

# Discovery output is the requested data, not validation chatter.
$(DISCOVERY_TARGETS):
	@cd $(call quote,$(ROOT)) && $(COMMAND_$@) $(ARGS)

# Make owns the phase transitions and stops immediately if a prerequisite fails.
verify: build test
test-tools: test-build test-python test-benchmark-tools
test-android-native: test-android-profile7 test-android-dovi-gpu

help:
ifdef TARGET
ifeq ($(TARGET),verify)
	@printf '%s\n' 'make verify [PROFILE=dev|release] [BUILD_ARGS="..."] [TEST_ARGS="..."]' \
	  'Build native libraries, then run package tests using the current Package.swift artifact selection. Stops on failure.'
else ifeq ($(TARGET),test-tools)
	@printf '%s\n' 'make test-tools' 'Run test-build, test-python, and test-benchmark-tools in order. Stops on failure.'
else ifeq ($(TARGET),test-android-native)
	@printf '%s\n' 'make test-android-native [ARGS="--serial ANDROID_SERIAL"]' 'Run production Profile 7 and Dolby Vision GPU checks on Android arm64. Stops on failure.'
else
ifeq ($(filter $(TARGET),$(COMMAND_TARGETS) $(DISCOVERY_TARGETS)),)
	$(error Unknown help target '$(TARGET)'; run make help for target names)
else
	@cd $(call quote,$(ROOT)) && $(COMMAND_$(TARGET)) $(ARGS) --help
endif
endif
else
	@printf '%s\n' \
	  'Usage: make TARGET [ARGS="tool options"] [JSON=1]' \
	  'make -C Build uses the same targets. make help TARGET=NAME shows tool options.' \
	  '' \
	  'Build:       doctor, build (PROFILE=dev|release), build-swift, release-candidate, repro, native-coverage, check' \
	  'Android:     build-core-android, build-android, build-android-package, build-android-example, release-android-candidate, test-android, test-android-device, test-android-example, test-android-example-release' \
	  'Selection:   use-local, use-remote, generate, status, clean' \
	  'Release:     release-publish, release-adopt, package-publish (explicit operations)' \
	  'Tests:       test-core, test-core-android, test, test-unit, test-integration, test-system, coverage, test-swift, test-apple-consumer, test-android-consumer' \
	  'Tool tests:  test-tools, test-build, test-python, test-benchmark-tools, test-native, test-android-native, test-artifact' \
	  'Device:      devices, device-project, test-device, test-simulator' \
	  'Benchmarks:  benchmark, benchmark-compare, benchmark-device, device-regression, benchmark-ab' \
	  'Profiling:   profile-capture, profile-analyze, profile-system-trace, sync-prepare, sync-probe' \
	  'Utilities:   media, rendering-media, native-update, update-dependencies, format, format-check' \
	  'Workflow:    verify (build then test; benchmarks are explicit)' \
	  'Aliases:     dev (development build), artifacts (release candidate)' \
	  '' \
	  'Tool output streams by default. JSON=1 emits one JSON result per step instead.' \
	  'Both modes save full logs and results in .build/validation.' \
	  'For multi-step workflows, use BUILD_ARGS, TEST_ARGS, or BENCHMARK_ARGS for phase-specific options.' \
	  'Quote paths inside ARGS when they contain spaces. PYTHON selects the Python executable.'
endif

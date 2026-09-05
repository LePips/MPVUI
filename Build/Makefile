.DEFAULT_GOAL := help
.PHONY: help doctor check artifacts native dev clean
# Run from the repository root with make -C Build <target>.

help:
	@./mpvbuild --help

doctor:
	@./mpvbuild doctor --bootstrap

check:
	@./mpvbuild check

artifacts:
	@./mpvbuild release candidate --profile release

dev:
	@./mpvbuild build --profile dev

clean:
	@./mpvbuild clean

# Compatibility alias for existing scripts.
native: artifacts

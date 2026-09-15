.DEFAULT_GOAL := help
.PHONY: help doctor check artifacts dev clean test test-unit coverage
# Run from the repository root with make -C Build <target>.

help:
	@./mpvbuild --help

doctor:
	@./mpvbuild doctor --bootstrap

check:
	@./mpvbuild check

test:
	@python3 Tests/coverage.py

test-unit:
	@python3 Tests/coverage.py --lane unit

coverage:
	@python3 Tests/coverage.py --check

artifacts:
	@./mpvbuild release candidate --profile release

dev:
	@./mpvbuild build --profile dev

clean:
	@./mpvbuild clean

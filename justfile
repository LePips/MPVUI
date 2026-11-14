set minimum-version := '1.55.0'
set positional-arguments

# Upstream native builds manage their own Make jobs and options.
unexport MAKEFLAGS
unexport MFLAGS
unexport MAKEOVERRIDES
unexport MAKELEVEL

python := 'python3'

# List commands, platform suites, and workflow steps.
[default]
@help:
    exec {{ quote(python) }} Build/commands.py help --

# Check requirements, install build tools, and prepare test media.
[arg('platform', long, pattern='apple|android')]
[arg('json', long, value='1', help='Print one JSON result per step')]
@setup platform='apple' json='0' *args:
    shift 2; exec {{ quote(python) }} Build/commands.py "$0" PLATFORM={{ quote(platform) }} JSON={{ quote(json) }} -- "$@"

# Build and check native libraries.
[arg('platform', long, pattern='apple|android')]
[arg('profile', long, pattern='dev|release')]
[arg('json', long, value='1', help='Print one JSON result per step')]
@build platform='apple' profile='dev' json='0' *args:
    shift 3; exec {{ quote(python) }} Build/commands.py "$0" PLATFORM={{ quote(platform) }} PROFILE={{ quote(profile) }} JSON={{ quote(json) }} -- "$@"

# Run tests. Use just help to list suites for each platform.
[arg('platform', long, pattern='apple|android')]
[arg('profile', long, pattern='dev|release')]
[arg('suite', long)]
[arg('filter', long, help='Run matching Apple package tests without coverage')]
[arg('device', long, help='Device or simulator identifier, or Android serial')]
[arg('json', long, value='1', help='Print one JSON result per step')]
@test platform='apple' suite='' filter='' device='' profile='dev' json='0' *args:
    shift 6; exec {{ quote(python) }} Build/commands.py "$0" PLATFORM={{ quote(platform) }} SUITE={{ quote(suite) }} FILTER={{ quote(filter) }} DEVICE={{ quote(device) }} PROFILE={{ quote(profile) }} JSON={{ quote(json) }} -- "$@"

# Create, check, or publish release artifacts. Use just help to list steps.
[arg('platform', long, pattern='apple|android')]
[arg('profile', long, pattern='dev|release')]
[arg('step', long)]
[arg('json', long, value='1', help='Print one JSON result per step')]
@release platform='apple' step='' profile='dev' json='0' *args:
    shift 4; exec {{ quote(python) }} Build/commands.py "$0" PLATFORM={{ quote(platform) }} STEP={{ quote(step) }} PROFILE={{ quote(profile) }} JSON={{ quote(json) }} -- "$@"

# Measure performance. Use just help to list steps.
[arg('platform', long, pattern='apple|android')]
[arg('step', long)]
[arg('device', long, help='Device or simulator identifier, or Android serial')]
[arg('json', long, value='1', help='Print one JSON result per step')]
@benchmark platform='apple' step='' device='' json='0' *args:
    shift 4; exec {{ quote(python) }} Build/commands.py "$0" PLATFORM={{ quote(platform) }} STEP={{ quote(step) }} DEVICE={{ quote(device) }} JSON={{ quote(json) }} -- "$@"

# Select the latest native candidate. Pass -- --remote to restore the published artifact.
[arg('json', long, value='1', help='Print one JSON result per step')]
@select json='0' *args:
    shift; exec {{ quote(python) }} Build/commands.py "$0" JSON={{ quote(json) }} -- "$@"

# Update native dependency pins.
[arg('json', long, value='1', help='Print one JSON result per step')]
@update json='0' *args:
    shift; exec {{ quote(python) }} Build/commands.py "$0" JSON={{ quote(json) }} -- "$@"

# Remove build outputs and test results. Pass -- --cache to remove caches too.
[arg('json', long, value='1', help='Print one JSON result per step')]
@clean json='0' *args:
    shift; exec {{ quote(python) }} Build/commands.py "$0" JSON={{ quote(json) }} -- "$@"

# Format sources, or check formatting without changing files.
[arg('check', long, value='1')]
[arg('json', long, value='1', help='Print one JSON result per step')]
@format check='0' json='0' *args:
    shift 2; exec {{ quote(python) }} Build/commands.py "$0" CHECK={{ quote(check) }} JSON={{ quote(json) }} -- "$@"

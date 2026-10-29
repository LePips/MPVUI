.DEFAULT_GOAL := help
SHELL := /bin/sh
MAKEFLAGS += --no-print-directory
# Validation shares build directories and benchmark hardware, so commands run in order.
.NOTPARALLEL:

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
PYTHON ?= python3
COMMANDS := setup build test release benchmark select update clean format help
# Build/commands.py validates every OPTION=value given on the command line.
COMMAND_LINE := $(foreach name,$(.VARIABLES),$(if $(filter command line,$(origin $(name))),$(name)))
OPTIONS := $(filter-out PYTHON ARGS,$(COMMAND_LINE))
# Options and jobserver flags must not reach upstream makefiles that tools run.
unexport MAKEFLAGS MFLAGS MAKEOVERRIDES MAKELEVEL $(COMMAND_LINE)

# Quote paths and values, including checkouts with spaces or apostrophes.
quote = '$(subst ','"'"',$(1))'

.PHONY: $(COMMANDS)
$(COMMANDS):
	@cd $(call quote,$(ROOT)) && $(call quote,$(PYTHON)) Build/commands.py $@ $(foreach name,$(OPTIONS),$(name)=$(call quote,$($(name)))) -- $(ARGS)

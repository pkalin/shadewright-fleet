# Entry points for the checks, the Kind cluster and the scenario harness (ADR-0022). Works with GNU Make 3.81
# (macOS) and later: every recipe is one call of a script in scripts/, which does the work and the checks.
#
#   make tools                                # pinned kustomize, kubeconform, kind, kubectl, shellcheck into bin/
#   make check-vendor                         # (network) the vendored Shadewright install equals a fresh build
#   make lint test render                     # shellcheck, offline harness tests, the render check
#   make kind-up kind-wait                    # a Kind cluster whose Flux tracks cluster/kind, then its baseline
#   make scenario-list
#   make scenario-<name> CLUSTER=kind|lab     # switch a scenario on: one commit on cluster/<CLUSTER>
#   make scenario-reset CLUSTER=kind|lab      # back to main's tree: one commit on cluster/<CLUSTER>
#   make kind-down

SHELL := /bin/bash

# Passed to the scripts through the environment, never spliced into a command line.
export CLUSTER SCENARIO_REF DRY_RUN RECONCILE FLEET_REMOTE
export KIND_CLUSTER_NAME FLEET_URL FLEET_BRANCH FLEET_COMMIT FLEET_REF_NAME EXPECT_COMMIT WAIT_TIMEOUT

SCRIPTS := $(wildcard scripts/*.sh) $(wildcard tests/*.sh)

.PHONY: help tools lint test render check-vendor check-scenarios kind-up kind-wait kind-down scenario-list scenario-reset

help:
	@sed -n '1,/^$$/p' Makefile | sed 's/^# \{0,1\}//'

tools:
	scripts/install-tools.sh

lint:
	PATH="$(CURDIR)/bin:$$PATH" shellcheck -x $(SCRIPTS)

test:
	tests/run.sh

render:
	scripts/render.sh

check-vendor:
	scripts/check-vendor.sh

check-scenarios:
	scripts/scenario.sh check --render

kind-up:
	scripts/kind.sh up

kind-wait:
	scripts/kind.sh wait

kind-down:
	scripts/kind.sh down

scenario-list:
	scripts/scenario.sh list

scenario-reset:
	scripts/scenario.sh reset

# Explicit targets above win over this pattern, so scenario-list and scenario-reset never reach it.
scenario-%:
	scripts/scenario.sh apply '$*'

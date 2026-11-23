# Entry points for the checks, the Kind cluster and the scenario harness (ADR-0022). Works with GNU Make 3.81
# (macOS) and later: every recipe is one call of a script in scripts/, which does the work and the checks, except the
# Go checks of tools/, which call the go tool (the toolchain line of each go.mod).
#
#   make tools                                # pinned kustomize, kubeconform, kind, kubectl, shellcheck into bin/
#   make lint test render                     # shellcheck, offline harness tests, the render check
#   make faultbox-lint faultbox-test          # gofmt and go vet, then the unit tests (race detector) of tools/faultbox
#   make kind-up kind-wait                    # a Kind cluster whose Flux tracks cluster/kind, then its baseline
#   make kind-dry-run-config                  # the pinned chart's CRDs, then a server-side dry run of the lab config
#   make scenario-list
#   make scenario-<name> CLUSTER=kind|lab     # switch a scenario on: one commit on cluster/<CLUSTER>
#   make scenario-reset CLUSTER=kind|lab      # back to main's tree: one commit on cluster/<CLUSTER>
#   make kind-down

SHELL := /bin/bash

# Passed to the scripts through the environment, never spliced into a command line.
export CLUSTER SCENARIO_REF DRY_RUN RECONCILE FLEET_REMOTE
export KIND_CLUSTER_NAME FLEET_URL FLEET_BRANCH FLEET_COMMIT FLEET_REF_NAME EXPECT_COMMIT WAIT_TIMEOUT

SCRIPTS := $(wildcard scripts/*.sh) $(wildcard tests/*.sh)

.PHONY: help tools lint test faultbox-lint faultbox-test render check-scenarios kind-up kind-wait kind-dry-run-config kind-down scenario-list scenario-reset

help:
	@sed -n '1,/^$$/p' Makefile | sed 's/^# \{0,1\}//'

tools:
	scripts/install-tools.sh

lint:
	PATH="$(CURDIR)/bin:$$PATH" shellcheck -x $(SCRIPTS)

test:
	tests/run.sh

faultbox-lint:
	cd tools/faultbox && test -z "$$(gofmt -l .)" || { gofmt -l .; echo "gofmt: the files above need formatting"; exit 1; }
	cd tools/faultbox && go vet ./...

faultbox-test:
	cd tools/faultbox && go test -race -count=1 ./...

render:
	scripts/render.sh

check-scenarios:
	scripts/scenario.sh check --render

kind-up:
	scripts/kind.sh up

kind-wait:
	scripts/kind.sh wait

kind-dry-run-config:
	scripts/kind.sh dry-run-config

kind-down:
	scripts/kind.sh down

scenario-list:
	scripts/scenario.sh list

scenario-reset:
	scripts/scenario.sh reset

# Explicit targets above win over this pattern, so scenario-list and scenario-reset never reach it.
scenario-%:
	scripts/scenario.sh apply '$*'

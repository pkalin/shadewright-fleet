# Scenarios

Reproducible incidents for Shadewright, switched on with one command and reset with another, on Kind and on the
AKS lab ([ADR-0022](https://github.com/pkalin/shadewright/blob/main/docs/adr/0022-scenario-switch-and-clusters.md)).
The files here are deliberately broken, so the render check on `main` (`scripts/render.sh`) leaves them out; the
harness renders each scenario before it commits it.

## Commands

```bash
make kind-up && make kind-wait          # a Kind cluster whose Flux tracks cluster/kind, then its healthy baseline
make scenario-list                      # scenarios on origin/main
make scenario-<name> CLUSTER=kind       # switch one on
make scenario-reset CLUSTER=kind        # back to main's tree
make kind-down
```

`CLUSTER` is `kind` or `lab` and is always explicit. Options, as environment variables or `make` arguments:
`DRY_RUN=1` builds, renders and shows the commit without pushing; `SCENARIO_REF=<ref>` reads the scenario's files
from another commit (a local branch with a scenario that is not merged yet; `apps/` still comes from
`origin/main`) and works only with `list` and `DRY_RUN=1`: a push (apply or reset) with `SCENARIO_REF` set is refused
before anything is pushed, so a cluster branch only ever gets scenarios reviewed on `origin/main`; `RECONCILE=0`
skips asking Flux to fetch at once.

## Before the first run

The harness refuses to run until the cluster tracks its own branch. Neither prerequisite is done by this
repository's scripts:

- **Both clusters:** the maintainer has created `cluster/kind` and `cluster/lab` on the remote from `main`, with their
  rulesets (ADR-0022, decision 5). The harness never creates a branch.
- **Kind:** nothing else. `make kind-up` points the Kind cluster's Flux at `cluster/kind` (`FLEET_BRANCH`).
- **Lab:** the lab's Flux configuration comes from `shadewright-azure` (`lab/flux.tf`), and its branch is
  `var.fleet_branch`, which defaults to `main`. Until `fleet_branch = "cluster/lab"` is set in the lab's git-ignored
  `terraform.tfvars` and applied (plan first, then an explicit yes), the lab's `GitRepository` tracks `main`, and
  `CLUSTER=lab` is refused with `tracks 'main', not cluster/lab`, on purpose: a scenario must never reach `main`.
  The lab is disposable, so the setting stays in `terraform.tfvars` for every new session. Then switch the kube
  context to the lab before `make scenario-<name> CLUSTER=lab`.

## What the harness does

Each cluster's Flux tracks its own branch, `cluster/<cluster>`, never `main`. `make scenario-<name> CLUSTER=<c>`:

1. reads the branch from the `GitRepository` `flux-system/fleet` in the current kube context, and refuses unless it
   is exactly `cluster/<c>` (`<c>` is `kind` or `lab`), with no tag, semver, ref name or commit pinned,
   and the `GitRepository` URL is the same repository as the Git remote (`origin`, or `FLEET_REMOTE`);
2. refuses if `cluster/<c>` does not exist on the remote: the maintainer creates cluster branches and their rulesets;
3. builds a tree from the current `origin/main` with the scenario's files copied over `apps/demo/` (only paths under
   `scenarios/<name>/apps/demo/`; anything else in the folder besides `README.md` and `expected.yaml` is refused, and
   so is a file that is not on `main` unless the scenario's own `kustomization.yaml` lists it, see Layout);
4. renders `apps/` of that tree with the pinned kustomize and kubeconform (`scripts/tools.env`, the versions of
   `scripts/render.sh`), and refuses unless the result matches the scenario's `render` (see below);
5. commits the tree on top of the head of `cluster/<c>` and pushes it as a fast-forward, never a force push; a tree
   equal to the branch head is a no-op;
6. asks Flux to fetch now (the reconcile annotation on the `GitRepository`; Flux also polls every minute).

`make scenario-reset CLUSTER=<c>` does the same with `main`'s tree unchanged, so it is idempotent and `prune: true`
on `apps` removes whatever a scenario added. One scenario is on at a time per cluster: switching another on
replaces it. The branch only moves forward and its history records every switch and reset. Nothing here writes
`main`, and the CI Kind cluster tracks the pull request's ref, so the harness refuses to run there.

## Layout

```text
scenarios/
  schema/scenario_v1alpha1.json   JSON schema of expected.yaml
  <name>/
    README.md                     what breaks, the expected diagnosis, the expected outcome, and why
    expected.yaml                 the same, machine-readable (schema below)
    apps/demo/<file>              the broken version of apps/demo/<file>, at the same path relative to the repo
```

`<name>` is lower case letters, digits and hyphens (not `schema`, `list`, `reset` or `check`) and is the make
target: `make scenario-<name>`. A scenario replaces whole files. A file that does not exist on `main` would be
ignored by kustomize, so the harness refuses it unless the scenario also replaces the `kustomization.yaml` of the same
directory and lists the file there (a list item that is exactly the file name); a scenario adds no directories. Keep the broken object a plain manifest that `apps` applies, so the operator's
source mapping (ADR-0012) can map it. A scenario that expects a pull request must break the very field the action
patches, so a reset changes it back and an open request becomes `Superseded`. Any deliberate break of the
restricted profile is explained in the scenario's README.

## expected.yaml

Checked against `schema/scenario_v1alpha1.json` with kubeconform (`make check-scenarios`, and by the harness before
every switch). `make check-scenarios` checks the scenarios of the `HEAD` commit and renders each on `HEAD`'s own
`apps/`, the tree the harness builds once that commit is on `main`; uncommitted changes are not checked. The harness
reads `name`, `summary` and `render` itself, so write them as plain one-line values (quotes are fine); a block scalar,
anchor, tag or escaped value there is refused rather than guessed. Example:

```yaml
apiVersion: scenarios.shadewright.io/v1alpha1
kind: Scenario
name: oom                       # the folder name
summary: The web container's memory limit is below what it needs, so it is OOMKilled and restarts.
render: passes                  # optional; fails only for a scenario that breaks the render on purpose
incident:
  reason: OOMKilled             # the event or container state reason the incident must carry
  object:                       # the object the incident is about
    apiVersion: apps/v1
    kind: Deployment
    namespace: demo
    name: web
diagnosis:
  evidence:                     # facts the diagnosis must name
    - OOMKilled from the container status
    - the restart count
    - the memory working set from Prometheus
outcome:                        # either a pull request ...
  type: pull-request
  action: SetContainerMemoryLimit
  bounds:
    min: 64Mi
    max: 256Mi
  paths:
    - apps/demo/web-deployment.yaml
```

or a refusal:

```yaml
outcome:
  type: refusal
  reason: Changing an image is not in the catalog; a person is notified.
  phase: NeedsIntervention      # optional: Denied or NeedsIntervention, if a RemediationRequest is created at all
```

| Field | Required | Meaning |
| --- | --- | --- |
| `apiVersion`, `kind` | yes | `scenarios.shadewright.io/v1alpha1`, `Scenario` |
| `name` | yes | the folder name |
| `summary` | yes | one line: what breaks (shown by `make scenario-list`) |
| `render` | no | `passes` (default) or `fails`: whether `apps/` with the scenario passes the render check. The harness refuses a scenario whose render does not match. |
| `incident.reason` | yes | the reason the incident must carry |
| `incident.object` | yes | `kind` and `name`, optional `apiVersion` and `namespace` |
| `diagnosis.evidence` | yes | one or more facts the diagnosis must name |
| `outcome.type` | yes | `pull-request` or `refusal` |
| `outcome.action`, `outcome.bounds.min`, `outcome.bounds.max`, `outcome.paths` | for `pull-request` | the catalog action, the range the proposed value must fall in, and the only files the pull request may change (under `apps/demo/`) |
| `outcome.reason`, `outcome.phase` | `reason` for `refusal` | why nothing may be proposed, and the phase a request ends in, if any |

The file holds one document; no other fields are allowed.

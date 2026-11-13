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
`origin/main`) and works only with `list` and `DRY_RUN=1`: `apply` with `SCENARIO_REF` set is refused without `DRY_RUN=1`, before
anything is pushed (`reset` never reads it), so a cluster branch only ever gets scenarios reviewed on `origin/main`; `RECONCILE=0`
skips asking Flux to fetch at once.

## Before the first run

The harness refuses to run until the cluster tracks its own branch. Neither prerequisite is done by this
repository's scripts:

- **Both clusters:** the maintainer has created `cluster/kind` and `cluster/lab` on the remote from `main`, with their
  rulesets (ADR-0022, decision 5). The harness never creates a branch.
- **Kind:** nothing else. `make kind-up` points the Kind cluster's Flux at `cluster/kind` (`FLEET_BRANCH`).
- **Lab:** the lab's Flux install and its `GitRepository` come from `shadewright-azure` (`scripts/lab.sh`, values from `lab/flux.tf`), and its branch is
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
    README.md                     what breaks, what was observed, the expected diagnosis and outcome, and why
    expected.yaml                 the same, machine-readable, each part marked observed or planned (schema below)
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
  reason: OOMKilled             # an event reason or a termination reason the collector reads, never a waiting reason
  status: observed              # observed: seen in a run, say which in source. planned: expected, not seen yet
  source: The kubelet writes lastState.terminated.reason; the collector's pod watch reads it.
  object:                       # the object the incident is about
    apiVersion: apps/v1
    kind: Deployment
    namespace: demo
    name: web
diagnosis:
  status: planned               # no analysis step exists yet
  evidence:                     # facts the diagnosis must name, each with where it is read from
    - fact: OOMKilled from the container status
      source: the pod's lastState.terminated.reason
    - fact: the memory working set
      source: a Prometheus query (planned)
outcome:                        # either a pull request ...
  type: pull-request
  status: observed
  note: What was seen, with a link (optional).
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
  status: planned
  reason: Changing an image is not in the catalog; a person is notified.
  phase: NeedsIntervention      # optional: Denied or NeedsIntervention, if a RemediationRequest is created at all
```

| Field | Required | Meaning |
| --- | --- | --- |
| `apiVersion`, `kind` | yes | `scenarios.shadewright.io/v1alpha1`, `Scenario` |
| `name` | yes | the folder name |
| `summary` | yes | one line: what breaks (shown by `make scenario-list`) |
| `render` | no | `passes` (default) or `fails`: whether `apps/` with the scenario passes the render check. The harness refuses a scenario whose render does not match. |
| `incident.reason` | yes | the reason the incident must carry: a Warning event reason or a termination reason (`OOMKilled`). Container waiting reasons (`ImagePullBackOff`, `CreateContainerConfigError`) are not read by the collector, so they never qualify |
| `incident.status` | yes | `observed` (seen in a run; `source` says which) or `planned` |
| `incident.source` | yes | the component that emits the event or termination, and the collector path that reads it |
| `incident.object` | yes | `kind` and `name`, optional `apiVersion` and `namespace` |
| `diagnosis.status` | yes | `observed` or `planned` (the diagnosis step is built since operator v0.3.0 and scored by the real-model evaluation, https://shadewright.io/evaluation/; `observed` only when all the scored facts were seen in real-model runs) |
| `diagnosis.evidence` | yes | one or more `{fact, source}`: a fact the diagnosis must name and where it is read from |
| `outcome.type` | yes | `pull-request` or `refusal` |
| `outcome.status`, `outcome.note` | `status` yes | `observed` or `planned`; `note` says what was seen, with a link |
| `outcome.action`, `outcome.bounds.min`, `outcome.bounds.max`, `outcome.paths` | for `pull-request` | the catalog action, the range the proposed value must fall in, and the only files the pull request may change (under `apps/demo/`) |
| `outcome.reason`, `outcome.phase` | `reason` for `refusal` | why nothing may be proposed, and the phase a request ends in, if any |

The file holds one document; no other fields are allowed.

## Observed and planned

A line in a scenario is **observed** only if someone saw it in a run, and the run is named next to it. Anything else
is **planned**: what the code or the design says should happen. As of v0.1.0 (2026-11-04) the analyzer's collector turns
Warning events and abnormal container terminations into Incidents; the diagnosis step, the creation of requests by
the analyzer and the read-only tools were not built then (they are since v0.3.0). The lab runs of 2026-11-06 to
2026-11-08 (v0.3.0-rc.2 to rc.5) are recorded in the scenarios `oom`, `keda-at-ceiling` and `statefulset-oom`, and the Incident reasons of `missing-secret` and `bad-image` were
observed on Kind on 2026-11-04. All other incident reasons are what the kubelet, the scheduler, KEDA and Flux are
expected to emit, checked against what the collector reads, not against a cluster.

The collector reads `events.k8s.io` Warning events and pods whose container terminated with `OOMKilled` or a non-zero
exit code. It does not read container waiting reasons, so `ImagePullBackOff` and `CreateContainerConfigError` are
never an Incident reason; the same failures show as the kubelet's `Failed` events (its image-pull `BackOff` event,
"Back-off pulling image", is type `Normal`, which the collector does not read; the restart `BackOff` of a
crash-looping container is a Warning, as in `oom`).

### Which namespaces are watched

The analyzer watches the namespaces in `--watch-namespaces`, and the lab sets it to `demo` only (the `watchNamespaces` value of the
HelmRelease in `infrastructure/shadewright/`). Every scenario except `invalid-manifest` breaks an object in `demo`. That one
fails in `flux-system` (the Kustomization `apps`), which is not watched, so it produces no Incident until
`flux-system` is added there, with a RoleBinding. That widens what the analyzer reads and is a separate decision.

## Scenario matrix

[MATRIX.md](MATRIX.md) lists the verification rows planned for v0.5.0: each row's setup, expected phase and reason, where it
runs and whether its scenario exists, plus the design of a second cluster.

## Evidence matrix

What each layer proves today. A cell without a link has no evidence yet.

| Layer | What it shows | Scenarios | Evidence |
| --- | --- | --- | --- |
| Schema and render | `expected.yaml` matches the schema, and `apps/` renders as the scenario declares (`make check-scenarios`) | the six before `statefulset-oom` | [Harness](https://github.com/pkalin/shadewright-fleet/actions/runs/41797824198) on `main` at 8fe9e16 |
| Harness | the scenario switch refuses what it must and pushes only fast-forwards to the cluster branch (`tests/`, offline, stubbed cluster) | the six before `statefulset-oom` | the same Harness run |
| Healthy baseline | `infrastructure` and `apps` become Ready on Kind with no scenario | none (baseline) | [Kind](https://github.com/pkalin/shadewright-fleet/actions/runs/41797824469) on `main` at 8fe9e16; on the lab the baseline still produced one-off startup Incidents for `worker` ([#267](https://github.com/pkalin/shadewright/issues/267)) |
| Runtime symptom | the symptom appears on a cluster and the collector creates the Incident | `oom`, `keda-at-ceiling`, `statefulset-oom`, `missing-secret`, `bad-image` | `oom`: the lab runs of 2026-11-04 and 2026-11-06 to 2026-11-08; `keda-at-ceiling` and `statefulset-oom`: the lab run of 2026-11-08 (v0.3.0-rc.5). `oom` on 2026-11-04 (`OOMKilled`, `BackOff` and `Unhealthy` Incidents for `demo/web`). `missing-secret` and `bad-image`: a Kind run of 2026-11-04 with the vendored agent applied by hand (`Failed` Incidents for `demo/web`, see each README) |
| Full acceptance | Incident, request, pull request and policy outcome end to end | `oom` (from the analyzer, merged and fixed), `keda-at-ceiling` (the same), `statefulset-oom` (up to a merged pull request, delivery not checked) | `oom`: [#51](https://github.com/pkalin/shadewright-fleet/pull/51) on 2026-11-08 (v0.3.0-rc.5); `keda-at-ceiling`: [#53](https://github.com/pkalin/shadewright-fleet/pull/53); `statefulset-oom`: [#54](https://github.com/pkalin/shadewright-fleet/pull/54), not merged. History: [#26](https://github.com/pkalin/shadewright-fleet/pull/26), a hand-written request on 2026-11-04 |

The other scenarios stop at schema, render and harness. `statefulset-oom` (the StatefulSet case,
[#269](https://github.com/pkalin/shadewright/issues/269)) ran on the lab up to a merged pull request; its delivery is not checked.

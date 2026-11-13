# Scenario matrix

The scenarios Shadewright v0.5.0 is checked against: for each, the setup, the phase and reason the request is
expected to end with, where it runs, and whether the scenario exists. It is a plan, not a record: nothing here is
**observed** unless a row says so and names the run (see "Observed and planned" in the [README](README.md)).
Tracked in [shadewright#672](https://github.com/pkalin/shadewright/issues/672).

## Names on this page

Phases and reasons are the ones in the operator's API (`api/v1alpha1/remediationrequest_types.go` in
`pkalin/shadewright`): `Merged`, `WaitingForDelivery`, `Verifying`, `Succeeded`, `Failed`, `Expired`, `Cancelled`,
`Superseded`, `NeedsIntervention`. The reasons `ChangeRequestClosed`, `RolloutStuck`, `DeliveryNotObserved`,
`RolloutNotDetermined` and `HelmManaged` exist in the code. The troubleshooting page of the operator says nothing sets
`WaitingForDelivery`, `Verifying`, `Succeeded`, `Failed` or `Cancelled` yet, so every row that ends there is planned
until the design of [shadewright#248](https://github.com/pkalin/shadewright/issues/248) is accepted and built. Any name
the rows need that does not exist yet is written as "to be named by the design of #248". There is no phase
`Inconclusive`, no revert action and no reason for a persistent ceiling today.

Where it runs:

- Kind: the symptom and the Incident only. The Kind cluster has no agent identity, so no pull request is opened
  there (README, "Kind").
- Lab: the AKS lab with the agent, a model and the GitHub App. Every row that needs a pull request runs here.
- Second cluster: see below.

## Verification rows

| # | Row | Setup | Expected phase | Expected reason | Runs on | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Limit too low, raised within policy | `make scenario-oom CLUSTER=lab`; merge the pull request (48Mi to 64Mi, inside the `demo-memory` bounds of 64Mi to 128Mi) | `Succeeded` after `Merged`, `WaitingForDelivery` and `Verifying`, once the checks held for `stableFor` | condition `Verified=True`, reason to be named by the design of #248 | Lab | exists (`oom`); the outcome needs the checks of #248 |
| 2 | Leak: the limit is raised, the kill returns later | `oom-leak`: `web` with a memory-backed volume that a load Deployment fills at a steady rate (see below) | `Failed` | to be named by the design of #248; the revert is a new request, whose action is to be named by the design of #248 | Lab (second cluster as an alternative) | new scenario needed |
| 3 | Merged, but the Kustomization fails to apply | `delivery-blocked`: the `oom` files plus a `ValidatingAdmissionPolicy` and its binding that refuse a `web` memory limit above 60Mi (see below) | `Merged`, then `WaitingForDelivery`, then a timeout: `Failed` or `Expired`, to be named by the design of #248 | condition `RolledOut=False`, reason `DeliveryNotObserved` (set today one hour after the merge) | Lab | new scenario needed |
| 4 | Applied, but the pods keep the old value | `rollout-blocked`: the `oom` files plus a `LimitRange` whose container `max` memory is 56Mi (see below) | not `Succeeded`; the final phase is to be named by the design of #248 | condition `RolledOut=False`, reason `RolloutStuck` (set today 10 minutes after the revision was applied) | Lab | new scenario needed |
| 5 | The incident stops before the pull request merges | `keda-load-burst`: `keda-at-ceiling` with a load that ends by itself after a few minutes; leave the pull request unmerged (see below) | `Cancelled` | to be named by the design of #248 (the reasons of `Cancelled` today are the hand-off ones) | Lab | new scenario needed |
| 6 | Pull request closed unmerged by the reviewer | `make scenario-oom CLUSTER=lab`, then close the pull request on GitHub without merging | `NeedsIntervention`, and no second pull request ([shadewright#643](https://github.com/pkalin/shadewright/issues/643)) | `ChangeRequestClosed` | Lab | exists (`oom`); the "no second pull request" half fails until #643 is fixed |
| 7 | Data missing during the window | no scenario: after the merge, take Prometheus away by hand (see below) | to be named by the design of #248 (not `Succeeded`, not `Failed`) | to be named by the design of #248; for the rollout side `RolloutNotDetermined` exists | Lab | new scenario needed (a documented manual step) |
| 8 | KEDA ceiling raised, still at the ceiling | `keda-ceiling-persists`: `keda-at-ceiling` with a load of about 25 requests per second, so the trigger asks for 5 replicas against a ceiling of 3 | `Failed` | to be named by the design of #248 | Lab | new scenario needed |

Rows 1 and 6 use `oom` unchanged. Row 6 is also the case the `statefulset-oom` and `keda-at-ceiling` scenarios would
give; one is enough. Rows 3 and 4 also need the scenario to render: the harness checks that with
`make check-scenarios`, and the new objects must be plain manifests with one object per file (ADR-0012).

## New scenarios, row by row

The demo app is podinfo 6.17.0 (`apps/demo/web-deployment.yaml`). Its flags and endpoints below were read in the
`6.17.0` tag of `stefanprodan/podinfo`: `cmd/podinfo/main.go` (flags `--stress-cpu`, `--stress-memory`,
`--unready`, `--unhealthy`, `--random-error`, `--random-delay`, `--data-path`), `pkg/api/http/store.go` (`POST /store`
writes the posted body to `--data-path`, default `/data`, one file per distinct body) and `pkg/api/http/panic.go`
(`GET /panic` exits with code 255). The README of the same repository lists `POST /fault_injection/enable`, which makes
the app answer 500 to application requests while probes stay healthy. Nothing below was run; each scenario needs a Kind
run to tune its numbers before it is merged.

### Row 2: a leak

`--stress-memory` allocates once at start (it truncates a file to N MB and reads it into the heap), so it cannot grow:
it gives the `oom` kill, never a leak. podinfo has no flag that grows memory over time. The smallest way to get growth
from podinfo itself is its `/store` endpoint on a memory-backed volume:

- In the scenario's `web-deployment.yaml`, the `data` volume becomes `emptyDir` with `medium: Memory` and a `sizeLimit`
  above the container limit (the `main` file has `sizeLimit: 16Mi`, which would evict the pod instead of killing the
  container). Tmpfs pages are charged to the container's memory cgroup, so they count against the limit.
- A `loadgen`-style Deployment (the `keda-at-ceiling` one is the model: same hardening, one object per file, listed in
  the scenario's `kustomization.yaml`) posts a different body to `/store` every few seconds, each below the request
  body limit of podinfo (`maxRequestBodySize` in `pkg/api/http`). The usage then grows in a straight line.
- Start the limit at 64Mi (the policy minimum). The first kill comes when the volume and the app together reach it; the
  agent raises it by at most 50% (policy `maxIncreasePercent`), the new pod starts with an empty volume, and the kill
  returns after a time set by the growth rate. Pick the rate so that this is longer than the delivery wait and shorter
  than `stableFor`.

Not checked: that the kernel kills the container (rather than evicting the pod) when tmpfs fills the cgroup. If it
does not, the smallest alternative is a second small public image whose only job is to grow, for example `busybox`
running a shell loop that appends to a variable, as its own Deployment under `apps/demo/` (pinned by digest, which the
repo requires). The `demo-memory` policy already covers any `apps/demo/*-deployment.yaml`.

### Row 3: the Kustomization fails to apply after the merge

The pre-merge policy check refuses a Kustomization that is not Ready (`KustomizationNotReady`), and the render check
refuses a change that does not render, so the failure must come from the cluster, not from the file. The smallest way is
an admission rule that the old value passes and the new one does not. A `ValidatingAdmissionPolicy` and a
`ValidatingAdmissionPolicyBinding` (Kubernetes 1.30 and later), as two plain files in `apps/demo/` listed in the
scenario's `kustomization.yaml`, reject a Deployment in `demo` whose container memory limit is above 60Mi. The `oom`
file starts at 48Mi, so the scenario applies. The agent's 64Mi is refused when Flux applies the merge: `apps` turns
`Ready=False` with the admission message, and the request waits for a delivery that never comes. Check on Kind that
the dry-run of the first apply passes and that Flux reports the second as a failure.

The timeout is long (an hour from the merge, as the code stands), so run this row last in a session. Whether the
wait ends `Failed` or `Expired` is for #248.

### Row 4: the pods keep the old value

A patch in the repository cannot make this row. A `kustomization.yaml` in `apps/demo/` may list `resources` only
(ADR-0012), and a Flux Kustomization with `patches` is refused with `KustomizationTransforms`; an overlay that
hides the new value fails the render check with `DesiredValueMissing` before any pull request exists. So a patch is
a separate refusal row, not this one. What the row needs is a change that Flux applies and the pods do not take. Two ways:

- A `LimitRange` in `demo` with a container `max` of 56Mi, one plain file. The Deployment applies, but its new
  ReplicaSet cannot create pods above 56Mi, so the old pod stays with its old limit and the rollout never completes.
  Side effect to accept or avoid: `worker` and `cache` have 64Mi limits, so a pod of theirs that is recreated while the
  scenario is on is refused too. The scenario lasts minutes and does not touch their templates.
- A mutating admission rule (a Kyverno policy, or a `MutatingAdmissionPolicy` on a cluster that has it) that rewrites
  the limit back to the old value. It is closest to "a patch overrides the field" but adds a controller or a newer API.
  Not recommended for the first run.

A paused Deployment (`spec.paused: true`) gives the same end state but cannot be a scenario file: it would also stop the
broken template of `oom` from rolling out, so no symptom would appear first.

### Row 5: the incident stops by itself

Every change to the target file is a plan input, and a change ends the request `Superseded` (ADR-0022, consequences), so
a reset of `oom` cannot make this row: it tests row "Superseded" instead. The symptom has to end with Git untouched.
`keda-load-burst` is `keda-at-ceiling` with `loadgen` running its curl loop for a fixed time (a few minutes), then
`sleep` for good. The ScaledObject file does not change, the HPA leaves its ceiling when the load ends, and the
`ReplicaCeiling` Incident stops being observed while the pull request waits for review. The reviewer waits until the
load has ended before looking. What the request does then is the point of the row, and is not decided yet.

### Row 7: data missing

No file under `apps/demo/` controls Prometheus (it is installed by `infrastructure/prometheus/`), so a scenario cannot
remove the data. The row is a procedure: after the merge, scale `prometheus-server` to zero (with `infrastructure`
suspended in Flux, so it is not put back), wait through the window, then resume. The expectation is that missing or
stale metrics never end in `Succeeded` (#248). Note that `NoNewOOMKills` reads kube-state-metrics, also in the
`prometheus` namespace, so the same step takes both away.

### Row 8: still at the ceiling

`keda-at-ceiling` asks for 3 replicas at about 13 requests per second (threshold 5 per replica). The `demo-keda` policy
allows `maxReplicaCount` 2 to 3 and no more. `keda-ceiling-persists` raises the load to about 25 requests per second
(`sleep 0.03` in `loadgen`; the rate is an estimate, tune it on Kind), so the trigger asks for 5 and the HPA stays at
3 after the fix is applied.

## Planned groups

Not part of v0.5.0 verification. Listed so the page matches the issue.

| Group | Row | Setup | Status |
| --- | --- | --- | --- |
| Change evidence | An OOM after a commit lowered the limit | a scenario whose cluster-branch history holds a commit that lowers `web`'s limit shortly before the symptom | planned |
| Change evidence | A sync that rolled the workload for another reason | a commit that changes something other than the limit (an annotation, an env value) and rolls the pods, while an OOM is already present | planned |
| Fleet registration | none written yet | the issue names the group but gives no rows | planned |

## Second cluster

The first cluster (Kind, or the AKS lab with Flux) cannot run two kinds of row. The second cluster, a lab for a
session and destroyed after it ([ADR-0008](https://github.com/pkalin/shadewright/blob/main/docs/adr/0008-disposable-azure-lab.md)),
adds:

- Argo CD as its delivery controller. The operator has one delivery adapter, Flux (`internal/providers/delivery/flux`);
  Argo CD is on the adapter list of the design (`DeliveryVerifier`, design 2 and 13) but not built, and the source
  mapping reads Flux labels. So the cluster by itself gives no row until the adapter and a mapping for Argo CD exist;
  it is the place to run them. Not designed.
- A public demo application whose failures we did not write. A check that only passes on breakage we authored
  proves little about the diagnosis.

Node size and price per hour and per session: from `make lab-cost` in `shadewright-azure`, once the size is chosen.
The cluster is applied for a session and destroyed after it; `make lab-check` lists what is left.

### Which applications

| Application | Delivered as | Documented failures | Resource needs | Source |
| --- | --- | --- | --- | --- |
| OpenTelemetry demo (`open-telemetry/opentelemetry-demo`) | a Helm chart; the documentation also shows `helm template ... > opentelemetry-demo.yaml` | feature flags in `src/flagd/demo.flagd.json`, among them `emailMemoryLeak` (variants `1x` to `10000x` and `off`), `failedReadinessProbe` (cart service), `cartFailure` (`10%` to `100%`), `adHighCpu` and `cartMetricCardinalityOverflow` | 6 GB of free RAM for the application | the repository above for the flags; `content/en/docs/demo/kubernetes-deployment.md` in `open-telemetry/opentelemetry.io` for the RAM and the `helm template` command |
| Online Boutique (`GoogleCloudPlatform/microservices-demo`) | plain manifests: `kubernetes-manifests/` and `release/kubernetes-manifests.yaml` (12 Deployments), also a `helm-chart/` | none documented as switches | per service in the manifests, for example `cartservice` requests 64Mi and limits 128Mi, and its Redis requests 200Mi and limits 256Mi (`kubernetes-manifests/cartservice.yaml`); I found no documented total in its `README.md` | the manifests above |

Not verified: how the flags are switched in the chart-based install (the flagd ConfigMap lives in the chart
repository, `open-telemetry/opentelemetry-helm-charts`, which was not read); the total memory of Online Boutique.

`emailMemoryLeak` is a real leak in a service we did not write, which makes it the better source for row 2 than the
podinfo construction. A flag is a value in a ConfigMap, so an agent could in principle propose it; whether that is an
allowed action is a different question and not assumed here.

Recommendation, for decision 1 of #672: start with Online Boutique. It is plain YAML, so the source mapping can
reach it with no rendering step, and it needs less memory than the OpenTelemetry demo. The OpenTelemetry demo comes
second, for its flags. The maintainer decides.

### The Helm refusal is a row

An application delivered by a Flux `HelmRelease` is refused by the source mapping with reason `HelmManaged`
(ADR-0012: Helm values are not supported). The only way to a pull request is to render the chart into plain YAML, commit
that, and let a Flux Kustomization apply it. That refusal is a verification row of its own:

| Row | Setup | Expected phase | Expected reason | Runs on | Status |
| --- | --- | --- | --- | --- | --- |
| A Helm-delivered application | install the OpenTelemetry demo chart through a `HelmRelease`, break a memory limit | `NeedsIntervention` (the phase of the other mapping refusals in the operator's lifecycle page; to be confirmed against the code) | `HelmManaged` | Lab; the second cluster adds the public chart | new scenario needed |

It needs no Argo CD: Flux already installs Helm charts on the lab.

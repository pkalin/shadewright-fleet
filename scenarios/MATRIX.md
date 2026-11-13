# Scenario matrix

The scenarios Shadewright v0.5.0 is checked against: for each, the setup, the phase and reason the request is
expected to end with, where it runs, and whether the scenario exists. It is a plan, not a record: nothing here is
**observed** unless a row says so and names the run (see "Observed and planned" in the [README](README.md)).
Tracked in [shadewright#672](https://github.com/pkalin/shadewright/issues/672).

## Names on this page

Phases and reasons that exist today are the ones in the operator's API (`api/v1alpha1/remediationrequest_types.go` in
`pkalin/shadewright`): `Merged`, `WaitingForDelivery`, `Verifying`, `Succeeded`, `Failed`, `Expired`, `Cancelled`,
`Superseded`, `NeedsIntervention`. The reasons `ChangeRequestClosed`, `RolloutStuck`, `DeliveryNotObserved`,
`RolloutNotDetermined` and `HelmManaged` exist in the code. The troubleshooting page of the operator says nothing sets
`WaitingForDelivery`, `Verifying`, `Succeeded`, `Failed` or `Cancelled` yet, so every row that ends there is planned
until the design of [shadewright#248](https://github.com/pkalin/shadewright/issues/248) is built.

The other names on this page (the phase `Inconclusive`, the reasons `OOMKilled`, `DeliveryFailed`, `TargetGone`,
`TargetReplaced`, `ClearingNotChecked`, `RevertApplied` and the rest, and the conditions `Configured` and `Cleared`)
come from [ADR-0030](https://github.com/pkalin/shadewright/blob/main/docs/adr/0030-merge-receipt-and-verification-outcomes.md),
accepted and merged on 2026-11-13. The names do not exist in the operator's code yet: they arrive with the build tasks
[#678](https://github.com/pkalin/shadewright/issues/678) to [#684](https://github.com/pkalin/shadewright/issues/684),
so until those land every row that names one is what the ADR requires, not what the operator does.

Where it runs:

- Kind: the symptom and the Incident only. The Kind cluster has no agent identity, so no pull request is opened
  there (README, "Kind").
- Lab: the AKS lab with the agent, a model and the GitHub App. Every row that needs a pull request runs here.
- Second cluster: see below.

## Verification rows

| # | Row | Setup | Expected phase | Expected reason | Runs on | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Limit too low, raised within policy | `make scenario-oom CLUSTER=lab`; merge the pull request (48Mi to 64Mi, inside the `demo-memory` bounds of 64Mi to 128Mi) | `Succeeded` after `Merged`, `WaitingForDelivery` and `Verifying`, once rolled out, configured and a quiet window of at least 10 minutes plus the node grace held (the memory minimum for `stableFor`) | condition `Verified=True`, `Cleared=True` with reason `NoRecurrence` | Lab | exists (`oom`); the outcome needs ADR-0030 built |
| 2 | Leak: the limit is raised, the kill returns later | `oom-leak`: `web` with a memory-backed volume that a load Deployment fills at a steady rate (see below) | `Failed`, at once when the kill is seen after the rollout | `OOMKilled`; the revert is row 10 | Lab | exists (`oom-leak`); the kill was settled on Kind (see below), the outcome is planned: no agent ran |
| 3 | Merged, but the Kustomization fails to apply | `delivery-blocked`: the `oom` files plus a `ValidatingAdmissionPolicy` and its binding that refuse a `web` memory limit above 60Mi (see below) | `Merged`, then `WaitingForDelivery`, then `Failed` at the end of the delivery window (one hour after the merge) | `DeliveryFailed`, because Flux failed on exactly the merge commit; the condition `RolledOut=False` with `DeliveryNotObserved` is what the code sets today | Lab | exists (`delivery-blocked`); the admission refusal was checked by hand on Kind, not through Flux or the agent |
| 4 | Applied, but the pods keep the old value | `rollout-blocked`: the `oom` files plus a `LimitRange` whose container `max` memory is 56Mi (see below) | `Failed` at the timeout (21 minutes from the applied revision with the defaults), never `Succeeded` | `RolloutStuck`, because `RolledOut` is False (set today 10 minutes after the revision was applied) | Lab | exists (`rollout-blocked`); the LimitRange refusal was checked by hand on Kind, not through Flux or the agent |
| 5 | The incident stops before the pull request merges | `keda-load-burst`: `keda-at-ceiling` with a load that ends by itself after a few minutes; leave the pull request unmerged (see below) | open: ADR-0030 gives no phase for it | open | Lab | new scenario needed; the outcome is not decided |
| 6 | Pull request closed unmerged by the reviewer | `make scenario-oom CLUSTER=lab`, then close the pull request on GitHub without merging | `NeedsIntervention`, today and under ADR-0030 (decided 2026-11-13: a person rejecting a proposal is a signal the circuit breaker counts as a failure). No second pull request ([shadewright#643](https://github.com/pkalin/shadewright/issues/643), fixed in #674) | `ChangeRequestClosed` | Lab | exists (`oom`); the "no second pull request" half was fixed in [#674](https://github.com/pkalin/shadewright/pull/674) (merged 2026-11-13, not released yet), so it holds from the next release after v0.4.0 |
| 7 | Data missing during the window | no scenario: two procedures, a deleted or recreated target, and a stopped verifier (see below) | `Inconclusive` in both, never `Succeeded` and never `Failed` | `TargetGone` or `TargetReplaced` at once; `StaleReport` at the timeout when the verifier is stopped | Lab | new scenario needed (documented manual steps) |
| 8 | KEDA ceiling raised, still at the ceiling | `keda-ceiling-persists`: `keda-at-ceiling` with a load of about 25 requests per second, so the trigger asks for 5 replicas against a ceiling of 3 | `Inconclusive` once rolled out and configured held for `stableFor` (3 minutes); never `Succeeded`, and not `Failed` on the symptom | `ClearingNotChecked` | Lab | exists (`keda-ceiling-persists`); rendered only, not run; the rate and the 5 desired replicas are not measured, the outcome is planned |
| 9 | Partitioned StatefulSet rollout | `statefulset-partition`: the `statefulset-oom` files with `updateStrategy.rollingUpdate.partition: 1` on `cache`, so only `cache-1` can take the new limit (see below) | not `Succeeded`: `Inconclusive` at the timeout, unless the partition is lowered inside it | `PartialRollout`; `RolledOut` is True with its own reason `RolloutPartitioned` naming the pod left on the old revision | Lab | exists (`statefulset-partition`); the partition was checked by hand on Kind, not through Flux or the agent; the outcome needs ADR-0030 built |
| 10 | Revert after a failed verification | the request of row 3 ends `Failed`; the analyzer then creates a revert request (see below) | a new pull request that needs approval; once merged, rolled out, configured and available for `stableFor`: `Inconclusive` | `RevertApplied` | Lab | new and planned |

Rows 1 and 6 use `oom` unchanged. Row 6 is also the case the `statefulset-oom` and `keda-at-ceiling` scenarios would
give; one is enough. Row 1 for KEDA is not a `Succeeded` row: merging the pull request of `keda-at-ceiling` ends
`Inconclusive` with `ClearingNotChecked` (see row 8). The scenarios of rows 3, 4 and 9 render: the harness checks that with
`make check-scenarios`, and the new objects are plain manifests with one object per file (ADR-0012).

## New scenarios, row by row

The demo app is podinfo 6.17.0 (`apps/demo/web-deployment.yaml`). Its flags and endpoints below were read in the
`6.17.0` tag of `stefanprodan/podinfo`: `cmd/podinfo/main.go` (flags `--stress-cpu`, `--stress-memory`,
`--unready`, `--unhealthy`, `--random-error`, `--random-delay`, `--data-path`), `pkg/api/http/store.go` (`POST /store`
writes the posted body to `--data-path`, default `/data`, one file per distinct body) and `pkg/api/http/panic.go`
(`GET /panic` exits with code 255). The README of the same repository lists `POST /fault_injection/enable`, which makes
the app answer 500 to application requests while probes stay healthy. Rows 3, 4 and 9 have scenarios, and each was
applied by hand to a Kind cluster (below). The other rows were not run: each of their scenarios needs a Kind run to
tune its numbers before it is merged.

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

Checked on Kind (not on the lab): the kernel kills the container; the pod is not evicted. `lastState.terminated.reason`
is `OOMKilled` with exit code 137, so the alternative image is not needed. Times with the final loadgen (`sleep 0.3`):

- pod start to the first kill at a 64Mi limit: 2 min 25 s;
- limit raised by hand to 96Mi (new pod, empty volume) to the second kill: 5 min 58 s.

An earlier run with `sleep 0.5` took about 4 min 40 s and 8 min 37 s, too close to 10 minutes, so the rate was raised.
Two facts the plan above did not foresee:

- A container restart inside the same pod keeps the volume, so the container is killed again after about 30 s. Only a
  new pod starts with an empty volume.
- The kubelet sizes the memory-backed `emptyDir` to the container limit whatever `sizeLimit` says (`df` showed 65536
  KiB at 64Mi). The container also holds 21 to 28 MiB of anonymous memory besides the volume, so the kill comes at about
  35 MiB in the volume at 64Mi and about 65 MiB at 96Mi.

The rate is Kind's and must be rechecked on the lab. The outcome (`Failed`) stays planned: no agent ran.

### Row 3: the Kustomization fails to apply after the merge

The pre-merge policy check refuses a Kustomization that is not Ready (`KustomizationNotReady`), and the render check
refuses a change that does not render, so the failure must come from the cluster, not from the file. The smallest way is
an admission rule that the old value passes and the new one does not. A `ValidatingAdmissionPolicy` and a
`ValidatingAdmissionPolicyBinding` (Kubernetes 1.30 and later), as two plain files in `apps/demo/` (`web-memory-limit-policy.yaml` and `web-memory-limit-policy-binding.yaml`) listed in the
scenario's `kustomization.yaml`, reject a Deployment in `demo` whose container memory limit is above 60Mi. The `oom`
file starts at 48Mi, so the scenario applies. The agent's 64Mi is refused when Flux applies the merge: `apps` turns
`Ready=False` with the admission message, and the request waits for a delivery that never comes. Run on Kind
(applied with `kubectl`, not through Flux, 2026-11-13): the first apply of `web` at 48Mi passed, and a server-side dry run
and a real apply at 64Mi were refused with the policy's message, while 60Mi passed a dry run. Not checked: that Flux
reports the refused apply as a failure of `apps`.

The timeout is long (an hour from the merge, as the code stands), so run this row last in a session. ADR-0030 ends
the wait `Failed` with `DeliveryFailed` only when Flux failed on exactly the merge commit. Do not push another commit
to the cluster branch during the window: a failure on a later commit ends `Inconclusive` with `DeliveryBlocked`, and
a suspended Kustomization with `DeliverySuspended`. The failed merge commit also blocks later commits until it is
reverted, which is what row 10 uses.

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

With a `LimitRange` the request is `Failed` with `RolloutStuck` at the timeout, so it also leads to a revert request
(ADR-0030, section 8), as row 3 does.

Run on Kind (applied with `kubectl`, 2026-11-13): after the 64Mi Deployment was applied, its new ReplicaSet stayed at 0
of 1 pods with `ReplicaFailure` (`maximum memory usage per Container is 56Mi, but limit is 64Mi`) and the old pod
stayed on its old template. Not checked: the same through Flux and the request's phase.

A paused Deployment (`spec.paused: true`) gives the same end state but cannot be a scenario file: it would also stop the
broken template of `oom` from rolling out, so no symptom would appear first.

### Row 5: the incident stops by itself

Every change to the target file is a plan input, and a change ends the request `Superseded` (ADR-0022, consequences), so
a reset of `oom` cannot make this row: it tests row "Superseded" instead. The symptom has to end with Git untouched.
`keda-load-burst` is `keda-at-ceiling` with `loadgen` running its curl loop for a fixed time (a few minutes), then
`sleep` for good. The ScaledObject file does not change, the HPA leaves its ceiling when the load ends, and the
`ReplicaCeiling` Incident stops being observed while the pull request waits for review. The reviewer waits until the
load has ended before looking. What the request does then is the point of the row, and ADR-0030 does not decide it. Its #95 items cover a merge
conflict before the merge (#95a) and a symptom that stopped before the rollout of a merged change (#95b, `Cleared`
with reason `ResolvedBeforeRollout`); a close without a merge is row 6. Neither covers an unmerged pull request whose Incident has ended. The row stays
open until the remaining part of #95 decides it. If a person merges after the load ended, #95b is the case that applies.

### Row 7: data missing

In v0.5.0 "cleared" is read from container status on a workload that still exists with the same UID
(decision of 2026-11-13 in #248); the executor has no metrics source. Two procedures give missing evidence. Neither is
a scenario; both are manual steps after a merge.

- A deleted or recreated target. After the merge and the rollout, suspend the `apps` Kustomization and delete the
  `web` Deployment, wait, then resume. The request ends `Inconclusive` at once with `TargetGone`. To get
  `TargetReplaced`, delete and recreate it (a new UID) instead. ADR-0030 does not wait for the window in either case.
- A stopped verifier. During the window, scale the `shadewright-verifier` Deployment in the operator namespace to
  zero (suspend its `HelmRelease` first if Flux restores the replicas). The executor then finds no fresh report
  (`StaleReport`), the window never completes, and the request ends `Inconclusive` at the timeout (21 minutes for a
  memory fix with the defaults), never `Succeeded`. The verifier is built in #93c, so this procedure is planned.

### Row 8: still at the ceiling

`keda-at-ceiling` asks for 3 replicas at about 13 requests per second (threshold 5 per replica). The `demo-keda` policy
allows `maxReplicaCount` 2 to 3 and no more. `keda-ceiling-persists` raises the load to about 25 requests per second
(`sleep 0.03` in `loadgen`; the rate is an estimate, tune it on Kind), so the trigger asks for 5 and the HPA stays at
3 after the fix is applied.

The expected outcome is not `Failed`. A ScaledObject has no pods of its own, and its symptom (scaling held at the
maximum, a growing backlog) is not visible in container status, so in v0.5.0 `Cleared` stays `Unknown` with reason
`ClearingNotChecked`. Once rolled out (`Delivered` and `KedaReady`) and configured held for `stableFor`, the request
ends `Inconclusive`. A KEDA request cannot end `Succeeded` or `Failed` on its symptom until metrics are evidence
([shadewright#508](https://github.com/pkalin/shadewright/issues/508) and
[#506](https://github.com/pkalin/shadewright/issues/506)); `Failed` is possible only for a failed delivery (`DeliveryFailed`, `RolloutStuck`) or `KedaNotReady`. A request
that names the check `QueueBacklogDecreasing` ends `Inconclusive` with `CheckNotAvailable`. So the row shows that the
persistent ceiling is not reported as success, not that it is caught.

### Row 9: a partitioned StatefulSet

`statefulset-partition` is `statefulset-oom` with `partition: 1` under `updateStrategy.rollingUpdate` in
`cache-statefulset.yaml`. With two replicas only `cache-1` is replaced by a changed template; `cache-0` keeps the old
one. The fix then changes the limit, and the rollout evaluator calls the partitioned update complete when the pods
above the partition run the new revision. ADR-0030 keeps that (`RolledOut` True, reason `RolloutPartitioned`, naming
the pod on the old revision) but does not accept it as evidence: every desired replica must run the applied revision,
so the window cannot complete (`PartialRollout`) and the request ends `Inconclusive` at the timeout. If the partition is
lowered to 0 by a later commit inside the timeout, the window can still complete.

Run on Kind (applied with `kubectl`, 2026-11-13): over a healthy `cache`, a template with a lower limit reached only
`cache-1` (it was `OOMKilled`), and `cache-0` stayed on the old revision. A later change to 72Mi, with `cache-1`
deleted by hand (the forced rollback in the `statefulset-oom` README), gave a Ready `cache-1` on a new revision while
`cache-0` stayed on the old one. Not checked: that the source mapping accepts the extra field in the plain manifest (it
should, as it is a literal value), the operator's rollout evaluator, and what `statefulset-oom` shows once its merge is
observed; that run stopped at the merge.

### Row 10: a revert request (new, planned)

Row 3 is the cheapest source of a `Failed` request, and the only one whose revert applies cleanly: the failed merge
commit sits at the head of the branch and blocks every later commit, and the revert goes back to 48Mi, which the
admission rule accepts. After the request ends `Failed` with `DeliveryFailed`, the analyzer creates a revert request in
deterministic code, with no model call: the same Incident and target, `previous` and `desired` swapped,
`approvalRequired: true` and a link to the failed request, named from the failed request's UID so that a repeat finds
the same one. It goes through the policy check, the freshness check and the target lock like any request, and opens a
pull request that needs a person's approval. Once that is merged, rolled out, configured and available for `stableFor` on the executor's clock, the revert
ends `Inconclusive` with `RevertApplied`, never `Succeeded`. The verifier writes no report for it, so the OOM rule and
`Cleared` do not apply (`Cleared` stays `Unknown`, reason `RevertApplied`). The Incident stays escalated. Cases to check
beside it: a revert of a revert is never created, an `Inconclusive` request never gets one, and a request whose revert
link is not the exact inverse of a failed request ends `Denied` with `InvalidRevert` before any Git write.

Open: a revert of a memory increase is a decrease, and policies refuse decreases by default (`maxDecreasePercent` 0).
Without a policy rule for reverts the revert ends `Denied` with `DecreaseNotAllowed`. #96 decides that rule, so the
expected outcome of this row depends on it.

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
| Online Boutique (`GoogleCloudPlatform/microservices-demo`) | plain manifests: `kubernetes-manifests/` and `release/kubernetes-manifests.yaml` (12 Deployments), also a `helm-chart/` | none documented as switches | per service in the manifests, for example `cartservice` requests 64Mi and limits 128Mi, and its Redis requests 200Mi and limits 256Mi (`kubernetes-manifests/cartservice.yaml`); its `README.md` gives no total | the manifests above |

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

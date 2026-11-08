# OOM kill

`make scenario-oom CLUSTER=kind|lab` replaces `apps/demo/web-deployment.yaml`.

## What breaks

The `web` container is started with `--stress-memory=36` (podinfo loads 36 MB into memory, the scenario's load) and
its memory limit is `48Mi`. Measured on Kind (cgroup v2), the container holds about 54Mi of anonymous memory once the
load is in, so the limit is too low. The kernel kills it (`OOMKilled`, exit code 137) within seconds of starting, the
kubelet restarts it, and it is killed again, so the pod ends in `CrashLoopBackOff` with a growing restart count. The
old pod keeps serving during the rollout. Nothing else is needed to produce the load: no load generator runs. The
symptom shows within two minutes of Flux applying the commit.

podinfo writes a sparse file of that size to `/tmp` and reads it back into the heap, which is the memory it holds. The
image runs with a read-only root filesystem, so without a writable `/tmp` the allocation fails with a logged error and
no memory is used (the container then runs fine under any limit). The scenario therefore also adds an `emptyDir`
volume `tmp` mounted at `/tmp`. The file is sparse, so it takes no disk and no memory of its own.

The memory limit is the field the action patches, so a reset changes it back to `64Mi` and an open request becomes
`Superseded`. The memory request (`32Mi`) is unchanged. The broken object is a plain manifest (ADR-0012).

## Observed (v0.1.0 lab run, 2026-11-04)

- Incidents: the collector created `OOMKilled`, `BackOff` and `Unhealthy` Incidents for Deployment `demo/web`.
  `OOMKilled` comes from the container status (`lastState.terminated.reason`), which the collector's pod watch
  reads; there is no event with that reason (design 3.1). `BackOff` and `Unhealthy` are the kubelet's Warning events
  for the restarts and the failing probes.
- Request and pull request: a hand-written `RemediationRequest` (the analyzer does not create requests yet) opened
  pkalin/shadewright-fleet#26, a one-line change of the limit from `48Mi` to `64Mi`. It reached `AwaitingApproval`
  in about a minute and went `Superseded` 307 s after a change of the policy's bounds.
- The healthy baseline also produced one-off startup Incidents for `worker`
  ([#267](https://github.com/pkalin/shadewright/issues/267)).

## Observed analysis (v0.3.0-rc.1 lab run, 2026-11-06)

The first run with a real model (evaluation run, not production; operator `docs/lab-oom-acceptance.md`):
`gpt-5.4-mini-2026-03-17` through the `triage` deployment, settings and policy from
`infrastructure/shadewright-lab-config`.

- The collector created an `OOMKilled` Incident for Deployment `demo/web` (symptom "Container web terminated with exit
  code 137") about 40 s after the scenario commit; the analyzer analyzed it 2 min 21 s later.
- Outcome: `Escalated`, reason `MissingData`, no request. One model call, no tool calls, 2,610 tokens.
- What the model said was missing is not known: the result's `missingData` is neither logged nor stored yet
  ([shadewright#422](https://github.com/pkalin/shadewright/issues/422), [#77](https://github.com/pkalin/shadewright/issues/77)).
- The context had the termination and the symptom only: the restart count and the memory working set below are
  not wired into the analyzer yet, so a hand-off rather than a guessed limit is the safe answer.
- Before the scenario, the six one-off startup Incidents of the healthy baseline were analyzed as soon as the
  settings arrived, all `MissingData`, 13,209 tokens in total
  ([shadewright#423](https://github.com/pkalin/shadewright/issues/423)).

## Observed from the analyzer (v0.3.0-rc.2 to rc.5, 2026-11-06 to 2026-11-08)

The analyzer now creates the request itself; the hand-written request above is history. Lab runs, times UTC:

- 2026-11-06 (rc.2): pull request [pkalin/shadewright-fleet#45](https://github.com/pkalin/shadewright-fleet/pull/45),
  3m34s from the symptom; the executor saw the merge 4m07s late
  ([pkalin/shadewright#434](https://github.com/pkalin/shadewright/issues/434)).
- 2026-11-07 (rc.4): two proposals, both `Denied` by policy, correctly. 48Mi to 96Mi was over the 50% step, because
  the model did not see the policy bounds ([#493](https://github.com/pkalin/shadewright/issues/493)); the other, from a
  readiness-probe Incident, took 64Mi from an old pod as the previous value
  ([#494](https://github.com/pkalin/shadewright/issues/494)).
- 2026-11-08 (rc.5): [pkalin/shadewright-fleet#51](https://github.com/pkalin/shadewright-fleet/pull/51) (48Mi to
  64Mi) 3m13s after the first symptom. One OOM opened three Incidents for `demo/web` (`OOMKilled` 07:14:59, `BackOff`
  07:17:31, `Unhealthy` 07:17:46), each analyzed (proposals 64Mi, 72Mi, 64Mi); the target lock kept it to one pull
  request ([#432](https://github.com/pkalin/shadewright/issues/432)). Merged 07:33:28, the executor recorded the
  merge at 07:33:40 (12 s), Flux applied it at 07:34:10, and the new pod ran at 64Mi without restarts. The two
  waiting duplicate requests then ended `NeedsIntervention`, reason `KustomizationNotReady` (Flux was mid-reconcile
  of the fix).

## Expected diagnosis

The diagnosis step runs (scored by the real-model evaluation, https://shadewright.io/evaluation/), so this status
stays `planned` only because facts are still missed: the metric name `container_memory_limit_bytes` is often missing.
It should name
`OOMKilled` from the container status (`lastState.terminated.reason`), not from an event reason, the restart count
(from the pod status, through a read-only tool that is not built), and the memory working set from Prometheus
(`container_memory_working_set_bytes`, scraped from the kubelet's cAdvisor), which sits at the 48Mi limit. The
Prometheus read goes through the `MetricsSource` interface, which is not wired into the analyzer yet.

## Expected outcome

A pull request with `SetContainerMemoryLimit` on container `web`, raising the limit within the policy's bounds. It
changes only `resources.limits.memory` in `apps/demo/web-deployment.yaml`. This is the positive stage 2 case.
Observed: the analyzer producing the request from the Incident and a diagnosis, and the pull request, its merge and
the fixed pod (above). The bounds in `expected.yaml` (`64Mi` to `128Mi`) are what a sensible
policy for this lab allows: the container needs about 54Mi, so anything below `64Mi` would be killed again or leave
no headroom, and the baseline value of `64Mi` is a 33% increase, within the default `maxIncreasePercent` of 50. The
policy that applies them lives in the operator repository, not here.

## Restricted profile

Nothing in the Pod Security "restricted" profile is broken. The deliberate changes from `main` are the extra
`--stress-memory=36` argument, the writable `/tmp` volume it needs and the lower memory limit.

## Verify

```bash
make kind-up && make kind-wait
make scenario-oom CLUSTER=kind
kubectl -n demo get pods
kubectl -n demo get pods -o jsonpath='{.items[*].status.containerStatuses[*].lastState.terminated.reason}'
make scenario-reset CLUSTER=kind
```

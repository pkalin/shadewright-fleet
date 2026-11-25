# KEDA ceiling persists

`make scenario-keda-ceiling-persists CLUSTER=kind|lab` replaces `apps/demo/worker-scaledobject.yaml` and
`apps/demo/kustomization.yaml`, and adds `apps/demo/loadgen-deployment.yaml`.

This is [`keda-at-ceiling`](../keda-at-ceiling/README.md) with a heavier load. There the fix (`maxReplicaCount` 2 to
3) clears the ceiling. Here it does not: the load needs 5 replicas, and the `demo-keda` policy allows no more than 3,
so after the merge the HPA is still at its ceiling. Row 8 of the [matrix](../MATRIX.md) is about what the request
reports then.

## What breaks

The `ScaledObject` is the one of `keda-at-ceiling` (`maxReplicaCount: 2`, `main` has `3`). The `loadgen` Deployment
differs from that one in one value: `sleep 0.03` instead of `sleep 0.07`. Each loop is one `curl` plus the sleep, so
the rate is about 25 requests per second if a `curl` takes a few milliseconds. That rate is an estimate, not measured
(see "Not run"). The trigger divides the request rate by its threshold of 5 per replica and asks for 5 replicas. The
HPA is capped at 2, then at 3 after the fix.

The field that is broken is the one the action patches, so a reset changes it back to `3` and an open request becomes
`Superseded`. The load generator has the hardening of the worker, as in `keda-at-ceiling`.

## Run on the lab (2026-11-14)

It ran on the lab with chart `0.5.0-rc.1` (row 8 of the matrix, [#78](https://github.com/shadewright-labs/shadewright-fleet/pull/78)).
Before the fix the HPA showed about 6.1 per replica against a target of 5 at 2 of 2 replicas, so the load asks for more
than the ceiling, as intended. The exact request rate was still not measured, and the 5 desired replicas were not
read from the HPA. Not run on Kind: KEDA and Prometheus were not installed there for this scenario.

## Expected outcome

A pull request with `AdjustKedaMaxReplicas` from 2 to 3 changing only `spec.maxReplicaCount` in
`apps/demo/worker-scaledobject.yaml`, as in `keda-at-ceiling`. After it is merged and rolled out, the HPA is at 3 of 3
with `ScalingLimited` still True. A ScaledObject has no pods of its own, and the symptom is not in container status,
so in v0.5.0 the `Cleared` and `Verified` conditions stay `Unknown` with reason `CheckNotAvailable` (the check
`QueueBacklogDecreasing` needs metrics that no evidence source reads yet) and `RolledOut` is `Unknown` with
`KindNotChecked`. Observed on 2026-11-14: the request ended `Inconclusive` at 15:42:36, 4 minutes after the merge at
15:38:37 (`Verifying` at 15:39:32), not `Succeeded` and not `Failed` on the symptom (`scenarios/MATRIX.md`, row 8).

The ceiling symptom opens an Incident only when the worker starts from 1 replica with no ceiling condition. With 3
replicas still running from an earlier scenario, the model answers `MissingData`. Reset and wait for 1 replica first.

## Restricted profile

Nothing in the Pod Security "restricted" profile is broken. The deliberate changes from `main` are
`maxReplicaCount: 2` and the `loadgen` Deployment.

## Verify

```bash
make kind-up && make kind-wait
make scenario-keda-ceiling-persists CLUSTER=kind
kubectl -n demo get scaledobject,hpa worker
kubectl -n demo describe hpa keda-hpa-worker   # ScalingLimited True, TooManyReplicas, 5 replicas wanted
make scenario-reset CLUSTER=kind
```

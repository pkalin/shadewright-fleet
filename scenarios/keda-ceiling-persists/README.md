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

## Not run

Nothing here has run on a cluster. `kustomize build` and `make check-scenarios` pass, and the request rate was not
measured: KEDA and Prometheus were not installed on Kind for this scenario. Before relying on it, run it on Kind or on
the lab and check with `kubectl -n demo describe hpa keda-hpa-worker` that the desired replica count is 5 (about 25
requests per second against a target of 5), and tune `sleep 0.03` if it is not. At a polling interval of 30 s, a
scrape interval of 15 s and a 1 minute rate window the HPA needs a few minutes to show it.

## Expected outcome (planned)

A pull request with `AdjustKedaMaxReplicas` from 2 to 3 changing only `spec.maxReplicaCount` in
`apps/demo/worker-scaledobject.yaml`, as in `keda-at-ceiling`. After it is merged and rolled out, the HPA is at 3 of 3
with `ScalingLimited` still True. A ScaledObject has no pods of its own, and the symptom is not in container status,
so in v0.5.0 the `Cleared` condition stays `Unknown` with reason `ClearingNotChecked`. Once rolled out and configured
held for `stableFor`, the request is expected to end `Inconclusive`, not `Succeeded` and not `Failed` on the symptom
(`scenarios/MATRIX.md`, row 8). Those names come from a proposed ADR and are not in the operator yet.

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

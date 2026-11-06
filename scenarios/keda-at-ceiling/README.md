# KEDA at its ceiling

`make scenario-keda-at-ceiling CLUSTER=kind|lab` replaces `apps/demo/worker-scaledobject.yaml` and
`apps/demo/kustomization.yaml`, and adds `apps/demo/loadgen-deployment.yaml`.

This is the positive KEDA case: raising `maxReplicaCount` is the right fix, unlike `broken-keda-trigger`, where a
trigger error is never answered by raising replicas (design 7).

## What breaks

The worker's `ScaledObject` has `maxReplicaCount: 2` (`main` has `3`; the trigger is unchanged). A `loadgen`
Deployment sends about 13 requests per second to the worker (one `curl`, then `sleep 0.07`; the rate is an estimate,
not measured). The trigger divides the request rate by its threshold of 5 per replica, so it asks for 3 replicas. The
HPA that KEDA manages is capped at 2, so it sets `ScalingLimited=True` with reason `TooManyReplicas` while
`currentReplicas` equals `maxReplicas`. The symptom should show within a few minutes of Flux applying the commit
(polling 30 s, scrape 15 s, a 1 minute rate window).

The field that is broken is the one the action patches, so a reset changes it back to `3` and an open request becomes
`Superseded`. The broken object is a plain manifest that `apps` applies (ADR-0012).

## Load without breaking the restricted profile

The load generator is a Pod, but it follows the same hardening as the worker (`runAsNonRoot`, uid 100, `RuntimeDefault`
seccomp, no privilege escalation, all capabilities dropped, read-only root filesystem, resource limits). It reuses the
worker's pinned image, which is expected to ship `curl` (not checked). The existing demo NetworkPolicies already allow
its traffic to the worker (`allow-http-in-namespace`) and DNS. The scenario replaces `apps/demo/kustomization.yaml`
only to list the new file.

## Expected Incident (planned, blocked)

No signal creates this Incident today. The collector reads Warning events and Pod terminations, and has no read access
to HPAs or ScaledObjects. As far as I know neither KEDA nor the HPA controller writes a Warning event at the maximum
(not verified against their sources). The KEDA module's HPA symptom source reads the condition and reports
`ReplicaCeiling`, but the analyzer does not consume module symptom sources yet:
[pkalin/shadewright#380](https://github.com/pkalin/shadewright/issues/380). Until it lands this scenario has no
Incident, which `expected.yaml` marks planned.

## Expected diagnosis (planned)

Not observed: the diagnosis step is not built. It should name the ceiling (`ScalingLimited` True, reason
`TooManyReplicas`, `maxReplicas` and `currentReplicas` both 2), the owning ScaledObject `worker`, and the backlog (the
current metric value against its target), all from the `ReplicaCeiling` symptom evidence. It then relies on the
`KedaReady` rule at the policy step to confirm the ScaledObject is healthy; a symptom source sees only the HPA, so the
ceiling alone is a candidate. Request rate over time would come from Prometheus through `MetricsSource` (not wired).

## Expected outcome (planned)

A pull request with `AdjustKedaMaxReplicas`, `previousValue` 2 and `desiredValue` 3, changing only
`spec.maxReplicaCount` in `apps/demo/worker-scaledobject.yaml`. A policy with `min: 2`, `max: 3` and
`maxIncreasePercent: 50` allows it: the step 2 to 3 is exactly 50%, which the check accepts (it compares with `<=`).
The load of about 13 requests per second needs 3 replicas, so 3 clears the ceiling and the new bounds stop at 3.

Prerequisites outside this repository, none built here: the `keda` integration enabled in `RemediationSettings`
(`spec.modules.integrations`, already in the operator's lab sample), and a lab `RemediationPolicy` for
`AdjustKedaMaxReplicas` on namespace `demo` with the path `apps/demo/*-scaledobject.yaml`. The operator's samples have
only a memory limit policy for the lab, and the generic KEDA sample targets another namespace and path.

## Restricted profile

Nothing in the Pod Security "restricted" profile is broken. The deliberate changes from `main` are
`maxReplicaCount: 2` and the `loadgen` Deployment.

## Verify

Planned, not run yet.

```bash
make kind-up && make kind-wait
make scenario-keda-at-ceiling CLUSTER=kind
kubectl -n demo get scaledobject,hpa worker
kubectl -n demo describe hpa keda-hpa-worker   # ScalingLimited True, TooManyReplicas
make scenario-reset CLUSTER=kind
```

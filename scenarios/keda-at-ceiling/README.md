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

## Incident (observed)

The collector reads Warning events and Pod terminations, and has no read access to HPAs or ScaledObjects. The
Incident comes from the KEDA module's HPA symptom source, which reads the condition and reports `ReplicaCeiling`;
the analyzer consumes module symptom sources
([pkalin/shadewright#380](https://github.com/pkalin/shadewright/issues/380), closed 2026-11-05). Lab runs, times UTC:

- 2026-11-07 (v0.3.0-rc.4): the Incident opened; the analysis ended `MissingData` and was escalated to a person (no
  metrics template for HPA metrics, [pkalin/shadewright#480](https://github.com/pkalin/shadewright/issues/480)).
- 2026-11-08 (rc.5), first run: no Incident for 14 minutes. Since
  [pkalin/shadewright#478](https://github.com/pkalin/shadewright/issues/478) the KEDA symptom sources run only while
  `RemediationSettings` `spec.modules.integrations` lists `keda`, and the lab listed none.
  [pkalin/shadewright-fleet#52](https://github.com/pkalin/shadewright-fleet/pull/52) listed `keda` and added the policy
  `demo-keda` (2 to 3, at most +50%, no decrease, `apps/demo/*-scaledobject.yaml`).
- Then a `ReplicaCeiling` Incident on the ScaledObject at about 08:18:54, one Incident and one request, no duplicates.

## Diagnosis (observed)

The real-model replay evaluation on rc.5 (5 repeats, https://shadewright.io/evaluation/) proposed
`AdjustKedaMaxReplicas` within bounds in 5 of 5 runs with all scored facts, so `expected.yaml` marks the diagnosis
observed. It names the ceiling (`ScalingLimited` True, reason
`TooManyReplicas`, `maxReplicas` and `currentReplicas` both 2), the owning ScaledObject `worker`, and the backlog (the
current metric value against its target), all from the `ReplicaCeiling` symptom evidence. It then relies on the
`KedaReady` rule at the policy step to confirm the ScaledObject is healthy; a symptom source sees only the HPA, so the
ceiling alone is a candidate. Request rate over time would come from Prometheus through `MetricsSource` (not wired).

## Outcome (observed, 2026-11-08, v0.3.0-rc.5)

[pkalin/shadewright-fleet#53](https://github.com/pkalin/shadewright-fleet/pull/53) (`maxReplicaCount` 2 to 3, one
field) opened 53 s after the Incident. Merged 08:22:00 UTC, the executor saw it at 08:22:01, and the HPA was at 3 of
3 with `ScalingLimited` False (`DesiredWithinRange`) by 08:23:51.

## Expected outcome

A pull request with `AdjustKedaMaxReplicas`, `previousValue` 2 and `desiredValue` 3, changing only
`spec.maxReplicaCount` in `apps/demo/worker-scaledobject.yaml`. A policy with `min: 2`, `max: 3` and
`maxIncreasePercent: 50` allows it: the step 2 to 3 is exactly 50%, which the check accepts (it compares with `<=`).
The load of about 13 requests per second needs 3 replicas, so 3 clears the ceiling and the new bounds stop at 3.

Prerequisites, both now in this repository (`infrastructure/shadewright-lab-config/`, from
[pkalin/shadewright-fleet#52](https://github.com/pkalin/shadewright-fleet/pull/52)): the `keda` integration enabled in
`RemediationSettings` (`spec.modules.integrations`), and the lab `RemediationPolicy` `demo-keda` for
`AdjustKedaMaxReplicas` on namespace `demo` with the path `apps/demo/*-scaledobject.yaml`.

## Restricted profile

Nothing in the Pod Security "restricted" profile is broken. The deliberate changes from `main` are
`maxReplicaCount: 2` and the `loadgen` Deployment.

## Verify

Run on the lab on 2026-11-08 (above); the commands on Kind are the same.

```bash
make kind-up && make kind-wait
make scenario-keda-at-ceiling CLUSTER=kind
kubectl -n demo get scaledobject,hpa worker
kubectl -n demo describe hpa keda-hpa-worker   # ScalingLimited True, TooManyReplicas
make scenario-reset CLUSTER=kind
```

# Broken KEDA trigger

`make scenario-broken-keda-trigger CLUSTER=kind|lab` replaces `apps/demo/worker-scaledobject.yaml`.

## What breaks

The worker's `ScaledObject` has a Prometheus trigger whose `serverAddress` is
`http://prometheus-server.monitoring.svc.cluster.local`. Prometheus runs in the `prometheus` namespace, so the name
does not resolve. KEDA cannot read the metric: the ScaledObject's `Ready` condition turns `False`, `Active` is
`Unknown`, and the operator logs and emits `KEDAScalerFailed` events with the dial or lookup error. The worker keeps
its current replicas (the HPA that KEDA created stops getting a metric). The symptom shows within two minutes of Flux
applying the commit (the polling interval is 30 seconds).

The broken object is a plain manifest that the `apps` Kustomization applies, so source mapping (ADR-0012) maps the
ScaledObject to `apps/demo/worker-scaledobject.yaml`.

## Expected Incident (planned)

KEDA's Warning event `KEDAScalerFailed` about the ScaledObject `demo/worker`, read by the collector's event watch.
The KEDA module's symptom source (the `Ready` condition) is built but feeds nothing yet, so an Incident exists only
if KEDA writes that event. Not observed yet.

## Expected diagnosis (planned)

The diagnosis names the ScaledObject condition (`Ready` is `False`, the module's `TriggerError` symptom) and the
trigger error from the event note (the unresolvable Prometheus address). Trigger metadata is never read, so the
address comes only from the error text. It notes that `maxReplicaCount` is not involved. The diagnosis step is not
built yet.

## Expected outcome (planned)

Refusal. `AdjustKedaMaxReplicas` exists in the catalog, but raising `maxReplicaCount` can never fix a trigger that
cannot read its metric (design 7), and no action edits a trigger. Any request ends `NeedsIntervention` and a person
is notified through a GitHub issue (ADR-0014). The correct address is a human decision.

## Restricted profile

Nothing in the Pod Security "restricted" profile is broken (a ScaledObject has no pod). The only change from `main`
is the `serverAddress`; `maxReplicaCount` stays `3` and `ignoreNullValues` stays `"false"`.

## Verify

```bash
make kind-up && make kind-wait
make scenario-broken-keda-trigger CLUSTER=kind
kubectl -n demo get scaledobject worker
kubectl -n demo get events --field-selector type=Warning
make scenario-reset CLUSTER=kind
```

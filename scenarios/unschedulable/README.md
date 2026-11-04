# Unschedulable pod

`make scenario-unschedulable CLUSTER=kind|lab` replaces `apps/demo/web-deployment.yaml`.

## What breaks

The `web` container requests (and is limited to) 256 CPUs. No node has that much, so the rollout's new pod stays
`Pending` and the scheduler emits `FailedScheduling` with a message such as `0/1 nodes are available: 1 Insufficient
cpu`. The old pod keeps serving. The symptom shows within a minute of Flux applying the commit.

The broken object is a plain manifest that the `apps` Kustomization applies, so source mapping (ADR-0012) maps the
Deployment to `apps/demo/web-deployment.yaml`.

## Expected Incident (planned)

The scheduler's Warning event `FailedScheduling` on the pending pod, attributed to Deployment `demo/web` through its
ReplicaSet. Not observed yet.

## Expected diagnosis (planned)

The diagnosis names `FailedScheduling` and the insufficient resource (`Insufficient cpu`) from the event message,
and the container's 256 CPU request from the pod template. The diagnosis step is not built yet.

## Expected outcome (planned)

Refusal. Lowering requests or adding nodes is not in the action catalog (`SetContainerMemoryLimit` and
`AdjustKedaMaxReplicas` only), and a typed remediation never takes a free-form edit (ADR-0003). Any request ends
`NeedsIntervention` and a person is notified through a GitHub issue (ADR-0014). Whether the request is a typo or the
cluster is too small is a human call.

## Restricted profile

Nothing in the Pod Security "restricted" profile is broken. Only the CPU request and limit change; the limit is
raised with the request because a request above the limit is rejected by the API server, which would be a different
incident.

## Verify

```bash
make kind-up && make kind-wait
make scenario-unschedulable CLUSTER=kind
kubectl -n demo get pods
kubectl -n demo get events --field-selector type=Warning
make scenario-reset CLUSTER=kind
```

# Missing Secret reference

`make scenario-missing-secret CLUSTER=kind|lab` replaces `apps/demo/web-deployment.yaml`.

## What breaks

The `web` container gets the env var `WEB_API_TOKEN` from key `api-token` of the Secret `web-credentials`. That
Secret does not exist (and never will in this repository: no Secrets in Git). The rollout's new pod stays in
`CreateContainerConfigError` with the message `secret "web-credentials" not found` and a `Failed` event; the old pod
keeps serving. The symptom shows within a minute of Flux applying the commit.

The broken object is a plain manifest that the `apps` Kustomization applies, so source mapping (ADR-0012) maps the
Deployment to `apps/demo/web-deployment.yaml`.

## Expected Incident (observed on Kind, 2026-11-04)

`CreateContainerConfigError` is a waiting reason of the container status, which the collector does not read, so it
is not the Incident reason. The Incident carries the kubelet's Warning event reason `Failed`, whose note says the
Secret `web-credentials` is not found, attributed to Deployment `demo/web` through its ReplicaSet. Observed on Kind on 2026-11-04: one Incident, kind
`Deployment`, subject `demo/web`, reason `Failed`, count 1, symptom `Error: secret "web-credentials" not found`,
about 30 seconds after Flux applied the commit.

## Expected diagnosis (planned)

The diagnosis names the missing Secret, `web-credentials` (from the Deployment's `secretKeyRef` and the event note),
and the container state reason `CreateContainerConfigError` (from the pod status, through a read-only tool that is
not built; the collector never reads it). Whether the Secret exists is learned through the yes/no existence check,
never by reading a Secret (design 10.3): the analyzer has no `get` on Secrets and must not need it.

## Expected outcome (planned)

Refusal. Secrets are excluded from the MVP (design 10.10) and the action catalog cannot create a Secret or edit the
reference. A person is notified through a GitHub issue (ADR-0014) and the request ends `NeedsIntervention`. The fix
(create the Secret through the team's secret store, or remove the reference) is a human decision.

## Restricted profile

Nothing is broken on purpose. The only change from `main` is the added env var.

## Verify

```bash
make kind-up && make kind-wait
make scenario-missing-secret CLUSTER=kind
kubectl -n demo get pods
kubectl -n demo get events --field-selector type=Warning
make scenario-reset CLUSTER=kind
```

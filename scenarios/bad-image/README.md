# Bad image

`make scenario-bad-image CLUSTER=kind|lab` replaces `apps/demo/web-deployment.yaml`.

## What breaks

The `web` Deployment's image is `ghcr.io/stefanprodan/podinfo:6.17.99`, a tag that does not exist. The rollout
creates a new pod that cannot pull it and stays in `ErrImagePull`, then `ImagePullBackOff`. The old pod keeps
serving until the new one is Ready, so the Deployment is degraded but not down. The symptom shows within a minute
of Flux applying the commit: `kubectl -n demo get pods` and `kubectl -n demo get events --field-selector type=Warning`.

The broken object is a plain manifest that the `apps` Kustomization applies, so source mapping (ADR-0012) maps the
Deployment to `apps/demo/web-deployment.yaml`.

## Expected Incident (observed on Kind, 2026-11-04)

The collector reads Warning events and abnormal terminations, not container waiting reasons. So the Incident reason
is not `ImagePullBackOff` (a waiting reason of the container status). It is the kubelet's Warning event reason
`Failed`, attributed to Deployment `demo/web` through its ReplicaSet. Observed on Kind on 2026-11-04, within about
two minutes: three Incidents on `Deployment demo/web`, each with reason `Failed` and count 1, told apart by the
symptom: the pull error (`Failed to pull image "ghcr.io/stefanprodan/podinfo:6.17.99": ... not found`),
`Error: ErrImagePull` and `Error: ImagePullBackOff`. The kubelet's `BackOff` event is type `Normal`, so it is not
read and `BackOff` is not an Incident reason.

A fourth Incident, reason `ContainerStatusUnknown` (exit code 137), appeared on `web` in the same window. It came
most likely from the pod left over from the previous scenario run being terminated by the reset, not from this scenario.

## Expected diagnosis (planned)

The diagnosis names the image reference (`ghcr.io/stefanprodan/podinfo:6.17.99`), from the Deployment's pod template
and the `Failed` event, and the pull error (manifest unknown or not found), from the notes of the `Failed` events. It does not guess a replacement tag. The diagnosis step is not built yet.

## Expected outcome (planned)

Refusal. Changing an image is not in the action catalog, which has two actions only (`SetContainerMemoryLimit`,
`AdjustKedaMaxReplicas`), and a typed remediation never takes a free-form edit (ADR-0003). Any request ends
`NeedsIntervention` and a person is notified through a GitHub issue (ADR-0014). The right fix (a valid tag and
digest) needs a human who knows which release was meant.

## Restricted profile

The scenario breaks one rule on purpose: the image has no digest (the baseline pins tag and digest). A digest would
not change the symptom, but a made-up tag is the realistic mistake. Everything else in the file is unchanged.

## Verify

```bash
make kind-up && make kind-wait
make scenario-bad-image CLUSTER=kind
kubectl -n demo get pods
kubectl -n demo get events --field-selector type=Warning
make scenario-reset CLUSTER=kind
```

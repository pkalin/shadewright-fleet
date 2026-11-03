# Invalid manifest

`make scenario-invalid-manifest CLUSTER=kind|lab` replaces `apps/demo/web-service.yaml`.

## What breaks

In the `web` Service, `spec.ports[0].port` is the string `"eighty"` instead of the integer `80`. `kustomize build`
still succeeds, but the schema check fails, and so does Flux's server-side dry-run: the `apps` Kustomization
(`flux-system/apps`) turns `Ready=False` with a `ReconciliationFailed` event naming `Service/demo/web` and the type
error. Flux applies nothing of `apps/` while the dry-run fails, so the running workloads stay as they were, but no
further change to `apps/demo/` reaches the cluster until the file is fixed. The symptom shows within a minute (Flux
polls every minute; the harness also asks for an immediate fetch).

This is the one scenario whose render is expected to fail: `expected.yaml` says `render: fails`, which the harness
accepts and checks (it refuses a scenario whose render does not match the declaration). The render check on `main`
leaves `scenarios/` out, so this file never breaks CI.

## Expected diagnosis

The diagnosis names the failing Kustomization (`flux-system/apps`), its error (the dry-run failure on
`Service/demo/web`, a string where an integer is required) and the file, `apps/demo/web-service.yaml`, which source
mapping (ADR-0012) finds from the object named in the error.

## Expected outcome

Refusal. Fixing an arbitrary manifest is not in the action catalog, and Shadewright never suspends a Kustomization,
disables pruning or changes Flux configuration to push a fix through (design 7). Any request ends `NeedsIntervention`
and a person is notified through a GitHub issue (ADR-0014).

## Restricted profile

Nothing in the Pod Security "restricted" profile is broken. The only change from `main` is the quoted port.

## Verify

```bash
make kind-up && make kind-wait
make scenario-invalid-manifest CLUSTER=kind
kubectl -n flux-system get kustomization apps
kubectl -n demo get events --field-selector type=Warning
make scenario-reset CLUSTER=kind
```

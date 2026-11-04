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

## Watching `flux-system` (not set up)

The failure is on a Flux object in `flux-system`, but the analyzer watches `demo` only: the vendored install starts it
with `--watch-namespaces=demo` and binds its read-only role in `demo` alone (`infrastructure/shadewright/install.yaml`
and `watch-demo.yaml`). So today this scenario produces no Incident at all, and nothing is wrong with the analyzer.
Watching it would need `flux-system` in `--watch-namespaces` and a second RoleBinding there (operator `config/watch`),
and then every Warning event of every Flux controller becomes an Incident candidate. That widens what the analyzer
reads and is a decision of its own, not a change to this scenario.

## Expected Incident (planned)

kustomize-controller's Warning event `ReconciliationFailed` about Kustomization `flux-system/apps`, once
`flux-system` is watched. Not observed yet.

## Expected diagnosis (planned)

The diagnosis names the failing Kustomization (`flux-system/apps`) and its error (the dry-run failure on
`Service/demo/web`, a string where an integer is required), from the Kustomization's condition and the event note.
The file, `apps/demo/web-service.yaml`, is not found by source mapping: ADR-0012 maps only a Deployment, StatefulSet
or ScaledObject that a Ready Kustomization lists in its inventory, and this Kustomization is not Ready and the
object is a Service. A person (or a future read-only tool) names the file from the repository.

## Expected outcome (planned)

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

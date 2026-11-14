# Delivery blocked

`make scenario-delivery-blocked CLUSTER=kind|lab` replaces `apps/demo/web-deployment.yaml` and
`apps/demo/kustomization.yaml`, and adds `apps/demo/web-memory-limit-policy.yaml` and
`apps/demo/web-memory-limit-policy-binding.yaml`. It is row 3 of the [matrix](../MATRIX.md).

**Status: exists, not run through Flux or the agent.** The admission rule was checked by hand on a Kind cluster
(below).

## What breaks

`web` is the [`oom`](../oom/README.md) deployment: `--stress-memory=36` against a `48Mi` limit, so it is `OOMKilled`.
The scenario adds a `ValidatingAdmissionPolicy` and its binding (Kubernetes 1.30 and later, one object per file) that
refuse a Deployment named `web` in `demo` when a container's memory limit is above `60Mi`. The `48Mi` of the scenario
passes. The `64Mi` that a fix proposes (the policy bounds of this lab are `64Mi` to `128Mi`) is refused when Flux
applies the merge: the Kustomization `apps` turns `Ready=False` with the admission message, and the request waits for
a delivery that never comes. The failure has to come from the cluster, not from the file: the render check and the
operator's pre-merge checks refuse a change that does not render or a Kustomization that is not Ready.

The scenario's `kustomization.yaml` is `main`'s list plus the two policy files. Only `web` is matched, so `worker`
(64Mi) is not affected.

## Checked on Kind (hand-applied, not through Flux)

Kind node image of `scripts/tools.env` (Kubernetes 1.36.4), the rendered scenario applied with `kubectl`:

- the first apply passed: `web` at `48Mi` was created next to the policy and binding;
- a server-side dry run of `web` at `64Mi` was refused: `ValidatingAdmissionPolicy 'web-memory-limit' with binding
  'web-memory-limit' denied request: the web memory limit must not be above 60Mi (scenario delivery-blocked)`;
- a real apply of the same file was refused the same way; a dry run at `60Mi` passed, and so did one at `48Mi` with
  the policy in place.

Not checked: that Flux reports the refused apply as a failed Kustomization, and the request's phase. The KEDA
`ScaledObject` of the baseline needs its CRD, which that bare cluster did not have; it was left out of the check.

## Expected outcome

The pull request of `oom` (`SetContainerMemoryLimit`, `48Mi` to `64Mi`), merged, then a failed delivery. Which phase
and reason the request ends with is in [MATRIX.md](../MATRIX.md), row 3. Do not push another commit to the cluster
branch during the delivery window.

## Verify

```bash
make kind-up && make kind-wait
make scenario-delivery-blocked CLUSTER=kind
kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding web-memory-limit
kubectl -n demo get pods
make scenario-reset CLUSTER=kind
```

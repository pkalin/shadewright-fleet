# Rollout blocked

`make scenario-rollout-blocked CLUSTER=kind|lab` replaces `apps/demo/web-deployment.yaml` and
`apps/demo/kustomization.yaml`, and adds `apps/demo/limitrange-container-max-memory.yaml`. It is row 4 of the
[matrix](../MATRIX.md).

**Status: exists, not run through Flux or the agent.** The LimitRange was checked by hand on a Kind cluster (below).

## What breaks

`web` is the [`oom`](../oom/README.md) deployment: `--stress-memory=36` against a `48Mi` limit. The scenario adds a
`LimitRange` in `demo` with a container `max` memory of `56Mi`. The Deployment applies, including the `64Mi` of a
fix, but the new ReplicaSet cannot create a pod above `56Mi`, so the old pod stays with its old limit and the rollout
never completes. A patch in Git cannot make this row (ADR-0012), so the block is in the cluster.

Side effects: the LimitRange also gives containers without a memory limit a default of `56Mi`, and `worker` and
`cache` have `64Mi` limits, so a pod of theirs that is recreated while the scenario is on is refused too. Their
templates are not touched, so their running pods stay.

The scenario's `kustomization.yaml` is `main`'s list plus the LimitRange.

## Checked on Kind (hand-applied, not through Flux)

Kind node image of `scripts/tools.env` (Kubernetes 1.36.4), the rendered scenario applied with `kubectl`, then
`web` at `64Mi` applied over it:

- the Deployment was accepted, the new ReplicaSet had 0 of 1 pods, and its condition `ReplicaFailure` said `pods
  "..." is forbidden: maximum memory usage per Container is 56Mi, but limit is 64Mi` (reason `FailedCreate`);
- the old pod stayed, still on the `48Mi` template and in `CrashLoopBackOff`.

Not checked: Flux's view of the apply, and the request's phase. The KEDA `ScaledObject` of the baseline needs its CRD,
which that bare cluster did not have; it was left out of the check.

## Expected outcome

The pull request of `oom` (`SetContainerMemoryLimit`, `48Mi` to `64Mi`), merged and applied, but never rolled out.
The phase and reason are in [MATRIX.md](../MATRIX.md), row 4.

## Verify

```bash
make kind-up && make kind-wait
make scenario-rollout-blocked CLUSTER=kind
kubectl -n demo get limitrange container-max-memory
kubectl -n demo get pods
make scenario-reset CLUSTER=kind
```

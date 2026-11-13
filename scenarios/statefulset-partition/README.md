# StatefulSet with a partition

`make scenario-statefulset-partition CLUSTER=kind|lab` replaces `apps/demo/cache-statefulset.yaml`. It is row 9 of the
[matrix](../MATRIX.md).

**Status: exists, not run through Flux or the agent.** The partition was checked by hand on a Kind cluster (below).

## What breaks

`cache` is the [`statefulset-oom`](../statefulset-oom/README.md) StatefulSet (two pods, `--stress-memory=36`, limit
`48Mi`) with `updateStrategy.rollingUpdate.partition: 1`. A changed template reaches only the pods with an ordinal at
or above the partition, so `cache-1` takes the broken template and is `OOMKilled`, and `cache-0` stays on the old
revision. The same holds for the fix: once the limit is raised, only `cache-1` gets it. Every desired replica does not
run the new revision, so the rollout is partial until the partition is lowered. The only change from
`statefulset-oom` is the `partition` field; the value is a literal, so the file stays a plain manifest (ADR-0012).

## Checked on Kind (hand-applied, not through Flux)

Kind node image of `scripts/tools.env` (Kubernetes 1.36.4). `main`'s `cache` was applied and became Ready (both pods on
revision `cache-578546696d`, `64Mi`), then the scenario's file over it:

- `cache-0` stayed on `cache-578546696d`; `cache-1` went to `cache-67fc579967`, was `OOMKilled` and entered
  `CrashLoopBackOff`; the StatefulSet showed `updatedReplicas` 1 with the partition set;
- the limit raised to `72Mi` and `cache-1` deleted (the forced rollback of the `statefulset-oom` README): `cache-1`
  came back Ready on a third revision, `cache-5fbcc6bfbb`, while `cache-0` stayed on `cache-578546696d`, and both
  `currentRevision` and `updateRevision` of the StatefulSet differed.

Not checked: how the operator's rollout evaluator and the source mapping treat the `partition` field, and the
request's phase.

## Expected outcome

The same pull request as `statefulset-oom` (`SetContainerMemoryLimit` on `cache`), merged, but `cache-0` never takes
the new limit. The phase and reason are in [MATRIX.md](../MATRIX.md), row 9.

## Verify

```bash
make kind-up && make kind-wait
make scenario-statefulset-partition CLUSTER=kind
kubectl -n demo get pods -l app.kubernetes.io/name=cache -L controller-revision-hash
make scenario-reset CLUSTER=kind
```

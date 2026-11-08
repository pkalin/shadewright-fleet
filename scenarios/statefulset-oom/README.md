# StatefulSet OOM kill

`make scenario-statefulset-oom CLUSTER=kind|lab` replaces `apps/demo/cache-statefulset.yaml`.

**Status: run on the lab on 2026-11-08 (v0.3.0-rc.5), up to an open pull request.** The Incident and the pull request
were seen (below). The pull request was not merged, so the rollout after a merge and the manual pod delete are not
checked. The diagnosis stays `planned` in `expected.yaml`: it runs, but misses facts (below).

## What breaks

`cache` is podinfo run as a StatefulSet of two pods (`cache-0`, `cache-1`) behind the headless Service `cache`. The
scenario adds `--stress-memory=36` (podinfo loads 36 MB into memory) and lowers the memory limit to `48Mi`, as the
[`oom`](../oom/README.md) scenario does for `web`; that scenario measured about 54Mi held by the container. The kernel
kills it (`OOMKilled`, exit code 137), the kubelet restarts it, and it ends in `CrashLoopBackOff`. As in `oom`, the
scenario also mounts an `emptyDir` at `/tmp`, because the root filesystem is read-only and podinfo writes its load
file there.

The memory limit is the field the action patches, so a reset changes it back to `64Mi` and an open request becomes
`Superseded`. The broken object is a plain manifest (ADR-0012).

## Rolling update with a stuck pod

A StatefulSet with the default `RollingUpdate` strategy replaces pods one at a time from the highest ordinal down and
waits for each to be Running and Ready before the next. So when Flux applies the broken template:

- `cache-1` is replaced first, is OOMKilled and never becomes Ready. `cache-0` is not touched and keeps serving on the
  old template (the same as the old pod of `oom`, but per ordinal).
- The fixing pull request, once merged, changes the template back. Kubernetes documents a known issue here: the
  controller keeps waiting for the broken pod to become Ready before it replaces it with the fixed one, so after the
  merge `cache-1` must be deleted by a person (`kubectl -n demo delete pod cache-1`); the recreated pod uses the
  fixed template. See "Forced rollback" in the Kubernetes StatefulSet documentation. This is expected behaviour of
  Kubernetes, not a failure of the agent, and Shadewright has no action for it (the catalog changes manifests in
  Git only). Whether the deletion is needed on the Kubernetes version of the lab is **planned** to be checked: the
  2026-11-08 run did not merge the pull request.
- That is why there are two replicas: with one, the whole workload is down, and the ordering is not visible.

## Decisions on the open questions of pkalin/shadewright#269

- **Storage: none.** No `volumeClaimTemplates`, only `emptyDir` volumes. Nothing in the demo keeps data, so there is
  no PersistentVolumeClaim, no disk cost on the lab, and the restricted profile needs no `fsGroup` (the `emptyDir`
  is writable by the non-root user). The cost is that this does not exercise a StatefulSet with a claim; that is out
  of scope for the memory action.
- **Restricted profile.** The same settings as `web`: non-root user 100, `seccompProfile: RuntimeDefault`, no
  privilege escalation, read-only root filesystem, all capabilities dropped, pinned image digest, probes, requests and
  limits, `automountServiceAccountToken: false`, its own ServiceAccount.
- **Headless Service.** `cache` with `clusterIP: None`, named by `serviceName`. The existing NetworkPolicies
  (`allow-http-in-namespace` on 9898, `allow-prometheus-scrape` on 9797 for pods labelled `part-of: demo`) already
  cover the pods; no new policy.
- **Where the manifests live.** The healthy StatefulSet, Service and ServiceAccount are on `main` in `apps/demo/`,
  listed in `apps/demo/kustomization.yaml`, one object per file. They must be on `main`: the operator opens its pull
  request against the file on `main`, and source mapping needs the object in the tree Flux applies (ADR-0012). The
  scenario only replaces `cache-statefulset.yaml`, so it needs no `kustomization.yaml` of its own. The scenario
  folder is `statefulset-oom` (the issue text says `oom-statefulset`).

## Observed on the lab (2026-11-08, v0.3.0-rc.5)

Times UTC, after [pkalin/shadewright-fleet#52](https://github.com/pkalin/shadewright-fleet/pull/52) added
`apps/demo/*-statefulset.yaml` to the policy `demo-memory`:

- An `OOMKilled` Incident on StatefulSet `demo/cache` at about 08:24:44.
- [pkalin/shadewright-fleet#54](https://github.com/pkalin/shadewright-fleet/pull/54) (the `cache` container, 48Mi to
  72Mi, +50%) at 08:27:39. Two more Incidents (`BackOff`, `Unhealthy`) for the same subject did not make more pull
  requests ([pkalin/shadewright#432](https://github.com/pkalin/shadewright/issues/432)).
- Not merged, so the manual pod delete after a merge is still not checked.
- Real-model replay evaluation on rc.5 (https://shadewright.io/evaluation/): 0 of 5 runs with all facts. The
  diagnosis never names `cache-0`, and often leaves out the metric names.

## Expected incident

`OOMKilled` from the container status of `cache-1`, with the StatefulSet `demo/cache` as the subject. The collector
follows a pod's controller reference to a ReplicaSet or a StatefulSet and checks each hop through the API reader
(`internal/analyzer/collector/owners.go`, `podSubject` and the owner lookup; `TestStatefulSetPod` in `owners_test.go`
covers a StatefulSet pod). Like `oom`, `BackOff` and `Unhealthy` Warning events for the restarts are expected as well,
for the same subject. The analyzer watches `demo`, which holds this workload.

## Expected diagnosis (planned)

The diagnosis step runs, but not every fact below is observed (see above). It should name `OOMKilled` from the container status of `cache-1`, the
restart count, that only the highest ordinal is affected, and the memory working set from Prometheus near the 48Mi
limit. The Prometheus pod templates resolve StatefulSet pods through owner references
(`internal/providers/metrics/prometheus/doc.go`), but `MetricsSource` is not wired into the analyzer yet.

## Expected outcome

A pull request with `SetContainerMemoryLimit` on container `cache`, raising the limit within the policy's bounds
(`64Mi` to `128Mi`, as in `oom`: the container needs about 54Mi). It changes only
`spec.template.spec.containers[name=cache].resources.limits.memory` in `apps/demo/cache-statefulset.yaml`.
The operator side, checked against the code in `pkalin/shadewright`:

- the action's target kinds include `apps/v1` `StatefulSet` (`internal/policy/decide.go`, the catalog table);
- `FieldFor` accepts a StatefulSet and returns the same field path as for a Deployment (`internal/gitops/sourcemap/field.go`,
  `TestFieldFor` covers both);
- the patcher and the schema check accept a StatefulSet (`internal/gitops/patch/patch.go`,
  `internal/gitops/semdiff/validate.go`).

The 2026-11-08 run showed the pull request step on this repository's StatefulSet manifest. The merge and the
rollout are not seen yet.

## Restricted profile

Nothing in the Pod Security "restricted" profile is broken. The deliberate changes from `main` are the extra
`--stress-memory=36` argument, the writable `/tmp` volume it needs and the lower memory limit.

## Verify

```bash
make kind-up && make kind-wait
make scenario-statefulset-oom CLUSTER=kind
kubectl -n demo get pods -l app.kubernetes.io/name=cache
kubectl -n demo get pods -o jsonpath='{.items[*].status.containerStatuses[*].lastState.terminated.reason}'
make scenario-reset CLUSTER=kind
```

# OOM leak

`make scenario-oom-leak CLUSTER=kind|lab` replaces `apps/demo/web-deployment.yaml` and `apps/demo/kustomization.yaml`,
and adds `apps/demo/loadgen-deployment.yaml`.

Where [`oom`](../oom/README.md) is one allocation at start that a higher limit fixes for good, this is a leak: memory
grows at a steady rate, so a higher limit only moves the kill later. Row 2 of the [matrix](../MATRIX.md) uses it for a
request that ends `Failed` because the kill returns after the rollout.

## What breaks

- `web-deployment.yaml` is the one on `main` (limit `64Mi`, no `--stress-memory`) with one change: the `data` volume
  is an `emptyDir` with `medium: Memory` and `sizeLimit: 128Mi`, above the container limit. Pages of a memory-backed
  volume are charged to the memory cgroup of the container that wrote them, so they count against its limit.
- `loadgen` posts a different 64 KiB body to `POST /store` of `web` (podinfo writes one file per distinct body to
  `/data`) every 0.3 s plus the time of the `curl`. Each body starts with a counter and the time, so no two are equal.
  64 KiB is far below the 10 MiB request limit of podinfo. The load generator has the hardening of the worker, as in
  `keda-at-ceiling`; the demo NetworkPolicies already allow its traffic.

The field the action patches is `resources.limits.memory`. It is `64Mi` on `main` too, so a reset does not change it,
but the file differs (the volume) and an open request becomes `Superseded` all the same.

## Observed on Kind (2026-11-13)

Kind v0.33.0 with its default node image (cgroup v2, containerd), one node, no Flux and no agent: the scenario's
`apps/demo` applied with `kubectl`, a throwaway cluster that was deleted afterwards. Times are from the
container status and the pod's start time.

Does the kernel kill the container, or does the kubelet evict the pod, when the volume fills the memory limit? **The
kernel kills the container**: `lastState.terminated.reason` is `OOMKilled`, exit code 137, the pod is not evicted and
stays `Running` with a restart count. The page's alternative (a separate image that grows by itself) is not needed.

Final configuration (`sleep 0.3`):

| What | Time |
| --- | --- |
| Pod start to the first kill, limit `64Mi` | 2 min 25 s |
| Limit raised by hand to `96Mi` (a new pod with an empty volume) to the second kill | 5 min 58 s |

Run before the rate was tuned (`sleep 0.5`, about 130 KB/s): the first kill came about 4 min 40 s after the start
(limit 64Mi) and the second 8 min 37 s after the pod start at 96Mi, which is too close to 10 minutes.

Other things seen, all in the first run:

- The tmpfs is sized to the limit: `df /data` showed 65536 KiB at a 64Mi limit.
- The container held about 21 to 28 MiB of anonymous memory (podinfo with the request bodies) next to the volume's
  pages, so the kill comes when the volume holds about 35 MiB at 64Mi and about 65 MiB at 96Mi, not at the limit's
  size.
- A restart of the container inside the same pod does not empty the volume: it still held 36 MiB after the first
  kill, and the container was killed again about 30 s later (`BackOff`, `CrashLoopBackOff`). Only a new pod, which the
  pull request's rollout makes, starts empty. That is why the second kill is timed from a new pod.
- Memory growth in the second run was steady (the cgroup's `memory.current` and the volume's size grew in a straight
  line).

The rate is the one Kind gave with this loadgen. The lab's nodes have other CPU and `curl` speed, so check on the lab
that the second kill still comes later than a delivery wait of a few minutes and inside 10 minutes.

## Expected diagnosis (planned)

`OOMKilled` from the container status, the working set growing in a straight line (Prometheus through `MetricsSource`,
not wired into the analyzer yet), and that the data volume is memory-backed. See `expected.yaml`.

## Expected outcome (planned)

A pull request with `SetContainerMemoryLimit` on container `web`, within the `demo-memory` policy (at most +50% per
step: 64Mi to 96Mi). After the merge and the rollout the kill returns about 6 minutes after the new pod starts, so
the request is expected to end `Failed` once the kill is seen after the rollout (matrix row 2; the names come from a
proposed ADR and are not in the operator yet). The revert is row 10. Not run with an agent.

## Restricted profile

Nothing in the Pod Security "restricted" profile is broken. The deliberate changes from `main` are the memory-backed
`data` volume and the `loadgen` Deployment.

## Verify

```bash
make kind-up && make kind-wait
make scenario-oom-leak CLUSTER=kind
kubectl -n demo get pods -w
kubectl -n demo get pods -l app.kubernetes.io/name=web -o jsonpath='{.items[*].status.containerStatuses[*].lastState.terminated.reason}'
make scenario-reset CLUSTER=kind
```

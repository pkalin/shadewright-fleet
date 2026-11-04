# OOM kill

`make scenario-oom CLUSTER=kind|lab` replaces `apps/demo/web-deployment.yaml`.

## What breaks

The `web` container is started with `--stress-memory=36` (podinfo loads 36 MB into memory, the scenario's load) and
its memory limit is `48Mi`. Measured on Kind (cgroup v2), the container holds about 54Mi of anonymous memory once the
load is in, so the limit is too low. The kernel kills it (`OOMKilled`, exit code 137) within seconds of starting, the
kubelet restarts it, and it is killed again, so the pod ends in `CrashLoopBackOff` with a growing restart count. The
old pod keeps serving during the rollout. Nothing else is needed to produce the load: no load generator runs. The
symptom shows within two minutes of Flux applying the commit.

podinfo writes a sparse file of that size to `/tmp` and reads it back into the heap, which is the memory it holds. The
image runs with a read-only root filesystem, so without a writable `/tmp` the allocation fails with a logged error and
no memory is used (the container then runs fine under any limit). The scenario therefore also adds an `emptyDir`
volume `tmp` mounted at `/tmp`. The file is sparse, so it takes no disk and no memory of its own.

The memory limit is the field the action patches, so a reset changes it back to `64Mi` and an open request becomes
`Superseded`. The memory request (`32Mi`) is unchanged. The broken object is a plain manifest (ADR-0012).

## Expected diagnosis

The diagnosis names `OOMKilled` from the container status (`lastState.terminated.reason`), not from an event reason
(design 3.1: there is no event with that reason), the restart count, and the memory working set from Prometheus
(`container_memory_working_set_bytes`, scraped from the kubelet's cAdvisor), which sits at the 48Mi limit.

## Expected outcome

A pull request with `SetContainerMemoryLimit` on container `web`, raising the limit within the policy's bounds. It
changes only `resources.limits.memory` in `apps/demo/web-deployment.yaml`. This is the positive stage 2 case. The
bounds in `expected.yaml` (`64Mi` to `128Mi`) are what a sensible policy for this lab allows: the container needs
about 54Mi, so anything below `64Mi` would be killed again or leave no headroom, and the baseline value of `64Mi` is
a 33% increase, within the default `maxIncreasePercent` of 50. The policy that applies them lives in the operator
repository, not here.

## Restricted profile

Nothing in the Pod Security "restricted" profile is broken. The deliberate changes from `main` are the extra
`--stress-memory=36` argument, the writable `/tmp` volume it needs and the lower memory limit.

## Verify

```bash
make kind-up && make kind-wait
make scenario-oom CLUSTER=kind
kubectl -n demo get pods
kubectl -n demo get pods -o jsonpath='{.items[*].status.containerStatuses[*].lastState.terminated.reason}'
make scenario-reset CLUSTER=kind
```

# Slowstart OOM kill

`make scenario-slowstart-oom CLUSTER=kind|lab` replaces `apps/slowstart/slowstart-deployment.yaml`. It needs
the `slowstart` workload (`apps/slowstart/`, [#105](https://github.com/pkalin/shadewright-fleet/pull/105)) on `main`.

It is the `oom` scenario for the workload of rows 13 and 14 of the matrix: `slowstart` has no `startupProbe`, so its
readiness failure at every start is a real `Unhealthy` event, which `web` no longer gives since #101.

## What breaks

The container sleeps 20 seconds, then starts podinfo with `--stress-memory=36` (the same load as `oom`) under a `48Mi`
limit, and the scenario adds the writable `/tmp` volume the load needs (the root filesystem is read-only). The kernel
kills the container (`OOMKilled`, exit code 137) a few seconds after podinfo starts. The kubelet restarts it, the
container sleeps again, and the readiness probe (every 3 seconds from the start) fails with connection refused for
about 20 seconds before the next kill. So each cycle gives, in this order, the kill, the kubelet's back-off, and
`Readiness probe failed` events for the restarted container. The pod ends in `CrashLoopBackOff`.

The liveness probe starts after 60 seconds, so it never fires: the container is killed about 25 seconds into each cycle.

The memory limit is the field an action would patch. The policy `demo-memory` lists `apps/demo/*-deployment.yaml` only,
so a proposal for this file is `Denied`; matrix row 13 counts Incidents and requests and does not need a pull request.

## Observed

On a local Kind cluster (node image v1.36.4, no Flux, no agent) with the scenario's file and the `slowstart`
ServiceAccount applied by hand, on 2026-11-16: after about 100 seconds the pod was in `CrashLoopBackOff` with 2
restarts and `lastState.terminated.reason` `OOMKilled`. The events had a Warning `BackOff` ("Back-off restarting failed
container") and a Warning `Unhealthy` with `Readiness probe failed: ... dial tcp ...:9898: connect: connection refused`
(count 23). Not run on the lab and not run with the agent.

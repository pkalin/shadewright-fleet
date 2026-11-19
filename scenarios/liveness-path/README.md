# Liveness probe path

`make scenario-liveness-path CLUSTER=kind|lab` replaces `apps/demo/web-deployment.yaml`.

This is the scenario for the read tools ([pkalin/shadewright#926](https://github.com/pkalin/shadewright/issues/926)).
In the lab run of `v0.6.0-rc.1` no analysis called a tool (0 in 27): every other scenario is answered from the first
context, and only an escalated analysis is offered tools. This one is built so that the deciding fact is not in the
first context. Whether it escalates is not decided by the manifest: see "What escalates" below, which has two
prerequisites that are not in this folder.

## What breaks

The `livenessProbe` of the `web` container asks for `/health`. podinfo serves `/healthz` (the path `main` uses) and is
not expected to serve `/health`, so the probe fails with an HTTP error status, and after three failures (about 30
seconds, the probe starts once the `startupProbe` has passed) the kubelet kills and restarts the container. The restart
count grows and the pod ends in `CrashLoopBackOff`. The old pod keeps serving during the rollout.

The broken object is a plain manifest that the `apps` Kustomization applies, so source mapping (ADR-0012) maps the
Deployment to `apps/demo/web-deployment.yaml`.

## Why the first context does not hold the cause

Read in the operator at `origin/main` on 2026-11-19 (`internal/incidentcontext`): the first context is the Incident
(subject, reason, symptom, counts), the status and owners of the Deployment and its pods (conditions, restarts, container
states, the memory limits of the template and of each pod), at most two log excerpts, the approved metric templates and
the policy bounds. It holds no probe settings, no environment, no earlier ReplicaSet and no events other than the one
that opened the Incident. The kubelet's note names the status code of the failed probe ("Liveness probe failed: HTTP
probe failed with statuscode: ..."), not the path. So the path is in one place only, the Deployment spec, and
`get_resource` on the Deployment returns it (the tool leaves out annotations, managed fields and literal environment
values, and keeps probes).

Not chosen from the three candidates of the issue, and why:

- A missing Secret or ConfigMap (`check_missing_reference`): the existing `missing-secret` scenario shows that the
  Incident's own symptom already says `secret "web-credentials" not found`, so the first context holds the cause and the
  model needs no tool. The tool would be offered only on escalation, and nothing in this case escalates.
- A log excerpt cut by size (`get_pod_logs`): a cut log is a label on the block, never an escalation signal (a section
  cut to its own bound; only a cut of the whole context is one, and the section bounds add up to less than the total
  bound, so it does not happen with the defaults). The tool reads the same newest lines through the same bounds, so it
  rarely adds anything the context lacks.
- A neighbouring object (`get_resource`, `list_events`): this is the chosen candidate. The probe path is such a fact, and
  the eval case `probe-path` of the operator (`test/eval/testdata/escalation/probe-path`) models the same fact.

## What escalates

The model is offered read tools only when the analysis escalates, and the loop escalates on three deterministic signals
and nothing else (operator `internal/analysis/loop.go`, design 3.3): the context was cut to its total bound, a source
that is configured could not be fetched, or the triage reply was invalid twice. The first cannot happen with the
default bounds and the third depends on the model. That leaves a failed source, which no manifest in `demo` causes: it
is a fault of the cluster read, the log read or the metrics source. Two prerequisites follow, neither is in this
scenario:

1. A failed source while the context is built. The planned way is to take Prometheus down for the analysis
   (`kubectl -n prometheus scale deployment/prometheus-server --replicas=0`, back with `--replicas=1` afterwards). Every
   metric template then fails, the metrics block says "could not fetch" and the context escalates. Prometheus is
   installed by a `HelmRelease` that sets no drift detection, so the change is expected to hold until the next Helm
   upgrade, not until the next Flux reconcile. The Deployment name and that behaviour were not checked on a cluster.
2. An escalation model. The lab has none today (`infrastructure/shadewright-lab/` sets only the triage model; the
   operator issue #80 is the second deployment). Without it an escalation is handed off with
   `EscalationNotConfigured` before any tool is offered. [NEEDS CLARIFICATION: which escalation model each provider
   gets, and who adds the second deployment. Foundry needs `inferenceAPI: Responses` for a model that refuses function
   tools on chat completions ([pkalin/shadewright#501](https://github.com/pkalin/shadewright/issues/501)). This
   pull request does not change `infrastructure/`.]

## Expected path (planned, not observed)

1. The kubelet writes the Warning event `Unhealthy` ("Liveness probe failed") for the `web` pod. It is a consequence
   event, so the collector holds it for 2 minutes and emits it only if the container has not recovered; `BackOff` may
   open the Incident first. One Incident for `demo/web`.
2. With Prometheus down the context has a failed source: the analysis escalates, one call to the escalation model with
   the read tools (`escalated: true` in the analysis record).
3. The model calls `get_resource` for the Deployment `demo/web` (at least one call; `list_events` and `get_pod_logs`
   are acceptable extras) and reads the probe path `/health` in the result. The analysis record has `toolCalls` of 1 or
   more.
4. Outcome: no proposal. No catalog action changes a probe, so the analysis ends without a plan (`NoProposal` or
   `MissingData`, a hand-off with the diagnosis that names the path) and a person is notified; if a request is created
   it ends `NeedsIntervention`. A memory proposal is wrong whatever its value (nothing points at memory).

Nothing here forces the model to call a tool. The path is not in the first context, so a model that answers without
reading can only hand off; a run with `toolCalls` of 0 is a result to record, not a pass.

## Before the run

The row is **not tested** unless all of these hold; write down what was seen:

- Prometheus is down and the escalation model is configured (the two prerequisites above).
- The first context does not hold the path. After the switch, `kubectl -n demo logs deploy/web` and the same with
  `--previous` must not contain `/health`. If podinfo logs the request path, the context could hold it and the model
  needs no tool: the row is not tested.

## Restricted profile

Nothing is loosened. The only change from `main` is the probe path. The image is the pinned digest of `main`, the
resource requests and limits are unchanged, and nothing outside the `demo` namespace is added.

## Verify

```bash
make kind-up && make kind-wait
make scenario-liveness-path CLUSTER=kind
kubectl -n demo get pods -l app.kubernetes.io/name=web
kubectl -n demo get events --field-selector type=Warning
make scenario-reset CLUSTER=kind
```

On Kind there is no agent, so this shows the symptom only: restarts of the `web` pod and `Liveness probe failed` events.

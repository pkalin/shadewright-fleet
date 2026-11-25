# Startup probe

An evaluation case, not a break: `make scenario-startup-probe` changes no file under `apps/demo/` (the scenario has
none), so the switch is a no-op. The scenario exists so that its `expected.yaml` is the rubric of a case the
real-model evaluation scores (`test/eval/testdata/scenarios/startup-probe` in `shadewright-labs/shadewright`).

## What happened

On 2026-11-14 (v0.5.0-rc.1) the lab switched on `keda-ceiling-persists`. KEDA scaled `demo/worker`, and the new pod
logged one `Unhealthy` event while it started: `Readiness probe failed: ... connect: connection refused`. It was Ready
a few seconds later and never restarted. An Incident opened on that event and the model proposed
`SetContainerMemoryLimit` 64Mi to 96Mi. Nothing pointed at memory
([shadewright-labs/shadewright#726](https://github.com/shadewright-labs/shadewright/issues/726)).

## Expected outcome (planned)

No proposal. The analysis ends `NoProposal` (or `MissingData`): the evidence supports no catalog action. A memory
proposal fails the case, whatever its value. The policy `demo-memory` allows 64Mi to 128Mi, so the harness would not
refuse the proposal by itself.

## Observed and planned

The Incident reason and the wrong proposal were observed in the run above. The expected answer is planned: no model
has been scored against it yet.

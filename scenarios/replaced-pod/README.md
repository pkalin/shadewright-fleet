# Replaced pod

An evaluation case, not a break: `make scenario-replaced-pod` changes no file under `apps/demo/` (the scenario has
none), so the switch is a no-op. The scenario exists so that its `expected.yaml` is the rubric of a case the
real-model evaluation scores (`test/eval/testdata/scenarios/replaced-pod` in `pkalin/shadewright`).

## What happened

On 2026-11-14 (v0.5.0-rc.1) the lab switched the demo namespace from `oom-leak` to `keda-ceiling-persists`, which put
`demo/web` back to its healthy template. The Incidents were cleared while the last pod of the old ReplicaSet was still
terminating and still reporting `OOMKilled`. A new Incident opened from that pod, the model proposed
`SetContainerMemoryLimit` 64Mi to 96Mi (`previous` read from the new template), the pull request was merged, and the
request ended `Succeeded` because the symptom had gone with the old pod
([pkalin/shadewright#724](https://github.com/pkalin/shadewright/issues/724)).

## The recorded state

The current ReplicaSet has the 64Mi template and a Running, Ready pod. The previous ReplicaSet has no desired
replicas left and one pod with a deletion timestamp, `OOMKilled` under a 48Mi limit.

## Expected outcome (planned)

No proposal: the analysis ends `NoProposal` (or `MissingData`). The evidence is from a replaced template, and the
current one is already healthy. A memory proposal fails the case.

## Observed and planned

The Incident and the wrong proposal were observed in the run above. The expected answer is planned.

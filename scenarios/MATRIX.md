# Scenario matrix

The scenarios Shadewright v0.6.0 is checked against: for each, the setup, the phase and reason the request is
expected to end with, where it runs, and whether the scenario exists. It is a plan, not a record: nothing here is
**observed** unless a row says so and names the run (see "Observed and planned" in the [README](README.md)).
Tracked in [shadewright#672](https://github.com/pkalin/shadewright/issues/672).

## Names on this page

Every phase, reason and condition on this page was read in the operator at `origin/main` of `pkalin/shadewright` on
2026-11-14: `api/v1alpha1/remediationrequest_types.go`, `internal/controller/phases.go`,
[ADR-0030](https://github.com/pkalin/shadewright/blob/main/docs/adr/0030-merge-receipt-and-verification-outcomes.md),
`docs/request-lifecycle.md` and `docs/troubleshooting.md`. The phases after the merge (`WaitingForDelivery`,
`Verifying`, `Succeeded`, `Failed`, `Inconclusive`) and the conditions `Delivered`, `Configured`, `RolledOut`,
`Cleared` and `Verified` are built. They run only when the executor has `--verify-outcomes` on (chart value
`executor.verification.enabled`, off by default). With it off, a request still in `Merged` stays there (`RolledOut`
reports the rollout), a request found in `WaitingForDelivery` or `Verifying` ends `Inconclusive` with
`VerificationDisabled`, and a stale plan merged by a person ends `Inconclusive` with `StalePlanMerged` once its rollout
check is over. Every row that ends after the merge assumes it is on. `AutoMergeQueued` exists in the API and nothing sets it. `Cancelled` is set by `spec.cancel` (reason `CancelRequested`, built in #289), by a replacement whose handoff did not happen (`HandoffRefused`, `HandoffAborted`, `HintsTurnedOff`) and, once [shadewright#816](https://github.com/pkalin/shadewright/pull/816) is merged, by the executor for a request whose Incident was folded into its cause or is gone before its pull request opened (`IncidentFolded`, `IncidentGone`). On `origin/main` of the operator on 2026-11-16 (`f102c51a`) the last two are not in the code or in `docs/troubleshooting.md`; they are in the diff of #816 and in ADR-0039 points 21 and 22. Rows 13 to 17 read ADR-0039, `docs/design/3-observation-and-deduplication.md` and `test/eval/grouping_test.go` at that commit.

Where it runs:

- Kind: the symptom and the Incident only. The Kind cluster has no agent identity, so no pull request is opened
  there (README, "Kind").
- Lab: the AKS lab with the agent, a model and the GitHub App. Every row that needs a pull request runs here.
- Second cluster: see below.

## Verification rows

| # | Row | Setup | Expected phase | Expected reason | Runs on | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Limit too low, raised within policy | `make scenario-oom CLUSTER=lab`; merge the pull request (48Mi to 64Mi, inside the `demo-memory` bounds of 64Mi to 128Mi) | `Succeeded` after `Merged`, `WaitingForDelivery` and `Verifying`, once rolled out, configured and a quiet window of at least 10 minutes plus the node grace held (the memory minimum for `stableFor`) | condition `Verified=True`, `Cleared=True` with reason `NoRecurrence` | Lab | exists (`oom`); **observed** twice on the lab with verification on: chart `0.5.0-rc.1` on 2026-11-14 ([#70](https://github.com/pkalin/shadewright-fleet/pull/70), merged 12:33:15, `Verifying` 12:34:19, `Succeeded` 12:46:04, `Cleared=True`/`NoRecurrence`) and rc.2 (chart digest pinned in #81) the same day ([#82](https://github.com/pkalin/shadewright-fleet/pull/82), merged 16:24:26, `Verifying` 16:25:42, `Succeeded` 16:37:25). The two sibling requests (one OOM opens three Incidents: `OOMKilled`, `Unhealthy`, `BackOff`) differed: on rc.1 they ended `NeedsIntervention`/`ValueMismatch` 11 s after the merge ([shadewright#719](https://github.com/pkalin/shadewright/issues/719)); on rc.2 they stayed `Queued`/`TargetLocked` during the verification and ended `Superseded` with `AnotherRequestSucceeded`, and all three Incidents were `Resolved` Also observed with the Anthropic provider and the triage model `claude-haiku-5-5`, chart `0.5.0-rc.3`, 2026-11-14 ([#92](https://github.com/pkalin/shadewright-fleet/pull/92), 48Mi to 64Mi): `Succeeded` with `Verified=True`/`NoRecurrence` at 22:33:25 UTC. Observed again on chart `0.5.0-rc.4` on 2026-11-15 ([#99](https://github.com/pkalin/shadewright-fleet/pull/99), 48Mi to 64Mi, merged 02:13:40): `Succeeded` with `Verified=True/NoRecurrence` at 02:26:27 UTC. |
| 2 | Leak: the limit is raised, the kill returns later | `oom-leak`: `web` with a memory-backed volume that a load Deployment fills at a steady rate (see below) | `Failed`, at once when the kill is seen after the rollout | `OOMKilled`, from the verifier's report. The analyzer then proposes a revert (row 10) | Lab | exists (`oom-leak`); the kill was settled on Kind (see below); **observed** on the lab with chart `0.5.0-rc.1` on 2026-11-14: [#71](https://github.com/pkalin/shadewright-fleet/pull/71) merged at 13:46, the request ended `Failed` with `OOMKilled` at 13:55:07 |
| 3 | Merged, but the Kustomization fails to apply | `delivery-blocked`: the `oom` files plus a `ValidatingAdmissionPolicy` and its binding that refuse a `web` memory limit above 60Mi (see below) | `Merged`, then `WaitingForDelivery`, then `Failed` at the end of the delivery window (one hour after the merge) | `DeliveryFailed`, because Flux failed on exactly the merge commit; the condition `RolledOut=False` with `DeliveryNotObserved` is what the code sets today | Lab | exists (`delivery-blocked`); the admission refusal was checked by hand on Kind, not through Flux or the agent |
| 4 | Applied, but the pods keep the old value | `rollout-blocked`: the `oom` files plus a `LimitRange` whose container `max` memory is 56Mi (see below) | `Failed` at the timeout (21 minutes from the applied revision with the defaults), never `Succeeded` | `RolloutStuck`, because `RolledOut` is False (set today 10 minutes after the revision was applied) | Lab | exists (`rollout-blocked`); the LimitRange refusal was checked by hand on Kind; **observed** on the lab with chart `0.5.0-rc.1` on 2026-11-14: [#79](https://github.com/pkalin/shadewright-fleet/pull/79) merged 15:51:52, `RolledOut=False`/`RolloutStuck` at 16:03:14 (10 minutes after the applied revision), `Failed` with `RolloutStuck` at 16:14:18 (21 minutes). The automatic revert (64Mi back to 48Mi) was `Denied` with `BelowMinimum` (`min: 64Mi`) |
| 5 | The incident stops before the pull request merges | `keda-load-burst`: `keda-at-ceiling` with a load that ends by itself after a few minutes; leave the pull request unmerged (see below) | none ends it: the request stays `AwaitingApproval` (`Approved=False`, reason `WaitingForReview`) with its pull request open, and holds the target lock, until a person merges or closes the pull request. The deadline of 30 minutes (`Expired`, `PullRequestDeadline`) covers only the wait for the pull request to be opened and is cleared when it opens; no code reads the Incident's end in this phase. The issue's wording "ends without a merge, reason recorded" is therefore not met at any deadline, only when a person closes it (row 6) | `WaitingForReview` while it waits; no ending reason exists | Lab | new scenario needed; the outcome is the code's today, whether it should be different is open (see "Open points") |
| 6 | Pull request closed unmerged by the reviewer | `make scenario-oom CLUSTER=lab`, then close the pull request on GitHub without merging | `NeedsIntervention`, terminal (decided 2026-11-13: a person rejecting a proposal is a signal the circuit breaker counts as a failure). No second pull request ([shadewright#643](https://github.com/pkalin/shadewright/issues/643), fixed in #674): a request queued behind it for the same target and field ends `Superseded` with reason `AnotherRequestClosed` and opens none | `ChangeRequestClosed` (on the closed request), `AnotherRequestClosed` (on a queued one) | Lab | exists (`oom`); the "no second pull request" half was fixed in [#674](https://github.com/pkalin/shadewright/pull/674) (merged 2026-11-13); the queued request needs a second Incident for the same target and field, as on 2026-11-10 (#643); **observed** on the lab with chart `0.5.0-rc.1` on 2026-11-14: [#75](https://github.com/pkalin/shadewright-fleet/pull/75) closed at 14:24:00, `NeedsIntervention`/`ChangeRequestClosed` at 14:24:53, no second pull request in 12 minutes, the siblings `Superseded` |
| 7 | Data missing during the window | no scenario: two procedures, a deleted or recreated target, and a stopped verifier (see below) | `Inconclusive` in both, never `Succeeded` and never `Failed` | `TargetGone` or `TargetReplaced` at once; `StaleReport` at the timeout when the verifier is stopped | Lab | new scenario needed (documented manual steps) Observed with `claude-haiku-5-5` through the Anthropic provider, chart `0.5.0-rc.3`: a target deleted during verification ([#94](https://github.com/pkalin/shadewright-fleet/pull/94), 2026-11-14) ended `Inconclusive` with `TargetGone`; a verifier stopped during verification ([#95](https://github.com/pkalin/shadewright-fleet/pull/95)) ended `Inconclusive` with `StaleReport` at 00:05:00 on 2026-11-15. |
| 8 | KEDA ceiling raised, still at the ceiling | `keda-ceiling-persists`: `keda-at-ceiling` with a load of about 25 requests per second, so the trigger asks for 5 replicas against a ceiling of 3 | `Inconclusive` once rolled out and configured held for `stableFor` (3 minutes); never `Succeeded`, and not `Failed` on the symptom | `CheckNotAvailable` on `Verified` and `Cleared` (`RolledOut=Unknown` with `KindNotChecked`) | Lab | exists (`keda-ceiling-persists`); **observed** on the lab with chart `0.5.0-rc.1` on 2026-11-14: [#78](https://github.com/pkalin/shadewright-fleet/pull/78) (`maxReplicaCount` 2 to 3) merged 15:38:37, `Verifying` 15:39:32, `Inconclusive` at 15:42:36; the HPA showed about 6.1 per replica against a target of 5 at 2 of 2 replicas; the exact request rate was not measured Observed again with `claude-haiku-5-5` through the Anthropic provider, chart `0.5.0-rc.3`, 2026-11-14 ([#93](https://github.com/pkalin/shadewright-fleet/pull/93), `AdjustKedaMaxReplicas` 2 to 3, merged 23:14:48): `Inconclusive` at 23:18:50 UTC with `RolledOut=Unknown` (`KindNotChecked`) and `Cleared` and `Verified` `Unknown` with reason `ClearingNotChecked`, not `CheckNotAvailable`: this request did not name the check `QueueBacklogDecreasing`, and the operator records `CheckNotAvailable` only for a request that names it. Both end `Inconclusive`, as the row expects. |
| 9 | Partitioned StatefulSet rollout | `statefulset-partition`: the `statefulset-oom` files with `updateStrategy.rollingUpdate.partition: 1` on `cache`, so only `cache-1` can take the new limit (see below) | not `Succeeded`: `Inconclusive` at the timeout, unless the partition is lowered inside it | `PartialRollout`; `RolledOut` is True with its own reason `RolloutPartitioned` naming the pod left on the old revision | Lab | exists (`statefulset-partition`); the partition was checked by hand on Kind, not through Flux or the agent; the outcome needs ADR-0030 built |
| 10 | Revert after a failed verification (the leak: the limit is raised, the kill returns) | the request of row 2 ends `Failed`; the analyzer then creates a revert request (see below) | the failed request: `Failed`. The revert request, with a policy that allows the decrease: a pull request that needs approval, then `Inconclusive` once merged, rolled out, configured and available for `stableFor`. With the default policy (`maxDecreasePercent` 0): `Denied`, and a person reverts by hand | failed request `OOMKilled` (row 2); revert `NotAvailable` on `Verified` with the allowing policy (observed, see the note below the table), `DecreaseNotAllowed` with the default | Lab | **observed** on the lab with chart `0.5.0-rc.1` on 2026-11-14: revert request created 13:55:09, [#72](https://github.com/pkalin/shadewright-fleet/pull/72) merged 13:56:17, `Inconclusive` at 14:18:41 with `Verified=Unknown`, reason `NotAvailable`. It needs `maxDecreasePercent: 34` on `demo-memory` (set in [#69](https://github.com/pkalin/shadewright-fleet/pull/69)). Row 4 also showed that a revert target below the policy minimum is `Denied` with `BelowMinimum`. Repeated with chart `0.5.0-rc.2` the same day: [#84](https://github.com/pkalin/shadewright-fleet/pull/84) ended `Failed` with `OOMKilled` at 16:58:39, the revert [#86](https://github.com/pkalin/shadewright-fleet/pull/86) (titled `revert: ... back to 64Mi`, its body names the failed request and pull request #84) merged 17:00:53 and ended `Inconclusive` at 17:22:24, again `NotAvailable`. The two requests queued behind #84 kept waiting through its verification and ended `Denied` with `PreviousValueMismatch` when it failed |
| 11 | A plan Shadewright knew was stale is merged by a person | `make scenario-oom CLUSTER=lab`; once the pull request is open, change the policy `demo-memory` (any change of its generation makes the plan stale), then merge the pull request before the executor closes it (the freshness check runs about every five minutes), or with a Git App that may not close pull requests (#199) | `Inconclusive`, never `Succeeded`. With verification on, a failure still ends `Failed` | `StalePlanMerged`; `PlanFresh` stays `False` with the stale reason (`PolicyChanged`) | Lab | new scenario needed; timing dependent; the circuit breaker counts it as no outcome Observed with `claude-haiku-5-5` through the Anthropic provider, chart `0.5.0-rc.4`, 2026-11-15 ([#97](https://github.com/pkalin/shadewright-fleet/pull/97)): the policy `demo-memory` was changed after approval and the pull request merged six seconds later; the request recorded `PlanFresh=False`/`PolicyChanged` at the merge ([shadewright#753](https://github.com/pkalin/shadewright/pull/753)) and ended `Inconclusive` with `Verified=Unknown`/`StalePlanMerged` at 02:03:24 UTC. |
| 12 | The render of the build needs more than the limits | a Kustomization path whose build is over a limit of the render check (4 MiB of input, 4,096 YAML documents, 1,024 objects), the target's file inside it | `NeedsIntervention` | `TooLarge`: on `PolicyAllowed` (`Unknown`, no plan made) for input over the limits, on `PullRequestOpened` or `Approved` (`False`) for a render over 1,024 objects. A build that fits the input limits but needs more memory or CPU than the render's own bounds is refused the same way only after #614 (pull request 711, open on 2026-11-14) | Lab | after #614 for the resource-bound case; the input-limit case exists in the code today; new scenario needed |
| 13 | One fault, one Incident: the kubelet's consequences group under the cause | `make scenario-slowstart-oom CLUSTER=lab` and no more, run **three times** with a clean-up between runs (see "Rows 13 to 17" below). Needs [#105](https://github.com/pkalin/shadewright-fleet/pull/105) merged (the `slowstart` workload). Precondition for each run: an `OOMKilled` in the container status of a `slowstart` pod, a `BackOff` Warning event for it, and a Warning `Unhealthy` event with a note starting `Readiness probe failed` for the restarted container. Without all three the run is **not tested** | one Incident for `demo/slowstart` with `OOMKilled` as its cause (`status.cause` true) and the consequences that did occur in `status.absorbed` (`BackOff` and `Unhealthy`), one analysis, at most one request (it ends `Denied`: the policy `demo-memory` lists `apps/demo/*-deployment.yaml` only) | no phase of its own: the count is the result, not a second Incident for `BackOff` or `Unhealthy`, a second analysis or a second request. ADR-0039 | Lab | exists (`slowstart-oom`, after #105); the operator checks the count in `TestGroupingOOMOpensOneIncident` ([shadewright#795](https://github.com/pkalin/shadewright/issues/795)); the pod showed `OOMKilled`, `BackOff` and the readiness failure on a Kind cluster (2026-11-16), **not run** on the lab since the grouping rule ([shadewright#432](https://github.com/pkalin/shadewright/issues/432) saw the events open on their own). Since [#101](https://github.com/pkalin/shadewright-fleet/pull/101) `web` has a `startupProbe` and gives no readiness `Unhealthy`, which is why this row uses `slowstart` (see below) |
| 14 | A failed readiness or startup probe during a start opens nothing | `startup-probe` changes no file (see its README), and needs [#105](https://github.com/pkalin/shadewright-fleet/pull/105) merged (the `slowstart` workload): delete the `demo/slowstart` pod (or `kubectl -n demo rollout restart deploy/slowstart`) so that a new pod starts. Precondition: the new pod has a Warning event with reason `Unhealthy` whose note starts `Readiness probe failed`, which `slowstart` gives at every start (see "Rows 13 to 17" below). Without it the row is **not tested**, not passed | nothing opens: no Incident, no analysis, no request | none: the collector skips the probe failure as part of the pod's start (design 3.1, shadewright#726), so there is no request to take a phase. ADR-0039 | Lab | exists (`startup-probe`); the operator checks it in `TestGroupingStartupProbeOpensNothing` ([shadewright#795](https://github.com/pkalin/shadewright/issues/795)); the earlier run that opened an Incident on this event (on `worker`) is in the scenario's README; `slowstart` showed the event at every start of four pods on a Kind cluster ([#105](https://github.com/pkalin/shadewright-fleet/pull/105)); **not run** on the lab with the agent |
| 15 | A consequence Incident already open is folded into a later cause | `web` readiness fails with no kill first (`POST /readyz/disable`), then `make scenario-oom CLUSTER=lab` within 15 minutes of that Incident's creation (steps below). Precondition: when the cause Incident appears, the consequence Incident is `Open`, `Analyzing` or `Proposed` and none of its requests has a pull request. Otherwise **not tested** | the consequence Incident ends `Resolved` with condition `Lifecycle` reason `FoldedIntoCause` and `status.foldedInto` naming the cause Incident; the cause stays open | none: an Incident outcome, not a request phase. ADR-0039 points 12 to 15 | Lab | new row; the fold is built ([shadewright#793](https://github.com/pkalin/shadewright/issues/793), merged on `main`); the operator checks it in its envtest suite; **not run** on the lab, and the timing is tight (see below) |
| 16 | The request of a folded Incident is cancelled | the request of row 15's `Unhealthy` Incident is held before its pull request with the kill switch (`spec.paused`), the Incident is folded while it waits, then the pause is released (steps below) | the request ends `Cancelled`; its slot under `maxConcurrentRemediations` is free at once, its target lock after the next read of its branch finds no open pull request of the change; a pull request of its own found open is closed first. No pull request is opened | `IncidentFolded`, on condition `PullRequestOpened` `False` | Lab | needs [shadewright#816](https://github.com/pkalin/shadewright/pull/816), **open** on 2026-11-16; the operator checks it in `internal/controller/pullrequest_test.go`; **not run** on the lab; the pause holds the window open on purpose (steps below) |
| 17 | The request of a deleted Incident is cancelled | delete the Incident of a request right after the request is created, before its pull request opens (steps below) | as row 16 | `IncidentGone`, on condition `PullRequestOpened` `False` (also when the Incident was deleted and opened again under the same name: another UID) | Lab | needs [shadewright#816](https://github.com/pkalin/shadewright/pull/816), **open** on 2026-11-16; **not run** on the lab |
| 18 | The analysis escalates and the model calls a read tool | `liveness-path`: `web` with a liveness probe on `/health`; Prometheus scaled to 0 for the analysis (failed source); an escalation model configured (not in the lab today, see the scenario README) | none of its own: the Incident ends with no proposal (`NoProposal` or `MissingData`); a request, if created, ends `NeedsIntervention` | analysis record: `escalated` true and `toolCalls` of 1 or more (`get_resource` on `demo/web` expected); no memory proposal | Lab | exists (`liveness-path`); **not run**: the Incident reason, the escalation and the tool call are planned, read from the operator's code on 2026-11-19, not observed. Not tested unless Prometheus is down, an escalation model is set and the `web` log does not hold `/health` (README of the scenario). Tracked in [shadewright#926](https://github.com/pkalin/shadewright/issues/926) |

Row 10 expected `RevertApplied` for the revert request, and that was wrong for the leak. The revert restores the limit
that the leak also kills, so the pod is killed again at the restored value and the verification has no clear data: the
request ends `Inconclusive` with `Verified=Unknown` and reason `NotAvailable` (observed 2026-11-14). `RevertApplied`
would fit a revert of a change that did not cause a kill.

Rows 1 and 6 use `oom` unchanged. Row 6 is also the case the `statefulset-oom` and `keda-at-ceiling` scenarios would
give; one is enough. Row 1 for KEDA is not a `Succeeded` row: merging the pull request of `keda-at-ceiling` ends
`Inconclusive` with `CheckNotAvailable` (see row 8). The scenarios of rows 3, 4 and 9 render: the harness checks that with
`make check-scenarios`, and the new objects are plain manifests with one object per file (ADR-0012).

## Rows 13 to 17: preconditions and steps

Incidents and requests are in `shadewright-system`; the kubelet's events are in `demo`. A row counts only when its
precondition was observed and written down. A row whose precondition is not met is **not tested**: say so in the run
record, never "passed". Times in these rows are estimates from the earlier runs, not measured on them. Nothing opening is the expected result of rows 13 (for the consequences) and 14, so a missing
symptom looks the same as a working rule; the precondition is what tells them apart.

### What the `startupProbe` changed (rows 13 and 14)

Since [#101](https://github.com/pkalin/shadewright-fleet/pull/101) `web`, `worker` and `cache` (and every scenario copy
of `web`) have a `startupProbe` on `/readyz` (3 s initial delay, every 2 s, 30 failures allowed). The Kubernetes pod
lifecycle page says: "If a startup probe is configured, Kubernetes does not execute liveness or readiness probes until
the startup probe succeeds" (read on 2026-11-16). So:

- Row 13. In the `oom` scenario `web` is killed within seconds of starting (see its README), before or soon after the
  first startup probe, so a readiness `Unhealthy` is not certain there. The row therefore uses `slowstart`
  ([#105](https://github.com/pkalin/shadewright-fleet/pull/105), scenario `slowstart-oom`): no `startupProbe`, its
  port opens 20 seconds after the container starts, so after each kill the restarted container fails its readiness
  probe with connection refused until the next kill. The order is the kill, the `BackOff` of the kubelet, then
  `Readiness probe failed`. All three are the precondition.
- Row 14. `worker` cannot fail a readiness probe at start any more. Its only `Unhealthy` at start would be a failed
  startup probe, and only if podinfo has not opened its port 3 s after the container starts, which it normally has. So
  the row uses `slowstart` ([#105](https://github.com/pkalin/shadewright-fleet/pull/105)): every pod start logs
  `Readiness probe failed ... connection refused` and the pod then becomes Ready. The precondition still tells a working
  rule from an absent symptom.
- Merge order: #105 before this change. The scenario `slowstart-oom` replaces a file of `apps/slowstart/`, which exists
  on `main` only after #105, so `make check-scenarios` fails here until it is merged.

### Row 13: run three times

Run it three times, each from a clean state (see "Running rows one after another"). One run is one order of arrival of
the kill, the `BackOff` events and the Incident; the grouping rule has to hold for each of them.

1. Delete the requests and Incidents; `make scenario-slowstart-oom CLUSTER=lab`.
2. Precondition, from about two minutes after the switch (the `BackOff` comes with the second restart, the readiness failures with every restart):
   `kubectl -n demo get events --field-selector type=Warning,reason=BackOff -o custom-columns=LAST:.lastTimestamp,POD:.involvedObject.name,NOTE:.message`
   must list a `slowstart-` pod, and
   `kubectl -n demo get pods -l app.kubernetes.io/name=slowstart -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'`
   must show `OOMKilled` for it. Also list `reason=Unhealthy` the same way: a note starting `Readiness probe failed` must be there. The row is **not tested** if any of the three is missing. Events are short-lived: read them in the first minutes.
3. Wait 10 minutes (the analysis came about 2.5 minutes after the symptom in the earlier lab runs, plus the gate).
4. Record, per run:
   - the Incidents of the subject:
     `kubectl -n shadewright-system get incidents -o custom-columns=NAME:.metadata.name,REASON:.spec.reason,PHASE:.status.phase,CAUSE:.status.cause`
     Expected: one Incident for the kill with `CAUSE` true and none with reason `BackOff` or `Unhealthy`;
   - the cause Incident's `status.absorbed` (`kubectl -n shadewright-system get incident <name> -o jsonpath='{.status.absorbed}'`):
     each `reason`, its `count` and `lastSeen`. `BackOff` and `Unhealthy` must be there (the precondition);
   - the requests: `kubectl -n shadewright-system get remediationrequests`: at most one (a proposal for `slowstart` is
     `Denied` by the policy, which is no failure of this row);
   - the analyses taken from the daily budget (the analyzer's budget ConfigMap in `shadewright-system`, read before the
     switch and after the request exists; its name was not checked for this page), expected one.
5. The row fails for the run if a second Incident opened for `BackOff` or `Unhealthy`, a second analysis ran or a second
   request exists. Do not repeat a failed run until it passes: record the counts and stop the row.

The model does not see the tally yet ([shadewright#796](https://github.com/pkalin/shadewright/issues/796) is not
built), so a proposal says nothing about `status.absorbed`. The counts are read from the Incident only.
Time: about 15 minutes a run, including the clean-up.

### Row 14: precondition and outcome

1. `make scenario-startup-probe CLUSTER=lab` (a reset of the tree: the `slowstart-oom` of row 13 must not be on), then
   `kubectl -n demo get pods -l app.kubernetes.io/name=slowstart`, then delete the pod (or
   `kubectl -n demo rollout restart deploy/slowstart`) so that a new one starts.
2. Precondition, within the first minute:
   `kubectl -n demo get events --field-selector type=Warning,reason=Unhealthy,involvedObject.name=<the new pod> -o custom-columns=LAST:.lastTimestamp,NOTE:.message`
   must show a note that starts `Readiness probe failed` (about 7 failures with connection refused in the first 20 seconds,
   then the pod is Ready). Try up to three pod starts.
3. No event on any of them: the row is **not tested**. Do not go on to step 4.
4. Event seen: wait 10 minutes (2 minutes of the collector's hold, one minute of settle grace, and the gate) and check
   that `kubectl -n shadewright-system get incidents` has none for `slowstart`, and that the analyses taken from the budget
   did not move. That is the pass.

Time: 12 minutes with the event, 5 without.

The `slowstart` pod shows `Readiness probe failed` at every start, so the event is expected. If it is missing, the
workload is not the one of #105: the row is **not tested**.

### Row 15: a consequence Incident already open is folded into a later cause

The fold needs the consequence Incident to exist first, which the normal order (the kill comes first) prevents.
Untested on the lab; the steps below are the plan.

1. Clean up. `kubectl -n demo port-forward deploy/web 9898:9898` and, in another terminal,
   `curl -s -X POST localhost:9898/readyz/disable` (`POST /readyz/disable` is in podinfo 6.17.0, `pkg/api/http/server.go`).
   The pod stays Ready for about 30 s (3 failures at 10 s), then not; no kill, so the pod status shows no cause.
2. The `Unhealthy` Incident opens after the collector's hold of 2 minutes and the gate's second sighting, about five
   minutes in:
   `kubectl -n shadewright-system get incidents -o custom-columns=NAME:.metadata.name,REASON:.spec.reason,PHASE:.status.phase,CREATED:.metadata.creationTimestamp`
3. Precondition: its phase is `Open`, `Analyzing` or `Proposed`, none of its requests has a pull request, and less than
   15 minutes have passed since `CREATED` (the gate's `RecurWithin`; two `creationTimestamp`s are compared, no clock of
   ours). Do it at once: its analysis ends about 2.5 minutes after it opens, and an `Escalated` Incident is not
   folded (ADR-0039 point 12, build notes of #793). If it is `Escalated` or `Resolved`, the row is **not tested**.
   [NEEDS CLARIFICATION: no way to hold the analyses back on the lab was found; the cap at 0 might end the Incident
   `Escalated` through `DailyBudgetReached`, which was not checked.]
4. `make scenario-oom CLUSTER=lab`. The cause Incident opens about 40 seconds after the commit (the `oom` README).
5. Expected, seconds after the cause Incident is created:
   `kubectl -n shadewright-system get incident <the Unhealthy Incident> -o jsonpath='{.status.phase}{" "}{.status.foldedInto}{"\n"}{.status.conditions}'`
   shows `Resolved`, `status.foldedInto` with the cause Incident's name and UID, and condition `Lifecycle` with reason
   `FoldedIntoCause`. The cause Incident has `status.cause` true. The folded Incident does not go back to `Proposed` or
   to `Escalated` (the closure rules skip it).

Time: 15 to 25 minutes (about 5 for the first Incident, then the switch and the fold).

### Rows 16 and 17: the cancel of a request whose Incident was folded or deleted

Both need [shadewright#816](https://github.com/pkalin/shadewright/pull/816), **open** on 2026-11-16; on `main` of the
operator the request goes on to open its pull request. The executor reads the Incident live as the last step before it
opens the pull request (ADR-0039 points 21 and 22). So the Incident must be folded or deleted between the request's
creation and the open, which is under a minute (`AwaitingApproval` came about a minute after a request in the lab run
of 2026-11-04, `oom` README). Row 16 holds that window open with the kill switch; row 17 races it.

Expected for both, once #816 is merged and in the chart under test:

- `kubectl -n shadewright-system get remediationrequest <name> -o jsonpath='{.status.phase}{" "}{.status.conditions[?(@.type=="PullRequestOpened")].reason}{"\n"}'`
  prints `Cancelled IncidentFolded` (row 16) or `Cancelled IncidentGone` (row 17), the condition `PullRequestOpened`
  `False`.
- No pull request: `gh pr list -R pkalin/shadewright-fleet --state open` has none for the request. The request's branch
  and its commit are left on the fleet repository.
- The slot under `maxConcurrentRemediations` is free at once. The target lock is not released by the cancel: the
  request has no recorded pull request, so one may exist, and the lock is kept until the next read of the branch finds
  no open pull request that may deliver the change (`status.holdsTarget` stays true until then, then false). A pull
  request of the request's own that the read finds open is closed first and recorded in `status.pullRequest`; one a
  person opened from the branch is never closed and keeps the lock. After the lock is released, the next request for the
  same field is decided as usual.
- The Incident of a folded request does not end `Escalated`.

Row 17 steps. Start this in a second terminal before the switch, so the delete follows the request at once:

```
until n=$(kubectl -n shadewright-system get remediationrequests -o jsonpath='{.items[0].spec.incidentRef.name}' 2>/dev/null) && [ -n "$n" ]; do sleep 1; done; kubectl -n shadewright-system delete incident "$n"
```

then `make scenario-oom CLUSTER=lab` from a clean state. Precondition: the request was still before its pull request
when the Incident was deleted (no `PullRequestOpened` `True`). If it already has a pull request, it runs its course
(close that pull request), and the row is **not tested**. Time: 3 to 5 minutes from the switch to `Cancelled`, a further
reconcile for the lock.

Row 16 steps. The kill switch holds a request before its first Git write, so the request waits with no branch and no
pull request, and the Incident can be folded while it waits. The operator's docs say it: while `spec.paused` is true the
executor pushes no branch and opens no pull request, a request decided while paused waits, shows the condition
`WritesPaused` and goes on from where it stopped when the pause ends (`docs/emergency.md`, "Stop new Git writes";
design 5.4 and 6, "What a held-back request looks like"). The live read of the Incident comes after the branch and the
commit, so it happens after the release. Pausing does not stop analysis or Incidents (`docs/emergency.md`).

1. Clean up. Pause Git writes before anything starts:
   `kubectl patch remediationsettings default --type merge -p '{"spec":{"paused":true}}'`
2. Do row 15 steps 1 to 3: the `web` readiness failure with no kill, and its `Unhealthy` Incident (`Open`, `Analyzing`
   or `Proposed`).
3. Wait for a request for that Incident (the analysis ends about 2.5 minutes after the Incident opens):
   `kubectl -n shadewright-system get remediationrequests -o custom-columns=NAME:.metadata.name,INCIDENT:.spec.incidentRef.name,PHASE:.status.phase`
   Precondition: it exists, its condition `WritesPaused` is `True`
   (`kubectl -n shadewright-system get remediationrequest <name> -o jsonpath='{.status.conditions[?(@.type=="WritesPaused")].status}'`)
   and `gh pr list -R pkalin/shadewright-fleet --state open` has no pull request of it. If the analysis proposed nothing
   (no request) or a pull request already exists, the row is **not tested** (release the pause, step 6).
4. `make scenario-oom CLUSTER=lab`. The cause Incident opens about 40 seconds after the commit. Row 15 step 5 shows the
   `Unhealthy` Incident `Resolved` with `FoldedIntoCause` while the request still waits.
5. The request must still be before its pull request (`WritesPaused` `True`, no pull request, no `PullRequestOpened`
   `True`). Otherwise the row is **not tested**.
6. Release the pause, always, whatever the result:
   `kubectl patch remediationsettings default --type merge -p '{"spec":{"paused":false}}'`
   The request goes on, pushes its branch, reads the Incident and ends as in the expected list above. Read its phase and
   condition with the command above (`Cancelled IncidentFolded`).

The pause is cluster-wide: no other request writes to Git until step 6, so do this row alone. A pause set while a
request is already between two writes does not stop the one in flight (`docs/emergency.md`), which is why the pause is
set before the request exists, in step 1. This is not run on the lab: the docs say the request waits at its first write and that the Incident read follows the commit, and the run is what confirms that `WritesPaused` shows before the fold and the cancel comes after the release. Time: about 10 minutes after row 15's own
5, plus the release.

## Order of a full run

One scenario at a time: `make scenario-<name>` commits the scenario's files over `apps/demo/` and one request is
active at a time (`maxConcurrentRemediations` 1), so rows cannot overlap. What can be arranged is the order. The times
come from the observed rows above (merge to end) plus about four minutes for the pull request; a time marked "not
measured" is an estimate.

| Order | Row | Workload | Time | Why here |
| --- | --- | --- | --- | --- |
| 1 | 2, then 10 | `web` (`oom-leak`) | about 45 minutes | the kill after the merge (9 minutes) and the revert request (22 minutes to `Inconclusive` after its merge) are waits; the revert needs the failed request's outcome |
| 2 | 4 | `web` (`rollout-blocked`) | about 30 minutes | `Failed` 21 to 23 minutes after the merge |
| 3 | 9 | `cache` (`statefulset-partition`) | up to 30 minutes, not measured | the timeout is 21 minutes from the rollout |
| 4 | 1 | `web` (`oom`) | about 20 minutes | 13 minutes after the merge |
| 5 | 6, 11 | `web` (`oom`) | about 10 minutes each | short, and 11 is timing dependent |
| 6 | 8, then 5 | `worker` (`keda-ceiling-persists`, `keda-load-burst`) | about 10 and 10 minutes | clear before the switch (the HPA condition rule below) |
| 7 | 7 | `web` | about 30 minutes, not measured | two procedures |
| 8 | 12 | not decided | 10 minutes, not measured | the resource-bound case needs #614 |
| 9 | 13 (three times), 15, 17, 16 | `slowstart` (`slowstart-oom`) for 13, `web` (`oom`) for the others | about 45, 25, 5 and 5 minutes | short, but each needs a clean state; 16 holds the kill switch and releases it |
| 10 | 14 | `slowstart` | 5 to 12 minutes | no scenario file; the precondition is the event |
| 11 | 18 | `web` (`liveness-path`) | about 15 minutes, not measured | needs Prometheus down for the analysis and an escalation model; restore Prometheus afterwards |
| 12 | 3 | `web` (`delivery-blocked`) | about 70 minutes | last: the delivery window is one hour from the merge, no commit may go to the cluster branch during it, and the failed merge commit blocks later commits until it is reverted |

Row 3 is the longest and is last, not first, for that reason: starting a scenario for the next row during its window
would end it `Inconclusive` with `DeliveryBlocked`. Added up, a full run is about six hours of waiting.

Rows that share a workload, and what clears them between rows:

- `web`: rows 1, 2, 3, 4, 6, 7, 10, 11, 12, 15, 16 and 17 end in an `OOMKilled` symptom (row 18 is a probe failure on the same workload). They all end in a symptom on the same
  workload, so within 24 hours of a resolution the second one is `Recurred` and escalated, not analyzed. Delete the
  RemediationRequests and Incidents in `shadewright-system` between two of them, after Flux applied the switch and the
  pods of the previous scenario are gone ("Running rows one after another").
- `slowstart`: rows 13 and 14 (needs #105). Row 13 leaves Incidents for `slowstart` behind: delete them before row 14 (row 14 resets the tree with `startup-probe`).
- `worker`: rows 5 and 8. Rows 5 and 8 have a symptom that is a condition that stays unchanged (the HPA's
  `ScalingLimited`): clear before the switch.
- `cache`: row 9 alone.

## Rows to run again after a new release candidate

A new candidate does not mean every row. The table says which rows read what a package decides; it is a rule of
thumb from what each row's outcome depends on, not a measured dependency. A change outside every package below (docs,
tests, scenarios or fleet only) needs `make check-scenarios`, not a lab run.

| Changed package | Rows to run again | Because |
| --- | --- | --- |
| `redact` | 1, 13 | text that goes to the model, the pull request and the status: the full path of row 1, and the analysis of row 13 |
| `policy` | 1, 4, 6, 10, 11 | the bounds and the decrease rule (rows 1, 4, 10), the closed pull request (6) and the stale plan after a policy change (11) |
| `gitops` (pull requests, render, source mapping, target lock) | 1, 5, 6, 11, 12, 16, 17 | everything that opens, reads or closes a pull request or reads the branch |
| `controller` (executor phases, delivery, verification, lock) | 1 to 11, 16, 17 | every row that ends after the merge, and the cancel |
| `collector` or `incidents` (grouping, fold, gate) | 13, 14, 15, 16, and 1 to see an Incident still open | what becomes an Incident, and how many |
| `analysis` or the model's input | 1, 2, 8, 13, 14 | what the model sees and returns: a limit, a leak, a KEDA ceiling, one analysis per fault, no proposal for a probe |
| chart (values, RBAC, flags) | 1, 5, 7, 17 | the install with verification on, the pull request path, the stopped verifier, and the `delete` on Incidents row 17 uses |

## Analyses of a full run

The daily cap is `analysis.maxAnalysesPerDay` in `infrastructure/shadewright-lab-config/base/remediationsettings.yaml`. A
revert request and the deterministic steps use no analysis. Each row's analyses when the grouping rule holds:

| Row | Analyses | Row | Analyses |
| --- | --- | --- | --- |
| 1 | 1 | 9 | 1 |
| 2 (with 10) | 1 | 10 (the default-policy run of row 2) | 1 |
| 3 | 1 | 11 | 1 |
| 4 | 1 | 12 | 1 |
| 5 | 1 | 13, three runs | 3 |
| 6 (a second Incident for the queued request) | 2 | 14 | 0 |
| 7 (two procedures) | 2 | 15 (the consequence and the cause) | 2 |
| 8 | 1 | 16 | 2 |
| | | 17 | 1 |

That is 22 analyses. Row 13 now runs on `slowstart` instead of `web` and row 14 on `slowstart` instead of `worker`, so the counts are the same. If the grouping rule did not hold, one fault would open three Incidents and each would be analyzed
(the run of 2026-11-14, [shadewright#432](https://github.com/pkalin/shadewright/issues/432)): 2 more for each of the 16
analyses of OOM faults (rows 1, 2, 3, 4, 6 twice, 7 twice, 10, 11, 13 three times, 15, 16, 17), 32 more, so 54 for one
pass. The release run goes through the matrix once per model provider (decided 2026-11-17: Microsoft Foundry, the
Anthropic API and the OpenAI API), three passes in one UTC day: 162 at worst. The cap is 180: that and a margin of 18,
about six more runs of a row. The token cap is per model: at about 7,000 tokens an analysis (the evaluation of
2026-11-14) one pass of 60 analyses is about 420k tokens, under `maxTokensPerDay` (800000) of the model it runs on.

## Running rows one after another

Several rows on one workload in one session need cleaning between them (learned on the lab run of 2026-11-14):

- Within 24 hours of a resolution the same symptom on the same workload is marked `Recurred` and escalated, not
  analyzed again. Between two rows on one workload, delete the RemediationRequests and Incidents in `shadewright-system`.
- Clear them only after Flux has applied the scenario switch and the pods of the previous scenario are gone. Clearing
  earlier let an Incident open from a dying pod of the old template ([shadewright#724](https://github.com/pkalin/shadewright/issues/724)).
- For a scenario whose symptom is a condition that stays unchanged (the HPA's `ScalingLimited` in the KEDA scenarios),
  clear before the switch: an Incident deleted while the condition is already True is not opened again.
- A pod that starts under the scenario may log one readiness probe failure, and the agent has proposed a memory
  increase for it ([shadewright#726](https://github.com/pkalin/shadewright/issues/726)). Close that pull request: it
  also holds the one remediation slot (`maxConcurrentRemediations`).

## New scenarios, row by row

The demo app is podinfo 6.17.0 (`apps/demo/web-deployment.yaml`). Its flags and endpoints below were read in the
`6.17.0` tag of `stefanprodan/podinfo`: `cmd/podinfo/main.go` (flags `--stress-cpu`, `--stress-memory`,
`--unready`, `--unhealthy`, `--random-error`, `--random-delay`, `--data-path`), `pkg/api/http/store.go` (`POST /store`
writes the posted body to `--data-path`, default `/data`, one file per distinct body) and `pkg/api/http/panic.go`
(`GET /panic` exits with code 255). The README of the same repository lists `POST /fault_injection/enable`, which makes
the app answer 500 to application requests while probes stay healthy. Rows 3, 4 and 9 have scenarios, and each was
applied by hand to a Kind cluster (below). The other rows were not run: each of their scenarios needs a Kind run to
tune its numbers before it is merged. Rows 1, 2, 4, 6, 8 and 10 were run on the lab on 2026-11-14 (see their Status).

### Row 2: a leak

`--stress-memory` allocates once at start (it truncates a file to N MB and reads it into the heap), so it cannot grow:
it gives the `oom` kill, never a leak. podinfo has no flag that grows memory over time. The smallest way to get growth
from podinfo itself is its `/store` endpoint on a memory-backed volume:

- In the scenario's `web-deployment.yaml`, the `data` volume becomes `emptyDir` with `medium: Memory` and a `sizeLimit`
  above the container limit (the `main` file has `sizeLimit: 16Mi`, which would evict the pod instead of killing the
  container). Tmpfs pages are charged to the container's memory cgroup, so they count against the limit.
- A `loadgen`-style Deployment (the `keda-at-ceiling` one is the model: same hardening, one object per file, listed in
  the scenario's `kustomization.yaml`) posts a different body to `/store` every few seconds, each below the request
  body limit of podinfo (`maxRequestBodySize` in `pkg/api/http`). The usage then grows in a straight line.
- Start the limit at 64Mi (the policy minimum). The first kill comes when the volume and the app together reach it; the
  agent raises it by at most 50% (policy `maxIncreasePercent`), the new pod starts with an empty volume, and the kill
  returns after a time set by the growth rate. Pick the rate so that this is longer than the delivery wait and shorter
  than `stableFor`.

Checked on Kind (not on the lab): the kernel kills the container; the pod is not evicted. `lastState.terminated.reason`
is `OOMKilled` with exit code 137, so the alternative image is not needed. Times with the final loadgen (`sleep 0.3`):

- pod start to the first kill at a 64Mi limit: 2 min 25 s;
- limit raised by hand to 96Mi (new pod, empty volume) to the second kill: 5 min 58 s.

An earlier run with `sleep 0.5` took about 4 min 40 s and 8 min 37 s, too close to 10 minutes, so the rate was raised.
Two facts the plan above did not foresee:

- A container restart inside the same pod keeps the volume, so the container is killed again after about 30 s. Only a
  new pod starts with an empty volume.
- The kubelet sizes the memory-backed `emptyDir` to the container limit whatever `sizeLimit` says (`df` showed 65536
  KiB at 64Mi). The container also holds 21 to 28 MiB of anonymous memory besides the volume, so the kill comes at about
  35 MiB in the volume at 64Mi and about 65 MiB at 96Mi.

The rate is Kind's and must be rechecked on the lab. The outcome (`Failed`) stays planned: no agent ran.

### Row 3: the Kustomization fails to apply after the merge

The pre-merge policy check refuses a Kustomization that is not Ready (`KustomizationNotReady`), and the render check
refuses a change that does not render, so the failure must come from the cluster, not from the file. The smallest way is
an admission rule that the old value passes and the new one does not. A `ValidatingAdmissionPolicy` and a
`ValidatingAdmissionPolicyBinding` (Kubernetes 1.30 and later), as two plain files in `apps/demo/` (`web-memory-limit-policy.yaml` and `web-memory-limit-policy-binding.yaml`) listed in the
scenario's `kustomization.yaml`, reject a Deployment in `demo` whose container memory limit is above 60Mi. The `oom`
file starts at 48Mi, so the scenario applies. The agent's 64Mi is refused when Flux applies the merge: `apps` turns
`Ready=False` with the admission message, and the request waits for a delivery that never comes. Run on Kind
(applied with `kubectl`, not through Flux, 2026-11-13): the first apply of `web` at 48Mi passed, and a server-side dry run
and a real apply at 64Mi were refused with the policy's message, while 60Mi passed a dry run. Not checked: that Flux
reports the refused apply as a failure of `apps`.

The timeout is long (an hour from the merge, as the code stands), so run this row last in a session. ADR-0030 ends
the wait `Failed` with `DeliveryFailed` only when Flux failed on exactly the merge commit. Do not push another commit
to the cluster branch during the window: a failure on a later commit ends `Inconclusive` with `DeliveryBlocked`, and
a suspended Kustomization with `DeliverySuspended`. The failed merge commit also blocks later commits until it is
reverted, which is what row 10 uses.

### Row 4: the pods keep the old value

A patch in the repository cannot make this row. A `kustomization.yaml` in `apps/demo/` may list `resources` only
(ADR-0012), and a Flux Kustomization with `patches` is refused with `KustomizationTransforms`; an overlay that
hides the new value fails the render check with `DesiredValueMissing` before any pull request exists. So a patch is
a separate refusal row, not this one. What the row needs is a change that Flux applies and the pods do not take. Two ways:

- A `LimitRange` in `demo` with a container `max` of 56Mi, one plain file. The Deployment applies, but its new
  ReplicaSet cannot create pods above 56Mi, so the old pod stays with its old limit and the rollout never completes.
  Side effect to accept or avoid: `worker` and `cache` have 64Mi limits, so a pod of theirs that is recreated while the
  scenario is on is refused too. The scenario lasts minutes and does not touch their templates.
- A mutating admission rule (a Kyverno policy, or a `MutatingAdmissionPolicy` on a cluster that has it) that rewrites
  the limit back to the old value. It is closest to "a patch overrides the field" but adds a controller or a newer API.
  Not recommended for the first run.

With a `LimitRange` the request is `Failed` with `RolloutStuck` at the timeout, so it also leads to a revert request
(ADR-0030, section 8), as row 3 does.

Run on Kind (applied with `kubectl`, 2026-11-13): after the 64Mi Deployment was applied, its new ReplicaSet stayed at 0
of 1 pods with `ReplicaFailure` (`maximum memory usage per Container is 56Mi, but limit is 64Mi`) and the old pod
stayed on its old template. Not checked: the same through Flux and the request's phase.

A later commit that overwrites the new value on the cluster branch is a different outcome: the live field no longer holds
the desired value, and the request ends `Inconclusive` at once with `ValueChanged` (`Configured=False`).

A paused Deployment (`spec.paused: true`) gives the same end state but cannot be a scenario file: it would also stop the
broken template of `oom` from rolling out, so no symptom would appear first.

### Row 5: the incident stops by itself

Every change to the target file is a plan input, and a change ends the request `Superseded` (ADR-0022, consequences), so
a reset of `oom` cannot make this row: it tests row "Superseded" instead. The symptom has to end with Git untouched.
`keda-load-burst` is `keda-at-ceiling` with `loadgen` running its curl loop for a fixed time (a few minutes), then
`sleep` for good. The ScaledObject file does not change, the HPA leaves its ceiling when the load ends, and the
`ReplicaCeiling` Incident stops being observed while the pull request waits for review. The reviewer waits until the
load has ended before looking. What the request does then is the point of the row: read in the code, nothing ends it (the deadline of the pull request step is cleared once the pull request is open), and ADR-0030 does not decide it. Its #95 items cover a merge
conflict before the merge (#95a) and a symptom that stopped before the rollout of a merged change (#95b, `Cleared`
with reason `ResolvedBeforeRollout`); a close without a merge is row 6. Neither covers an unmerged pull request whose Incident has ended. The expected
outcome is the code's behaviour today; the row stays open until the remaining part of #95 decides whether it should change. If a person merges after the load ended, #95b is the case that applies.

### Row 7: data missing

In v0.5.0 "cleared" is read from container status on a workload that still exists with the same UID
(decision of 2026-11-13 in #248); the executor has no metrics source. Two procedures give missing evidence. Neither is
a scenario; both are manual steps after a merge.

- A deleted or recreated target. After the merge and the rollout, suspend the `apps` Kustomization and delete the
  `web` Deployment, wait, then resume. The request ends `Inconclusive` at once with `TargetGone`. To get
  `TargetReplaced`, delete and recreate it (a new UID) instead. ADR-0030 does not wait for the window in either case.
- A stopped verifier. During the window, scale the `shadewright-verifier` Deployment in the operator namespace to
  zero (suspend its `HelmRelease` first if Flux restores the replicas). The executor then finds no fresh report
  (`StaleReport`), the window never completes, and the request ends `Inconclusive` at the timeout (21 minutes for a
  memory fix with the defaults), never `Succeeded`. The verifier writes the report the executor reads; the procedure has not been run.

### Row 8: still at the ceiling

`keda-at-ceiling` asks for 3 replicas at about 13 requests per second (threshold 5 per replica). The `demo-keda` policy
allows `maxReplicaCount` 2 to 3 and no more. `keda-ceiling-persists` raises the load to about 25 requests per second
(`sleep 0.03` in `loadgen`; the rate is an estimate, tune it on Kind), so the trigger asks for 5 and the HPA stays at
3 after the fix is applied.

Observed on 2026-11-14 (chart `0.5.0-rc.1`, #78): the request ended `Inconclusive` with `RolledOut=Unknown` (reason
`KindNotChecked`), and `Cleared` and `Verified` `Unknown` with reason `CheckNotAvailable`, because the check
`QueueBacklogDecreasing` needs metrics that no evidence source reads yet. A request that does not name
that check ends `Inconclusive` with reason `ClearingNotChecked` instead, as the run with `claude-haiku-5-5` on
2026-11-14 (#93) did.

The expected outcome is not `Failed`. A ScaledObject has no pods of its own, and its symptom (scaling held at the
maximum, a growing backlog) is not visible in container status, so in v0.5.0 `Cleared` stays `Unknown` with reason
`CheckNotAvailable`. Once rolled out (`Delivered` and `KedaReady`) and configured held for `stableFor`, the request
ends `Inconclusive`. A KEDA request cannot end `Succeeded` or `Failed` on its symptom until metrics are evidence
([shadewright#508](https://github.com/pkalin/shadewright/issues/508) and
[#506](https://github.com/pkalin/shadewright/issues/506)); `Failed` is possible only for a failed delivery (`DeliveryFailed`, `RolloutStuck`) or `KedaNotReady`. A request
that names the check `QueueBacklogDecreasing` ends `Inconclusive` with `CheckNotAvailable`. So the row shows that the
persistent ceiling is not reported as success, not that it is caught.

### Row 9: a partitioned StatefulSet

`statefulset-partition` is `statefulset-oom` with `partition: 1` under `updateStrategy.rollingUpdate` in
`cache-statefulset.yaml`. With two replicas only `cache-1` is replaced by a changed template; `cache-0` keeps the old
one. The fix then changes the limit, and the rollout evaluator calls the partitioned update complete when the pods
above the partition run the new revision. ADR-0030 keeps that (`RolledOut` True, reason `RolloutPartitioned`, naming
the pod on the old revision) but does not accept it as evidence: every desired replica must run the applied revision,
so the window cannot complete (`PartialRollout`) and the request ends `Inconclusive` at the timeout. If the partition is
lowered to 0 by a later commit inside the timeout, the window can still complete.

Run on Kind (applied with `kubectl`, 2026-11-13): over a healthy `cache`, a template with a lower limit reached only
`cache-1` (it was `OOMKilled`), and `cache-0` stayed on the old revision. A later change to 72Mi, with `cache-1`
deleted by hand (the forced rollback in the `statefulset-oom` README), gave a Ready `cache-1` on a new revision while
`cache-0` stayed on the old one. Not checked: that the source mapping accepts the extra field in the plain manifest (it
should, as it is a literal value), the operator's rollout evaluator, and what `statefulset-oom` shows once its merge is
observed; that run stopped at the merge.

### Row 10: a revert request (new, planned)

Row 2 (`oom-leak`) is the source of the revert that goes through under `demo-memory`: the limit goes from 64Mi to 96Mi
(50%), the kill returns and the request ends `Failed` with `OOMKilled`. Row 3 also ends `Failed`, but its revert goes
back to 48Mi, below the policy's `min` of 64Mi, so it ends `Denied` with `BelowMinimum` (the policy check tests `min`
before the decrease, so no `maxDecreasePercent` changes that). After a request ends `Failed`, the analyzer creates a revert request in
deterministic code, with no model call: the same Incident and target, `previous` and `desired` swapped,
`approvalRequired: true` and a link to the failed request, named from the failed request's UID so that a repeat finds
the same one. It goes through the policy check, the freshness check and the target lock like any request, and opens a
pull request that needs a person's approval. Once that is merged, rolled out, configured and available for `stableFor` on the executor's clock, the revert
ends `Inconclusive` with `RevertApplied`, never `Succeeded`. The verifier writes no report for it, so the OOM rule and
`Cleared` do not apply (`Cleared` stays `Unknown`, reason `RevertApplied`). The Incident stays escalated. Cases to check
beside it: a revert of a revert is never created, an `Inconclusive` request never gets one, and a request whose revert
link is not the exact inverse of a failed request ends `Denied` with `InvalidRevert` before any Git write.

A revert of a memory increase is a decrease, and policies refuse decreases by default (`maxDecreasePercent` 0). The two
ends:

- Default policy: the revert ends `Denied` with `DecreaseNotAllowed`, and a person reverts by hand (ADR-0030, section 8).
  Whether a policy may allow exactly the inverse of a failed request's change is still an open decision for the
  maintainer (the fourth point of the ADR).
- A policy that allows the decrease: the revert goes through approval and, once merged and held, ends `Inconclusive`
  with `RevertApplied`.

Proposed for the lab run: set `maxDecreasePercent: 34` on the policy of the demo app (`demo-memory`, `min` stays 64Mi)
so that the revert path is exercised from row 2: 96Mi back to 64Mi is a decrease of 33.3%, inside 34 and not below
`min`. Row 3's revert to 48Mi is denied `BelowMinimum` under that policy whatever the percent is. Make one run with the
default to show the `DecreaseNotAllowed` denial. The setting is a proposal until the maintainer decides the policy
question.

## Planned groups

Not part of v0.6.0 verification. Listed so the page matches the issue.

| Group | Row | Setup | Status |
| --- | --- | --- | --- |
| Change evidence | An OOM after a commit lowered the limit | a scenario whose cluster-branch history holds a commit that lowers `web`'s limit shortly before the symptom | planned |
| Change evidence | A sync that rolled the workload for another reason | a commit that changes something other than the limit (an annotation, an env value) and rolls the pods, while an OOM is already present | planned |
| Fleet registration | none written yet | the issue names the group but gives no rows | planned |
| OpenTelemetry Demo flags (second cluster) | `adHighCpu` | the service gets CPU pressure; expected to be observed as throttling or a slow service, with no OOM and no pod restart, so the open question is whether the agent proposes anything | planned |
| OpenTelemetry Demo flags (second cluster) | `cartFailure` | the cart service answers with errors at the set rate; expected to be observed as failing requests with the pods running and no memory symptom | planned |
| OpenTelemetry Demo flags (second cluster) | `failedReadinessProbe` | the cart service pods stay not Ready; expected to be observed as a readiness failure on the cart service, no kill | planned |

## Second cluster

The first cluster (Kind, or the AKS lab with Flux) cannot run two kinds of row. The second cluster, a lab for a
session and destroyed after it ([ADR-0008](https://github.com/pkalin/shadewright/blob/main/docs/adr/0008-disposable-azure-lab.md)),
adds:

- Argo CD as its delivery controller. The operator has one delivery adapter, Flux (`internal/providers/delivery/flux`);
  Argo CD is on the adapter list of the design (`DeliveryVerifier`, design 2 and 13) but not built, and the source
  mapping reads Flux labels. So the cluster by itself gives no row until the adapter and a mapping for Argo CD exist;
  it is the place to run them. Not designed.
- A public demo application whose failures we did not write. A check that only passes on breakage we authored
  proves little about the diagnosis.

The design of the second cluster is in `shadewright-azure`:
[docs/second-lab-cluster.md](https://github.com/pkalin/shadewright-azure/blob/main/docs/second-lab-cluster.md)
(node size, price per hour and per session, which rows need AKS). The cluster is applied for a session and destroyed
after it.

### Which applications

| Application | Delivered as | Documented failures | Resource needs | Source |
| --- | --- | --- | --- | --- |
| OpenTelemetry demo (`open-telemetry/opentelemetry-demo`) | a Helm chart; the documentation also shows `helm template ... > opentelemetry-demo.yaml` | feature flags in `src/flagd/demo.flagd.json`, among them `emailMemoryLeak` (variants `1x` to `10000x` and `off`), `failedReadinessProbe` (cart service), `cartFailure` (`10%` to `100%`), `adHighCpu` and `cartMetricCardinalityOverflow` | 6 GB of free RAM for the application | the repository above for the flags; `content/en/docs/demo/kubernetes-deployment.md` in `open-telemetry/opentelemetry.io` for the RAM and the `helm template` command |
| Online Boutique (`GoogleCloudPlatform/microservices-demo`) | plain manifests: `kubernetes-manifests/` and `release/kubernetes-manifests.yaml` (12 Deployments), also a `helm-chart/` | none documented as switches | per service in the manifests, for example `cartservice` requests 64Mi and limits 128Mi, and its Redis requests 200Mi and limits 256Mi (`kubernetes-manifests/cartservice.yaml`); its `README.md` gives no total | the manifests above |

Not verified: how the flags are switched in the chart-based install (the flagd ConfigMap lives in the chart
repository, `open-telemetry/opentelemetry-helm-charts`, which was not read); the total memory of Online Boutique.

`emailMemoryLeak` is a real leak in a service we did not write, which makes it the better source for row 2 than the
podinfo construction. A flag is a value in a ConfigMap, so an agent could in principle propose it; whether that is an
allowed action is a different question and not assumed here.

Decision 1 of #672, taken on 2026-11-14: the OpenTelemetry demo goes on the second cluster first, because its failures
are documented, behind feature flags, and were not written here, and because it is a Helm chart, which gives the
`HelmManaged` row below and the case of a chart rendered into plain YAML. The design note checks both claims against the
application's own pages and maps the flags to rows. Online Boutique stays a candidate for later.

### The Helm refusal is a row

An application delivered by a Flux `HelmRelease` is refused by the source mapping with reason `HelmManaged`
(ADR-0012: Helm values are not supported). The only way to a pull request is to render the chart into plain YAML, commit
that, and let a Flux Kustomization apply it. That refusal is a verification row of its own:

| Row | Setup | Expected phase | Expected reason | Runs on | Status |
| --- | --- | --- | --- | --- | --- |
| A Helm-delivered application | install the OpenTelemetry demo chart through a `HelmRelease`, break a memory limit | `NeedsIntervention` (the troubleshooting page of the operator lists `HelmManaged` with the other delivery refusals, all `NeedsIntervention`, on condition `PolicyAllowed`) | `HelmManaged` | Lab; the second cluster adds the public chart | new scenario needed |

It needs no Argo CD: Flux already installs Helm charts on the lab.

## Open points

- Row 5: nothing ends a request that waits for approval while its Incident resolves. It stays `AwaitingApproval`, with
  its pull request open and the target locked, until a person merges or closes the pull request. The row stays open
  until the design decides whether the executor should end it.
- Row 12, resource-bound case: marked "after #614". The input-limit case already gives `TooLarge`.
- Row 11 depends on a merge inside the freshness interval; the scenario needs a way to make that repeatable.
- Row 10: a revert of a memory increase is a decrease and ends `Denied` with `DecreaseNotAllowed` under the default
  policy. Whether a policy may allow the inverse of a failed change is a maintainer decision (ADR-0030, section 8).

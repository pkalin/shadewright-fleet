<p align="center"><img src=".github/logo.png" alt="Shadewright" width="120"></p>

<p align="center">
  Part of <a href="https://shadewright.io">Shadewright</a>, a safe-remediation controller for Kubernetes clusters run with GitOps: it turns untrusted proposals, from rules or an LLM, into typed, bounded changes tied to policy and to the object's real source in Git, delivers them only as reviewed pull requests, and verifies the effect.
</p>

# shadewright-fleet

The GitOps repository for the [Shadewright](https://shadewright.io) lab cluster, synced by Flux. The Shadewright operator opens its remediation pull requests here, so this repository's layout and branch rules are part of the demo.

## Layout

```text
clusters/lab/           Flux entry point, applied by the Flux configuration from shadewright-azure
  kustomization.yaml
  infrastructure.yaml   Flux Kustomization for infrastructure/
  shadewright.yaml      Flux Kustomization for the agent, after infrastructure, independent of apps
  shadewright-config.yaml  Flux Kustomization for the agent's settings and policy, after shadewright
  apps.yaml             Flux Kustomization for apps/, after infrastructure is ready
clusters/kind/          the same for a Kind cluster (scripts/kind.sh), without Azure substitutions
infrastructure/         cluster add-ons and the namespaces apps/ needs
  shadewright/          the agent from the released Helm chart: OCIRepository (digest, cosign) and HelmRelease
  shadewright-lab/      lab values for it: base/ (workload identity client IDs and the rest every provider shares) and one
                        variant per model provider (foundry, anthropic, openai), applied by clusters/lab/shadewright.yaml
  shadewright-lab-config/  the agent's RemediationSettings and policies: base/ and the same three variants (the models),
                        applied by clusters/lab/shadewright-config.yaml
  namespaces/           the demo Namespace, created before anything binds in it
  keda/                 KEDA (upstream chart, one replica per component)
  prometheus/           minimal Prometheus: server, kube-state-metrics, kubelet and cAdvisor, 24h retention
apps/                   demo workloads the scenarios break
  demo/                 web (podinfo) and worker (podinfo scaled by a KEDA ScaledObject on a Prometheus query)
scenarios/              reproducible incidents: the broken files, what breaks and what Shadewright must conclude
scripts/render.sh       render check: kustomize build and kubeconform on what Flux applies
schemas/                kubeconform schemas of the Shadewright CRDs (scripts/crd_schemas.py)
scripts/scenario.sh     scenario harness: make scenario-<name> and scenario-reset CLUSTER=kind|lab
scripts/kind.sh         Kind cluster with Flux pointed at this repository: make kind-up, kind-wait, kind-down
scripts/tools.env       every pinned tool version and checksum (make tools installs them into bin/)
tools/faultbox/         a workload that fails on request with known truth (Go, distroless): make faultbox-test
```

Environment values (tenant and identity client IDs, endpoints, the operator namespace) are never in this
repository: they arrive as Flux `postBuild` substitutions (`${VAR}`) from the lab's Terraform.

## Model provider

The lab runs the agent against one of three model providers, chosen when the lab is brought up or later with one
command, never by a commit here: `foundry` (the default: Microsoft Foundry, the analyzer's workload identity, no key),
`anthropic` (the Anthropic API) and `openai` (the OpenAI API through the OpenAI-compatible provider, operator ADR-0042).
Each has a directory under `infrastructure/shadewright-lab/` (the chart values) and under
`infrastructure/shadewright-lab-config/` (the `RemediationSettings` models); the parts every provider shares are in
`base/` next to them. A variant holds only its provider's values: the triage and escalation models, the provider's chart
values and its `analysis.models.triage` and `analysis.models.escalation`. The Secrets of the keys (`shadewright-anthropic`, `shadewright-openai`, key `api-key`) are
created outside Git by shadewright-azure.

How it is selected: the path of the Flux Kustomizations `shadewright` and `shadewright-config` ends in
`${MODEL_PROVIDER:=foundry}`. The root Kustomization `lab` (created by shadewright-azure's `scripts/lab.sh`) applies
`clusters/lab` with postBuild substitution, so it replaces that variable in the text of those two child objects before
it applies them (a root's own `spec.path` is not substituted, but the `path` of an object it applies is only text to
it). The value comes from the optional ConfigMap `lab-model-provider` (key `MODEL_PROVIDER`) in `flux-system`, which
the lab script writes with `LAB_MODEL_PROVIDER` at `make lab-up` and `make lab-provider`; with no ConfigMap the default
is `foundry`. A change of the ConfigMap changes both paths in one reconcile of `lab`, so the chart values and the
settings never come from different providers for longer than that reconcile.

The `openai` variant needs a chart release that has operator ADR-0042 (`analyzer.analysis.openAICompatible`, provider
`OpenAICompatible`): the pinned chart (v0.6.0-rc.1) has it, and `schemas/` holds its CRDs, so the render check covers that
variant's `RemediationSettings` like the others.

Escalation models (the only models offered the read tools, such as `get_resource`; a scenario that needs a tool
escalates on a failed source, README of `liveness-path`):

| Provider | Triage | Escalation | Where the ID comes from |
| --- | --- | --- | --- |
| `foundry` | `gpt-5.4-mini-2026-03-17` (deployment `triage`) | `gpt-5.4-2026-03-05` (deployment `escalation`, chat completions) | the foundation's `model_deployments` in shadewright-azure |
| `anthropic` | `claude-haiku-5-5` | `claude-sonnet-5-5` | operator docs and eval tests name the ID |
| `openai` | `gpt-6.1-sol` | `gpt-6-astra` (Responses) | only a test fixture of the operator names it: check it against a recorded response before the run |

Each escalation deployment has `maxTokensPerDay: 300000`, which today bounds one analysis (operator
`ModelDeployment.maxTokensPerDay`), so one escalated analysis spends at most 300,000 tokens on the escalation model. At
the output price of the model that is at most USD 4.50 (`gpt-5.4`, USD 15 per 1M output), USD 3.00 (Sonnet 5.5, USD 10)
and USD 15.00 (astra, USD 50, the Foundry list price: the OpenAI API price is not in this repository). The loop's own
limits (4 tool steps, 2048 output tokens per call, a context of about 12,000 tokens) put a typical escalated analysis
near USD 0.30, 0.22 and 1.10, before tool results. `gpt-5.4` does not need `inferenceAPI: Responses`; a `gpt-6.1` model
on Foundry would (operator #501).

## Kind

`clusters/kind` does not install the agent (it never did: the agent needs the lab's workload identity). To try the
released chart on a Kind cluster, install it by hand from the pinned digest in
`infrastructure/shadewright/ocirepository.yaml` (verify it with `cosign verify` first; the executor has no identity
there, so it stays idle):

```bash
helm install shadewright oci://ghcr.io/pkalin/charts/shadewright@sha256:<digest> \
  --namespace shadewright-system --create-namespace --set clusterId=kind --set 'analyzer.watchNamespaces={demo}'
```

## Checks

Scenarios are switched on with one commit on the cluster's own branch (`cluster/kind`, `cluster/lab`), never on
`main`; see [scenarios/README.md](scenarios/README.md).

Every pull request runs `Render manifests`: each kustomization Flux applies must build and pass
`kubeconform -strict` with the Flux CRD schemas, and every Flux `path:` must exist. Run the same check locally
with `scripts/render.sh`. The full rules and planned layout are in [AGENTS.md](AGENTS.md).

## Rules on `main`

`main` is the source of truth. On the lab, Flux tracks its own branch, `cluster/lab`, not `main`
([ADR-0022](https://github.com/pkalin/shadewright/blob/main/docs/adr/0022-scenario-switch-and-clusters.md)), which
holds the same tree as `main` between scenarios. The Shadewright operator opens its pull requests against the
branch Flux tracks, and `main` takes changes only through a reviewed pull request:

- **One approval of the most recent push**, and approvals are dismissed when new commits arrive. The operator's
  GitHub App cannot approve its own pull request, so nothing it proposes reaches the cluster without a person.
- **Code owner review** (`.github/CODEOWNERS`).
- **Required checks:** `Conventional PR title`, `Render manifests`, `Harness tests`, `Kind baseline`,
  `Workflow lint`, `Dependency review` and `Path guard`. A change that does not render never merges. `Path guard`
  (a pull request that touches anything outside `.github/shadewright-paths.txt`, read from the base branch, fails
  and needs a human) and code owner review keep `.github/`, which holds the guard itself, in human hands.
- **Squash merge only**; no force pushes, no deletion of `main`.
- **Bypass:** only the repository admin role, and only for pull requests, so the maintainer (a solo maintainer
  cannot approve their own pull request) can still merge theirs. GitHub logs every bypass. The GitHub App is
  never a bypass actor.

The ruleset lives in the repository settings, not in Git; changing it is the maintainer's.

## Reviewer hints and the `shadewright/review` check

Reviewer hints are off by default. When they are on (chart value `executor.reviewerHints.enabled`), the ruleset of
the branch the operator opens its pull requests against must require the status check `shadewright/review`, with
the Shadewright GitHub App as the expected source. Without the rule, a hint-steered change is not held by the
check.

In this lab fleet the maintainer is on the bypass list, and a bypass actor can merge past the check, including a
change it steered itself with a hint. GitHub logs every bypass. The App is never a bypass actor. The setup steps are
in the operator's `docs/how-to/turn-on-reviewer-hints.md` and ADR-0028.

## License

Apache License 2.0, see [LICENSE](LICENSE).

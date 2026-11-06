# shadewright-fleet: guide for coding agents

The GitOps repo for the Shadewright lab cluster, synced by Flux. It is also the repo the Shadewright operator opens remediation pull requests against, so its layout and branch protection are part of the demo.

## Layout

- `clusters/lab/`: Flux entry point. `shadewright-azure` (`scripts/lab.sh`, after the apply; its `lab/flux.tf` output
  holds the values) installs Flux and creates a `GitRepository` named `fleet` and the root Kustomization `lab` that
  applies this path, both in `flux-system`. This path holds no `flux-system` manifests of its own, only Flux `Kustomization` objects:
  `infrastructure`, then `shadewright` and `apps`, each after `infrastructure` (`dependsOn`) and independent of each
  other, with `prune: true` and `wait: true` (not `apps`: its Ready is the apply result, so a broken
  rollout does not keep the operator's source mapper from accepting it, ADR-0012). The lab's Flux runs with
  `--no-cross-namespace-refs` and `--default-service-account=flux-applier` (multi-tenancy, as
  the AKS extension had it: Flux objects are applied as the `flux-applier` ServiceAccount, bound to `cluster-admin`), so every Flux object stays in `flux-system` and references sources in that namespace.
- `clusters/kind/`: Flux entry point for a local or CI Kind cluster, the `infrastructure` and `apps`
  Kustomizations without substitutions (no `shadewright`). `scripts/kind.sh` creates what the lab's `scripts/lab.sh` creates there: the `GitRepository`
  `fleet` and a Kustomization `kind` that applies this path. Nothing applied from `clusters/kind/` may need an Azure
  value, so Azure-only parts (the Shadewright install with workload identity) go into a path only `clusters/lab`
  applies.
- `infrastructure/`: cluster add-ons and the namespaces `apps/` needs; Shadewright itself (Helm chart from the operator repo's release).
  - `namespaces/`: the `demo` Namespace. It belongs to the demo workloads but lives here because infrastructure
    objects bind in it before `apps` is applied (the analyzer's RoleBinding from the operator's `config/watch`,
    Prometheus' scrape target). Flux applies Namespaces before other objects of the same Kustomization, and
    `infrastructure` before `apps`, so it always exists first. Put any other namespace that `infrastructure/`
    refers to but `apps/` fills here too.
  - `keda/`: KEDA from the upstream chart (not the AKS add-on), one replica per component.
  - `prometheus/`: a minimal Prometheus (ADR-0017): server and kube-state-metrics, kubelet and cAdvisor
    targets, 24h retention on an emptyDir, no Alertmanager or Grafana. In-cluster URL
    `http://prometheus-server.prometheus.svc`.
  - `shadewright/`: the agent (analyzer and executor), installed from the released Helm chart: an `OCIRepository`
    (`oci://ghcr.io/pkalin/charts/shadewright`) pinned by `ref.digest`, never a tag or range, with `verify.provider:
    cosign` and `matchOIDCIdentity` for the exact chart workflow on the release tag, and a `HelmRelease` with `chartRef`
    to it (release `shadewright`, `targetNamespace` and `storageNamespace` `shadewright-system`). The chart pins the
    executor and analyzer image digests itself. The `shadewright-system` Namespace is a manifest here (restricted
    Pod Security, `prune: disabled`), not created by Helm. Values: `clusterId: lab` (set, because helm-controller must
    not depend on the chart's `lookup`; choose once, it is hashed into every Incident fingerprint) and
    `analyzer.watchNamespaces: [demo]`. To upgrade, take the chart digest and tag from the release, run `cosign
    verify` (operator `docs/upgrade-uninstall.md`), then change the digest and the tag in the `subject` together.
    Not listed in `infrastructure/kustomization.yaml`: `infrastructure/shadewright-lab/` (patches the two workload
    identity client IDs into the HelmRelease values as `${VAR}` substitutions, each tied to a Terraform output in its
    header) is applied only by `clusters/lab/shadewright.yaml`, after `infrastructure`; nothing depends on it, so a
    broken agent cannot block `apps`. The Kind cluster does not install the agent through Flux; see README, "Kind".
    `infrastructure/shadewright-lab/` also turns the model analysis on for an evaluation run (not production): triage
    model, `endpointSuffixes` limited to the lab's own AI Services host (`${MODEL_ENDPOINT_SUFFIX}`) and
    `actionPolicies`. The daily cap (`maxAnalysesPerDay`) is in the hand-applied `RemediationSettings`, not here.
    Switching a running lab from the old vendored install is not supported (Helm refuses to adopt the existing CRDs
    and RBAC): the lab is destroyed between sessions, so a fresh lab installs the chart cleanly.
  - Each add-on has its own namespace (restricted Pod Security labels, default-deny NetworkPolicy and explicit
    allows) and a `HelmRepository` and `HelmRelease` in `flux-system` (multi-tenancy) with `targetNamespace`.
    Charts are pinned to exact versions and images to tag and digest in the values; bump them together.
- `apps/`: small workloads used as remediation targets, under `apps/demo/`: `web` (Deployment and Service) and
  `worker` (Deployment, Service and a KEDA `ScaledObject` with a Prometheus trigger) and `cache` (a stateless
  two-replica StatefulSet with a headless Service, no volume claim), all podinfo. One object per
  file and kustomizations with `resources` only, because the operator's source mapping (ADR-0012) supports plain
  manifests only; values the patchers change (memory limits, `maxReplicaCount`) stay literal. The worker has no
  `spec.replicas`: the HPA that KEDA creates owns it.
- `scenarios/`: one folder per reproducible incident (bad image, missing Secret reference, OOM, unschedulable pod,
  broken KEDA trigger, invalid manifest, StatefulSet OOM), each with a `README.md` (what breaks, the expected diagnosis and the
  expected PR or refusal), an `expected.yaml` (schema in `scenarios/schema/`) and the broken versions of files
  under `apps/demo/`, at `scenarios/<name>/apps/demo/<file>`. Layout and schema: `scenarios/README.md`.
- `scripts/`: `render.sh` (the render check), `scenario.sh` (the scenario harness), `kind.sh` (the Kind cluster),
  `install-tools.sh`, `lib.sh`, and `tools.env`, the one place every tool version and checksum is pinned.
- `Makefile`: entry points, one script call each. `tests/`: offline tests of the scripts.

## Scenarios (ADR-0022)

Each cluster's Flux tracks its own branch, `cluster/kind` or `cluster/lab`, never `main`. `make scenario-<name>
CLUSTER=kind|lab` commits `main`'s tree with the scenario's files over `apps/demo/` on top of that branch, and
`make scenario-reset CLUSTER=kind|lab` commits `main`'s tree; both push fast-forwards only. The harness refuses
unless the `GitRepository` `flux-system/fleet` in the current kube context tracks exactly `cluster/<CLUSTER>`. Never
add a way for scripts here to write `main`, force-push, or create or delete a branch, and keep `push_cluster_branch`
in `scripts/scenario.sh` the only `git push`. A push never uses `SCENARIO_REF` (it is for `list` and `DRY_RUN=1`
only): `apply` refuses it without `DRY_RUN=1`, so a push is always built from `origin/main`.

## Rules

- `main` is protected: changes only through PRs with required checks. That applies to the operator's GitHub App as well; it never gets bypass rights.
- Files the operator may patch are listed in its policy config; anything else (Flux config, RBAC, Secrets, workflows, branch protection) is human-only.
- Environment values (tenant and identity client IDs, endpoints, the operator namespace) come from Flux
  `postBuild.substitute`, filled by `shadewright-azure` (the `flux` output of `lab/flux.tf`, applied by `scripts/lab.sh`). Never hard-code them here. Substitutions
  apply only to the Kustomization that declares them: `clusters/lab/infrastructure.yaml` forwards them as
  `${VAR}` to `infrastructure/`; forward a variable to `apps` the same way when a workload needs one.
- No Secrets in Git, not even encrypted.

## Checks

```bash
make tools            # pinned kustomize, kubeconform, kind, kubectl, shellcheck into bin/ (git-ignored)
scripts/render.sh     # kustomize build of clusters/, infrastructure/, apps/, kubeconform -strict, Flux paths exist
make lint test        # shellcheck and the offline tests of scripts/ (tests/)
make check-scenarios  # every scenario: layout, expected.yaml against the schema, render as declared
```

`render.sh` and the harness refuse kustomize and kubeconform versions other than those in `scripts/tools.env`;
`bin/` comes first on `PATH` (the tests set `FLEET_TOOLS_DIR` to an empty directory so their stubs win). A new kustomization is picked up automatically. Scripts must run on macOS bash 3.2 and
GNU Make 3.81 as well as Linux, pass shellcheck, and come with offline tests.

Rules on `main` (set in the ruleset by the maintainer; README, "Rules on `main`"): one approval of the most
recent push, code owner review, the repository admin role as the only bypass actor (pull requests only), never the App. Required checks:

- `Conventional PR title` (`.github/workflows/pr-title.yml`).
- `Path guard` (`.github/workflows/path-guard.yml`; required once the maintainer applies the ruleset): fails when a
  pull request changes (or renames from or to) any path outside `.github/shadewright-paths.txt`, which starts with
  `apps/**`, or changes a symlink or submodule. It runs on `pull_request_target` so the workflow, the list and
  `scripts/path_guard.py` are the base copies, and it only ever reads the head through the API (file list, Git
  tree). Never check out or run the head there, and never interpolate PR text into a shell. `.github/`, `clusters/`,
  `infrastructure/`, `scripts/`, `tests/`, `Makefile` and every root file are refused whatever the list says.
  Remaining gap: a pull request can add a new workflow whose job is also named `Path guard`. So `.github/` always
  stays code-owned (`.github/CODEOWNERS` gives `*` a human owner) and is never on the allow list; code owner review
  is what protects the guard itself.
- `Render manifests` (`.github/workflows/render.yaml`): every kustomization under `clusters/`, `infrastructure/` and `apps/` renders and passes the schema check for the lab's Kubernetes version, and every Flux `path:` in `clusters/` exists. `scenarios/` (deliberately broken) is left out.

Not required (yet): `Harness tests` (`.github/workflows/harness.yaml`: shellcheck, `tests/`, `make check-scenarios`)
and `Kind baseline` (`.github/workflows/kind.yaml`: a Kind cluster with Flux on the commit under test, read-only,
until the healthy baseline is Ready).

## Commits

Every commit on `main` follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):
`type(scope)!: summary`. Pull requests are squash-merged with the pull request title as the commit message,
so the **pull request title** is what counts; a required check (`Conventional PR title`) validates it.

- Types: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `ci`, `chore`, `revert`.
- Scope is optional; when used it is one of: `clusters`, `infrastructure`, `apps`, `scenarios`, `docs`, `ci`, `deps`.
- Summary in English, imperative, starting lower case, no full stop: `feat(policy): refuse decreases by default`.
- `!` after the type or scope, plus a `BREAKING CHANGE:` footer in the description, for incompatible changes
  (API fields, CRD schema, flags, Helm values).
- This repository is not released; the convention keeps the history readable and consistent with the operator.

## Working agreement

- Every change goes through a branch and a pull request; `main` is protected by a ruleset (required checks,
  squash merge, no force push). Keep pull requests small and say why in the description.
- Run `scripts/render.sh` locally before opening a pull request, and add or update tests in the same pull request.
- Leave the code safer than you found it: when you notice a security or reliability problem nearby, fix it
  or raise it in the pull request, do not ignore it.
- Prefer boring, well-known solutions and the project's existing patterns over new dependencies or clever code.

## Engineering and security practices

Manifests here follow the Kubernetes Pod Security "restricted" profile unless a scenario deliberately breaks
something, and then the scenario's README says what and why:

- Images pinned by tag and digest, never `latest`.
- `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, all capabilities
  dropped, `seccompProfile: RuntimeDefault`.
- Resource requests and limits on every container; liveness and readiness probes on long-running ones.
- A default-deny NetworkPolicy per namespace, with explicit allows.
- ServiceAccounts with `automountServiceAccountToken: false` unless the workload needs the API, and then a
  namespaced Role with the minimal verbs.

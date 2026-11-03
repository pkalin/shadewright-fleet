# shadewright-fleet: guide for coding agents

The GitOps repo for the Shadewright lab cluster, synced by Flux. It is also the repo the Shadewright operator opens remediation pull requests against, so its layout and branch protection are part of the demo.

## Layout

- `clusters/lab/`: Flux entry point. `shadewright-azure` (`lab/flux.tf`) creates the Flux configuration `fleet`
  through the AKS extension: a `GitRepository` named `fleet` and a Kustomization that applies this path, both in
  `flux-system`. This path holds no `flux-system` manifests of its own, only two Flux `Kustomization` objects:
  `infrastructure`, then `apps` (`dependsOn`), each with `prune: true` and `wait: true`. The extension enforces
  multi-tenancy, so every Flux object stays in `flux-system` and references sources in that namespace.
- `infrastructure/`: cluster add-ons and the namespaces `apps/` needs; later Shadewright itself (Helm chart from
  the operator repo).
  - `namespaces/`: the `demo` Namespace. It belongs to the demo workloads but lives here because infrastructure
    objects bind in it before `apps` is applied (the analyzer's RoleBinding from the operator's `config/watch`,
    Prometheus' scrape target). Flux applies Namespaces before other objects of the same Kustomization, and
    `infrastructure` before `apps`, so it always exists first. Put any other namespace that `infrastructure/`
    refers to but `apps/` fills here too.
  - `keda/`: KEDA from the upstream chart (not the AKS add-on), one replica per component.
  - `prometheus/`: a minimal Prometheus (ADR-0017): server and kube-state-metrics, kubelet and cAdvisor
    targets, 24h retention on an emptyDir, no Alertmanager or Grafana. In-cluster URL
    `http://prometheus-server.prometheus.svc`.
  - Each add-on has its own namespace (restricted Pod Security labels, default-deny NetworkPolicy and explicit
    allows) and a `HelmRepository` and `HelmRelease` in `flux-system` (multi-tenancy) with `targetNamespace`.
    Charts are pinned to exact versions and images to tag and digest in the values; bump them together.
- `apps/`: small workloads used as remediation targets, under `apps/demo/`: `web` (Deployment and Service) and
  `worker` (Deployment, Service and a KEDA `ScaledObject` with a Prometheus trigger), both podinfo. One object per
  file and kustomizations with `resources` only, because the operator's source mapping (ADR-0012) supports plain
  manifests only; values the patchers change (memory limits, `maxReplicaCount`) stay literal. The worker has no
  `spec.replicas`: the HPA that KEDA creates owns it.
- `scenarios/` (planned): one folder per reproducible incident (bad image, missing Secret reference, OOM, unschedulable pod, broken KEDA trigger, invalid manifest), each with what breaks, the expected diagnosis and the expected PR, or the expected refusal.
- `scripts/render.sh`: the render check, run by CI and locally.

## Rules

- `main` is protected: changes only through PRs with required checks. That applies to the operator's GitHub App as well; it never gets bypass rights.
- Files the operator may patch are listed in its policy config; anything else (Flux config, RBAC, Secrets, workflows, branch protection) is human-only.
- Environment values (tenant and identity client IDs, endpoints, the operator namespace) come from Flux
  `postBuild.substitute`, filled by `shadewright-azure` (`lab/flux.tf`). Never hard-code them here. Substitutions
  apply only to the Kustomization that declares them: `clusters/lab/infrastructure.yaml` forwards them as
  `${VAR}` to `infrastructure/`; forward a variable to `apps` the same way when a workload needs one.
- No Secrets in Git, not even encrypted.

## Checks

```bash
scripts/render.sh   # kustomize build of clusters/, infrastructure/, apps/, kubeconform -strict, Flux paths exist
```

It needs `kustomize` and `kubeconform` on `PATH` (or `KUSTOMIZE=` and `KUBECONFORM=` pointing at them); CI pins both
by version and checksum in `.github/workflows/render.yaml`. A new kustomization is picked up automatically.

Rules on `main` (set in the ruleset by the maintainer; README, "Rules on `main`"): one approval of the most
recent push, the repository admin role as the only bypass actor (pull requests only), never the App. Required checks:

- `Conventional PR title` (`.github/workflows/pr-title.yml`).
- `Render manifests` (`.github/workflows/render.yaml`): every kustomization under `clusters/`, `infrastructure/` and `apps/` renders and passes the schema check for the lab's Kubernetes version, and every Flux `path:` in `clusters/` exists. `scenarios/` (deliberately broken) is left out.

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

# shadewright-fleet: guide for coding agents

The GitOps repo for the Shadewright lab cluster, synced by Flux. It is also the repo the Shadewright operator opens remediation pull requests against, so its layout and branch protection are part of the demo.

## Layout

- `clusters/lab/`: Flux entry point. `shadewright-azure` (`lab/flux.tf`) creates the Flux configuration `fleet`
  through the AKS extension: a `GitRepository` named `fleet` and a Kustomization that applies this path, both in
  `flux-system`. This path holds no `flux-system` manifests of its own, only two Flux `Kustomization` objects:
  `infrastructure`, then `apps` (`dependsOn`), each with `prune: true` and `wait: true`. The extension enforces
  multi-tenancy, so every Flux object stays in `flux-system` and references sources in that namespace.
- `infrastructure/`: Shadewright itself (Helm chart from the operator repo), KEDA and anything the scenarios need.
  Empty for now.
- `apps/`: small workloads used as remediation targets, under `apps/demo/`. Empty for now.
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
scripts/render.sh   # kustomize build of every kustomization, then kubeconform -strict with the Flux CRD schemas
```

It needs `kustomize` and `kubeconform` on `PATH` (or `KUSTOMIZE=` and `KUBECONFORM=` pointing at them); CI pins both
by version and checksum in `.github/workflows/render.yaml`. A new kustomization is picked up automatically.

Required checks on `main` (set in the ruleset by the maintainer):

- `Conventional PR title` (`.github/workflows/pr-title.yml`).
- `Render manifests` (`.github/workflows/render.yaml`): every kustomization renders and passes the schema check.

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

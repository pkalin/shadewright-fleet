# shadewright-fleet: guide for coding agents

The GitOps repo for the Shadewright lab cluster, synced by Flux. It is also the repo the Shadewright operator opens remediation pull requests against, so its layout and branch protection are part of the demo.

## Layout (planned)

- `clusters/lab/`: Flux entry point (`flux-system`, Kustomizations for `infrastructure` then `apps`).
- `infrastructure/`: Shadewright itself (Helm chart from the operator repo), KEDA and anything the scenarios need.
- `apps/demo/`: small workloads used as remediation targets.
- `scenarios/`: one folder per reproducible incident (bad image, missing Secret reference, OOM, unschedulable pod, broken KEDA trigger, invalid manifest), each with what breaks, the expected diagnosis and the expected PR, or the expected refusal.

## Rules

- `main` is protected: changes only through PRs with required checks. That applies to the operator's GitHub App as well; it never gets bypass rights.
- Files the operator may patch are listed in its policy config; anything else (Flux config, RBAC, Secrets, workflows, branch protection) is human-only.
- Environment values (cluster name, identity client IDs, registry) come from Flux `postBuild.substitute`, filled by `shadewright-azure`. Never hard-code them here.
- No Secrets in Git, not even encrypted.

## Checks

```bash
kustomize build clusters/lab >/dev/null   # every Kustomization renders
```

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
- Run `kustomize build clusters/lab` locally before opening a pull request, and add or update tests in the same pull request.
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

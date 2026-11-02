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

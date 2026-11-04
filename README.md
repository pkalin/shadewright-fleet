<p align="center"><img src=".github/logo.png" alt="Shadewright" width="120"></p>

# shadewright-fleet

The GitOps repository for the [Shadewright](https://shadewright.io) lab cluster, synced by Flux. The Shadewright operator opens its remediation pull requests here, so this repository's layout and branch rules are part of the demo.

## Layout

```text
clusters/lab/           Flux entry point, applied by the Flux configuration from shadewright-azure
  kustomization.yaml
  infrastructure.yaml   Flux Kustomization for infrastructure/
  shadewright.yaml      Flux Kustomization for the agent, after infrastructure, independent of apps
  apps.yaml             Flux Kustomization for apps/, after infrastructure is ready
clusters/kind/          the same for a Kind cluster (scripts/kind.sh), without Azure substitutions
infrastructure/         cluster add-ons and the namespaces apps/ needs
  shadewright/          the agent, vendored from the operator repo (scripts/vendor-shadewright.sh, VENDOR)
  shadewright-lab/      lab values for it (workload identity client IDs), applied by clusters/lab/shadewright.yaml
  namespaces/           the demo Namespace, created before anything binds in it
  keda/                 KEDA (upstream chart, one replica per component)
  prometheus/           minimal Prometheus: server, kube-state-metrics, kubelet and cAdvisor, 24h retention
apps/                   demo workloads the scenarios break
  demo/                 web (podinfo) and worker (podinfo scaled by a KEDA ScaledObject on a Prometheus query)
scenarios/              reproducible incidents: the broken files, what breaks and what Shadewright must conclude
scripts/render.sh       render check: kustomize build and kubeconform on what Flux applies
scripts/scenario.sh     scenario harness: make scenario-<name> and scenario-reset CLUSTER=kind|lab
scripts/kind.sh         Kind cluster with Flux pointed at this repository: make kind-up, kind-wait, kind-down
scripts/tools.env       every pinned tool version and checksum (make tools installs them into bin/)
```

Environment values (tenant and identity client IDs, endpoints, the operator namespace) are never in this
repository: they arrive as Flux `postBuild` substitutions (`${VAR}`) from the lab's Terraform.

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

## License

Apache License 2.0, see [LICENSE](LICENSE).

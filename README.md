<p align="center"><img src=".github/logo.png" alt="Shadewright" width="120"></p>

# shadewright-fleet

The GitOps repository for the [Shadewright](https://shadewright.io) lab cluster, synced by Flux. The Shadewright operator opens its remediation pull requests here, so this repository's layout and branch rules are part of the demo.

## Layout

```text
clusters/lab/           Flux entry point, applied by the Flux configuration from shadewright-azure
  kustomization.yaml
  infrastructure.yaml   Flux Kustomization for infrastructure/
  apps.yaml             Flux Kustomization for apps/, after infrastructure is ready
infrastructure/         cluster add-ons and the namespaces apps/ needs (Shadewright later)
  namespaces/           the demo Namespace, created before anything binds in it
  keda/                 KEDA (upstream chart, one replica per component)
  prometheus/           minimal Prometheus: server, kube-state-metrics, kubelet and cAdvisor, 24h retention
apps/                   demo workloads the scenarios break
  demo/                 web (podinfo) and worker (podinfo scaled by a KEDA ScaledObject on a Prometheus query)
scripts/render.sh       render check: kustomize build and kubeconform on what Flux applies
```

Environment values (tenant and identity client IDs, endpoints, the operator namespace) are never in this
repository: they arrive as Flux `postBuild` substitutions (`${VAR}`) from the lab's Terraform.

## Checks

Every pull request runs `Render manifests`: each kustomization must build and pass `kubeconform -strict` with
the Flux CRD schemas. Run the same check locally with `scripts/render.sh`. The full rules and planned layout
are in [AGENTS.md](AGENTS.md).

## License

Apache License 2.0, see [LICENSE](LICENSE).

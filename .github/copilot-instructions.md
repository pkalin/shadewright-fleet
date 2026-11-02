# Review instructions

`AGENTS.md` at the repository root is the source of truth for this project. This repository is synced by Flux to a lab cluster, and the Shadewright operator opens remediation pull requests here. Comment only on real problems.

## What to check in every pull request

- **Remediation pull requests** (branches `shadewright/<uid>`) must change only the one file and the one value their description names, within the bounds of the policy it cites. Flag any other file, an extra document, changed comments far from the edited value, or a value that does not match the "desired" in the description.
- **Human-only paths.** Flux configuration (`clusters/`, `flux-system`), RBAC, Secrets, `.github/`, `CODEOWNERS` and policy objects must never change in a remediation pull request.
- **No Secrets in Git**, not even encrypted. No subscription, tenant or object IDs, IP addresses or emails; environment values come from Flux `postBuild.substitute`.
- **Manifests render.** `kustomize build clusters/lab` must succeed; flag references to files that do not exist.
- **Scenarios** under `scenarios/` must state what breaks, the expected diagnosis and the expected pull request or refusal.
- No long dashes (em or en) in text.

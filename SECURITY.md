# Security policy

This is the GitOps repository of the Shadewright reference lab. Its workloads are broken on purpose (they are
the incident scenarios), so a crashing or misconfigured demo workload is not a vulnerability.

## Reporting a vulnerability

Report privately through GitHub: [open a security advisory for this repository](https://github.com/pkalin/shadewright-fleet/security/advisories/new).
The form is private: only the maintainer sees it. Do not open a public issue or pull request for a vulnerability.

In scope here: a way for a pull request opened by the operator to merge without the review the branch rules
require, a workflow or manifest that would run with more permissions than the lab grants, or a change that
would make Flux apply something outside the lab's namespaces. A problem in the operator itself belongs in the
[operator's advisory form](https://github.com/pkalin/shadewright/security/advisories/new); its
[security policy](https://github.com/pkalin/shadewright/blob/main/SECURITY.md) describes scope and timelines.

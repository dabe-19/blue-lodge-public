---
trigger: glob
globs:**/{*.{tf,tfvars,hcl,bicep},cloudformation/**/*.{yaml,yml,json},{k8s,kubernetes,manifests}/**/*.{yaml,yml},helm/**/*.{yaml,yml,tpl}}
---

# Infrastructure-as-Code Standards

- **State Is Sacred**: Remote state (S3+DynamoDB, Azure Storage, Terraform Cloud, Pulumi Service) only. Never commit `.tfstate`. Enable state locking unconditionally.
- **Plan Before Apply**: All changes go through `plan` review (in PR or pre-merge CI). `apply` runs only from a protected branch via CI, never from a developer laptop in production.
- **No Hard-Coded Secrets**: Reference secrets via the platform's secret store (AWS Secrets Manager, Azure Key Vault, Vault, sealed-secrets). Never commit credentials, even encrypted, alongside IaC.
- **Modules Over Copy-Paste**: Repeated infrastructure patterns become reusable modules. Pin module versions; do not reference `main`/`HEAD`.
- **Variables and Outputs**: Every input variable declares `type`, `description`, and (when sensible) `default` and `validation`. Every output declares `description`.
- **Tag Everything**: Apply standard tags/labels to every resource: `environment`, `owner`, `cost-center`, `managed-by=terraform` (or equivalent). Enforce via policy, not convention.
- **Immutable Infrastructure**: Build new, swap traffic, retire old. Avoid in-place mutation of long-lived resources when blue/green or rolling replacement is feasible.
- **Drift Detection**: Schedule `terraform plan` (or equivalent) on a recurring CI job. Alert when remote state diverges from code.
- **Least Privilege**: IAM/RBAC roles created by IaC start with zero permissions and add only what the workload demonstrably needs. Wildcard `*` on `Action` or `Resource` requires written justification.
- **Network Posture**: Default-deny security groups / NSGs / NetworkPolicies. Explicit allow rules with comments explaining the need.
- **Kubernetes Specifics**: Always set `resources.requests` and `resources.limits`. Always set `securityContext.runAsNonRoot: true` and `readOnlyRootFilesystem: true` unless documented otherwise. Use `PodDisruptionBudget` for any workload with replicas > 1.
- **Validation in CI**: `terraform validate`, `terraform fmt -check`, `tflint`, `tfsec`/`checkov`, `kubeval`/`kubeconform`, `kustomize build | kubectl apply --dry-run=client`. All gates run on every PR.

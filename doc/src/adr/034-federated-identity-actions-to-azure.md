# ADR-034: Federated Identity for Actions to Azure

## Context

- Deploy and integration-test workflows need Azure access (AKS + Key Vault).
- Static `AZURE_CREDENTIALS` JSON secrets are long-lived credentials and increase risk.
- CI credentials must be isolated per service fork to reduce blast radius.

## Decision

- Use one User-Assigned Managed Identity per service fork and authenticate GitHub Actions through OIDC (`azure/login@v2`) instead of static JSON credentials.
- Federated credential subjects must cover:
  - `repo:${ORG}/${SERVICE}:ref:refs/heads/*`
  - `repo:${ORG}/${SERVICE}:pull_request`
  - `repo:${ORG}/${SERVICE}:ref:refs/tags/*`
- Use three repo secrets as the handoff contract from onboarding to workflows:
  - `AZURE_CLIENT_ID`
  - `AZURE_TENANT_ID`
  - `AZURE_SUBSCRIPTION_ID`
- Keep the ~20-step onboarding automated but split on the credential boundary:
  - **Cluster side (`osdu-spi-stack`, `spi onboard`)**: identity creation, federated credentials, AKS/KV RBAC, and Kubernetes RoleBinding; writes the three `AZURE_*` secrets to the target repo.
  - **Fork side (`osdu-spi`, extended `init.yml`)**: GHCR visibility, ruleset setup, and per-service repository variables.

## Consequences

- ✅ No long-lived Azure credential material stored in GitHub.
- ✅ Per-fork identity limits impact if one repository is compromised.
- ✅ Credential and repository setup responsibilities are explicit and automatable.
- ⚠️ Setup remains operationally heavy without automation, so `spi onboard` + `init.yml` coordination is required.
- ⚠️ Subject-claim mismatches (`refs/heads`, `pull_request`, `refs/tags`) cause authentication failures and require careful troubleshooting.

## Alternatives Considered

- **Keep static `AZURE_CREDENTIALS` secrets**
  - Rejected: long-lived secrets and larger compromise surface.
- **Use one shared identity for all service forks**
  - Rejected: poor blast-radius isolation and weaker service-level boundary control.

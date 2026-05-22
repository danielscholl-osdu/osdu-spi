# OSDU SPI CI/CD: Build, Deploy, Integration Test
## Detailed Design & Implementation Plan

**Status:** Draft — pre-implementation design  
**Authors:** Daniel Scholl (with Claude)  
**Date:** 2026-05-22  
**Target System:** `Azure/osdu-spi` engineering template + `osdu-spi-stack` runtime + 8 service forks

---

## 0. Executive Summary

The OSDU SPI engineering system today produces validated JAR artifacts via Maven build and unit tests, with code flowing through a three-branch fork management strategy. It does **not** produce container images, deploy to runtime infrastructure, or run integration tests against live services.

This design extends the engineering system with three new pipeline stages — **Docker Build → Deploy → Integration Test** — that run on the same per-push/per-PR cadence as the existing `validate.yml` and `build.yml` workflows. The new stages target a shared, long-lived `osdu-spi-stack` AKS environment whose Flux GitOps reconciliation is suspended after initial provisioning, allowing CI/CD workflows to directly patch service deployments via `kubectl set image`.

The design is delivered in two layers:

1. **Architecture** — what gets built, where it runs, how it's authenticated, what infrastructure must exist.
2. **Implementation Plan** — a five-phase rollout starting with a sandbox fork of the engineering system, validated against the existing `danielscholl-osdu/partition` fork, before any changes touch the official `Azure/osdu-spi` repository.

The single largest risk-reduction lever is the **sandbox engineering system**: a fork of `osdu-spi` in a separate org where workflow templates can be iterated without consequence to the eight production service forks that consume the official template.

---

## 1. Context & Current State

### 1.1 What exists today

**`Azure/osdu-spi`** — Fork Management Template repository. Acts as the central engineering system for all OSDU SPI service implementations. Documented across 31 ADRs (see `doc/src/adr/list.md`).

- Three-branch strategy (ADR-001): `main`, `fork_upstream`, `fork_integration`
- Template-workflow separation (ADR-015): `.github/template-workflows/` contains the workflows that get copied to forks during initialization, kept distinct from `.github/workflows/` which is for template development
- Template sync (ADR-012, ADR-031): forks pull updates from the template via daily `template-sync.yml`, with duplicate-prevention to avoid PR accumulation
- Release Please for versioning (ADR-004) with meta-commit strategy (ADR-023)
- Java/Maven build (ADR-025): Java 17 Temurin, GitLab Maven repo integration, JaCoCo coverage

**Current per-fork pipeline (from `template-workflows/`):**

| Stage | Workflow | Trigger | Output |
|-------|----------|---------|--------|
| Validate | `validate.yml` | PR/push to main, fork_integration, fork_upstream | Maven build + unit tests + commit linting + branch checks |
| Build (branch) | `build.yml` | push to any branch except protected | Maven build + unit tests + coverage report |
| Release | `release.yml` | push to main | Release-Please PR, semantic version tags |
| Cascade | `cascade.yml` + `cascade-monitor.yml` | manual + monitor | Upstream → fork_upstream → fork_integration → main |
| Validate dependabot | `dependabot-validation.yml` | dependabot PRs | Isolated dependency validation |

**`osdu-spi-stack`** — Runtime infrastructure. Bicep + Flux GitOps deployment of full OSDU platform on AKS Automatic.

- One generic Helm chart `software/charts/osdu-spi-service/` used by all OSDU services (image + values overrides only)
- HelmReleases under `software/stacks/osdu/services/*.yaml` reference upstream community.opengroup.org GitLab image registry today
- `spi up/down/status/reconcile/info` Python CLI bootstraps and observes the cluster
- ACR provisioned as part of "Core Infra" phase (currently unused for service images — Flux pulls from community registry)
- Key Vault wired for centralized secrets, Workload Identity for service auth

**`danielscholl-osdu/partition`** — First SPI service fork, established 2026-05-22. Initialized from `Azure/osdu-spi` template. Contains:
- Forked partition source (Java multi-module Maven project, multiple cloud providers)
- `devops/azure/Dockerfile`, `devops/azure/chart/` (legacy, will become irrelevant — single chart in stack)
- `partition-acceptance-test/` Maven module (integration tests)
- `.gitlab-ci.yml` (legacy OSDU upstream CI — reference for what the upstream did, not to be run)
- Engineering system workflows inherited from osdu-spi template

### 1.2 What does not exist

- Container image build in the engineering system
- Image push to any registry as part of CI
- Deploy to any Kubernetes cluster as part of CI
- Integration test execution against a live service
- Cross-component authentication for CI to talk to AKS
- Per-fork managed identity provisioning automation
- A pattern for restricting Maven builds to the Azure provider profile

### 1.3 Why this work is needed

The validation signal from the engineering system today proves that code **compiles and unit-tests pass**. It does not prove the service:

- Builds into a runnable container
- Starts up in a real Kubernetes environment
- Responds to API calls correctly against real Azure PaaS dependencies (CosmosDB, Service Bus, Storage, Key Vault, Entra ID)

Without these signals, the only way to discover deployment regressions is at release time, when changes have already been committed to `main`. The cost of catching a regression late is high — the fork management model means changes from upstream can introduce subtle Azure-specific breakage that no unit test will catch.

---

## 2. Goals & Constraints

### 2.1 Goals

- **G1.** Every push/PR that runs build/validate today also produces a Docker image and deploys it to the shared cluster for integration testing.
- **G2.** Integration test failures block the PR (treated as a required check).
- **G3.** The mechanism is identical across all 8 services — partition is the reference implementation, the other 7 inherit via template-sync.
- **G4.** Workflows live in `osdu-spi/template-workflows/` (engineering system owns the recipe).
- **G5.** Per-fork runtime is independent — no fork modifies the stack repo or another fork's state.
- **G6.** Operational onboarding of a new service fork should be scripted, not manual ad-hoc steps.

### 2.2 Constraints (locked by user)

- **C1.** Triggers match existing `build.yml`/`validate.yml`. Same branches, same paths, same cadence. New stages are appended jobs in the existing pipeline, not new workflows on different triggers.
- **C2.** Container registry: **GHCR**, fork-owned. Packages must be **public** (decided by user) so AKS can pull without per-fork image-pull-secrets.
- **C3.** Maven build restricted to **`-P partition-azure`** (or the Azure-equivalent profile for each service). Other cloud provider profiles are not built. Faster validate, smaller blast radius.
- **C4.** Deploy target: **single shared `osdu-spi-stack` AKS environment**. Already running. Flux is **fully suspended** after initial bring-up so CI workflows have free reign.
- **C5.** Deploy mechanism: **`kubectl set image`** directly on existing Deployments. No Helm from CI, no HelmRelease editing — Flux is suspended, deployments live untouched.
- **C6.** Fork is independent at runtime: no cross-repo commits, no PRs to `osdu-spi-stack` from a service fork.
- **C7.** Implementation must be proven in a sandbox fork of the engineering system before any change lands in `Azure/osdu-spi`.

### 2.3 Non-goals

- **NG1.** Production-grade deployment. The CI cluster is for validation, not customer-facing serving.
- **NG2.** Per-PR ephemeral environments. Cost-prohibitive; deferred.
- **NG3.** Replacing Flux GitOps for the spi-stack. Flux still owns the initial baseline; CI just patches on top.
- **NG4.** Building or deploying non-Azure provider profiles. Out of scope for SPI work.
- **NG5.** Rollback automation. CI cluster is allowed to remain in a broken state between runs; next run overwrites.

---

## 3. Locked Decisions

For traceability, here are the decisions made during brainstorming that this design assumes:

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | Workflows in `osdu-spi/template-workflows/` | Consistent with ADR-015. Template-sync delivers to all forks. |
| D2 | New stages appended to existing per-PR pipeline | Matches existing build/validate cadence. No new trigger machinery. |
| D3 | GHCR for image registry | Simplest from Actions; native auth via `GITHUB_TOKEN` |
| D4 | GHCR packages public | Eliminates per-fork image-pull-secret provisioning |
| D5 | Maven build restricted to Azure profile only | Smaller build, smaller test surface, no value in building unused providers |
| D6 | Single shared spi-stack as deploy target | One env, low cost, fast feedback. Already running. |
| D7 | Flux fully suspended for CI period | Simplest coexistence. No race conditions with reconciliation. |
| D8 | `kubectl set image` for deploy | Atomic, transient, perfect for Flux-suspended model |
| D9 | Federated identity (OIDC) for Actions → Azure | No long-lived secrets, per-fork managed identity |
| D10 | Sandbox engineering system fork for development | Risk isolation — official template stays clean |
| D11 | Existing `danielscholl-osdu/partition` is the reference fork | Avoids creating disposable test services |

---

## 4. Architecture Overview

### 4.1 System diagram

```
                       ┌──────────────────────────────────┐
                       │  Azure/osdu-spi (TEMPLATE)       │
                       │  - template-workflows/           │
                       │  - .github/actions/              │
                       └──────────────┬───────────────────┘
                                      │ template-sync (daily)
                                      ▼
                       ┌──────────────────────────────────┐
                       │  Service fork (e.g. partition)   │
                       │  ┌────────────────────────────┐  │
                       │  │  CI pipeline (per push/PR) │  │
                       │  │   1. java-build (Azure -P) │  │
                       │  │   2. docker-build          │  │
                       │  │   3. ghcr-push             │  │
                       │  │   4. azure-oidc-login      │  │
                       │  │   5. aks-set-image         │  │
                       │  │   6. rollout-wait          │  │
                       │  │   7. acceptance-tests      │  │
                       │  └────────────────────────────┘  │
                       └──────────────┬───────────────────┘
                                      │
                ┌─────────────────────┼────────────────────┐
                │                     │                    │
                ▼                     ▼                    ▼
       ┌────────────────┐    ┌────────────────┐   ┌─────────────────┐
       │  GHCR          │    │  Azure         │   │  Key Vault      │
       │  ghcr.io/<org>/│    │  Managed       │   │  Acceptance     │
       │  <svc>:<sha>   │    │  Identity      │   │  test secrets   │
       │  (public)      │    │  per fork      │   │                 │
       └──────┬─────────┘    └────────┬───────┘   └────────┬────────┘
              │                       │                    │
              │ pull image            │ AKS RBAC           │ read
              ▼                       ▼                    ▼
       ┌─────────────────────────────────────────────────────────────┐
       │  osdu-spi-stack — Shared AKS Automatic cluster              │
       │  (Flux SUSPENDED post-bring-up)                             │
       │                                                             │
       │   namespace: osdu                                           │
       │    ├─ Deployment/partition  ← kubectl set image             │
       │    ├─ Deployment/entitlements                               │
       │    ├─ Deployment/legal, schema, file, storage, ...          │
       │                                                             │
       │   namespace: platform                                       │
       │    └─ Istio Gateway → exposes /api/partition/v1/* etc.      │
       └─────────────────────────────────────────────────────────────┘
```

### 4.2 Data flow per CI run

```
  Code push                                            Acceptance test
       │                                                       ▲
       ▼                                                       │
  validate.yml (existing)                            ┌─────────┴──────────┐
       │                                             │ Maven runs against │
       │ Maven build OK                              │ gateway URL with   │
       ▼                                             │ KV-sourced secrets │
  docker-build job (NEW)                             └─────────▲──────────┘
       │                                                       │
       │ docker build -f devops/azure/Dockerfile               │
       │ docker tag …:<sha> …:<branch>                         │
       │ docker push ghcr.io/<org>/<svc>:…                     │
       ▼                                                       │
  deploy job (NEW)                                             │
       │                                                       │
       │ azure/login (OIDC, federated ID)                      │
       │ az aks get-credentials                                │
       │ flux-suspend-assertion                                │
       │ kubectl set image deployment/<svc> -n osdu …          │
       │ kubectl rollout status deployment/<svc> -n osdu       │
       ▼                                                       │
  acceptance job (NEW)  ───────────────────────────────────────┘
```

### 4.3 Trust & authentication boundaries

```
GitHub Actions runner
   │
   ├─ Identity: GITHUB_TOKEN (for GHCR push)
   │
   ├─ Identity: Azure AD federated credential
   │            issuer: token.actions.githubusercontent.com
   │            subject: repo:<org>/<repo>:ref:refs/heads/*
   │            audience: api://AzureADTokenExchange
   │  ↓
   │  Azure AD → User-Assigned Managed Identity (per fork)
   │  ↓
   │  RBAC: Azure Kubernetes Service Cluster User Role
   │        scoped to spi-stack AKS resource
   │  ↓
   │  Kubernetes RBAC: namespaced edit role on `osdu` namespace
   │  ↓
   │  kubectl can: get/list/patch deployments in osdu ns
   │              get pods/logs in osdu ns (for debugging)
   │              NOT delete deployments, NOT touch cluster-scoped resources
   │
   └─ Identity: Same managed identity, additional Key Vault Secret User role
                scoped to spi-stack-shared-kv
                allows reading acceptance test credentials
```

Three identities total per CI run, all stitched through federated credentials. No long-lived secrets stored in GitHub.

---

## 5. Component Design

### 5.1 Docker Build

**Inputs:**
- Built JAR artifacts from `java-build` job (already produced by existing workflow)
- `devops/azure/Dockerfile` from service repo

**Outputs:**
- Image pushed to `ghcr.io/<org>/<service>:<sha>` (always)
- Image pushed to `ghcr.io/<org>/<service>:<branch>` (on push)
- Image pushed to `ghcr.io/<org>/<service>:<version>` (on release-please tag)

**Trigger:** Same as existing `build.yml` and `validate.yml`. Runs after `java-build` job succeeds.

**Implementation surface:**

| Artifact | Type | Location |
|----------|------|----------|
| `docker-build` job | Job block | `template-workflows/build.yml` and `template-workflows/validate.yml` (added after `java-build`) |
| `docker-build` composite action | Composite action | `.github/actions/docker-build/action.yml` |
| Dockerfile | Per-service | `devops/azure/Dockerfile` (already in partition fork) |

**Composite action contract:**

```
inputs:
  dockerfile_path:        default 'devops/azure/Dockerfile'
  build_context:          default '.'
  image_name:             required (e.g. 'partition')
  registry:               default 'ghcr.io'
  org:                    default '${{ github.repository_owner }}'
  jar_artifact_name:      default 'build-artifacts'
  build_args:             optional

outputs:
  image_digest:           sha256 digest of pushed image
  image_tags:             comma-separated tags pushed
```

**Failure modes:**
- Dockerfile missing → job fails with clear message pointing at `devops/azure/Dockerfile`
- JAR artifact missing (java-build skipped or failed) → job is skipped (`needs: java-build`)
- GHCR push fails (rate limit, network) → job fails, retried by re-running workflow
- Image too large (>1GB) → warning surfaced, not blocking initially

**Open question:** Should we tag with the Maven `revision` (`${branch}-SNAPSHOT`) as well, to match how java-build versions JARs today? Probably yes for traceability — image tag matches JAR version.

### 5.2 Deploy

**Inputs:**
- Image reference from `docker-build` (digest preferred, tag acceptable)
- Service name (derives Kubernetes deployment name)
- Target namespace (default: `osdu`)
- Target cluster (resolved from repo variables)

**Outputs:**
- Deployment updated and rolled out
- New pod ready and healthy (liveness + readiness probes passing)

**Trigger:** `needs: docker-build`

**Implementation surface:**

| Artifact | Type | Location |
|----------|------|----------|
| `deploy` job | Job block | `template-workflows/build.yml` and `template-workflows/validate.yml` |
| `aks-deploy` composite action | Composite action | `.github/actions/aks-deploy/action.yml` |

**Composite action contract:**

```
inputs:
  azure_client_id:        required (from repo secret/var)
  azure_tenant_id:        required
  azure_subscription_id:  required
  aks_resource_group:     required
  aks_cluster_name:       required
  namespace:              default 'osdu'
  deployment_name:        required
  container_name:         default same as deployment_name
  image_ref:              required (full image:tag or image@digest)
  rollout_timeout:        default '5m'

outputs:
  rollout_status:         'success' | 'timeout' | 'failed'
  pod_logs_url:           link to GitHub log artifact with pod logs on failure
```

**Flux-suspend pre-check:**

Before patching, verify cluster is in CI mode. Implementation:

```bash
# Pre-check: ensure Flux Kustomizations are suspended
suspended=$(kubectl get kustomizations -n flux-system -o json | \
  jq -r '.items[] | select(.spec.suspend != true) | .metadata.name')
if [ -n "$suspended" ]; then
  echo "::error::Flux Kustomizations not suspended: $suspended"
  echo "Run: flux suspend kustomization --all"
  exit 1
fi
```

This is essential. Without it, a workflow run during Flux reconciliation will see its image revert mid-test, producing flaky failures with mysterious causes.

**Concurrency lock:**

```yaml
concurrency:
  group: spi-stack-osdu-deploy
  cancel-in-progress: false
```

Cluster-wide lock. Only one service's deploy runs at a time. Prevents two services from racing each other into the same namespace. `cancel-in-progress: false` because cancelling a deploy mid-rollout leaves the cluster in a partially-deployed state.

**Failure modes:**
- Azure login fails → check federated credential subject claim matches `repo:<org>/<repo>:ref:refs/heads/<branch>`
- AKS credentials fetch fails → managed identity missing RBAC binding
- `kubectl set image` succeeds but rollout times out → fetch pod logs, attach as artifact, fail job
- Flux not suspended → fail-fast at pre-check, surface operator action required

### 5.3 Integration Test

**Inputs:**
- Service name (resolves to acceptance test directory)
- Gateway URL (from repo variable — typically `https://<gateway-host>`)
- Acceptance test credentials (from Key Vault)

**Outputs:**
- JUnit results
- Test summary in PR comment

**Trigger:** `needs: deploy`

**Implementation surface:**

| Artifact | Type | Location |
|----------|------|----------|
| `integration-test` job | Job block | `template-workflows/build.yml` and `template-workflows/validate.yml` |
| `integration-test` composite action | Composite action | `.github/actions/integration-test/action.yml` |

**Composite action contract:**

```
inputs:
  test_dir:               default '${service_name}-acceptance-test'
  gateway_url:            required
  keyvault_name:          required
  secret_map:             JSON map of env-var-name → kv-secret-name
  maven_goal:             default 'verify'
  maven_profile:          optional

outputs:
  test_result:            'pass' | 'fail'
  test_report_url:        link to uploaded JUnit XML artifact
```

**Secret retrieval:**

```bash
# Pull secrets from Key Vault into env vars
for env_name in $(jq -r 'keys[]' <<< "$SECRET_MAP"); do
  secret_name=$(jq -r ".[\"$env_name\"]" <<< "$SECRET_MAP")
  value=$(az keyvault secret show --vault-name "$KV_NAME" --name "$secret_name" --query value -o tsv)
  echo "$env_name=$value" >> "$GITHUB_ENV"
done
```

This pattern matches how the partition acceptance tests expect their config (env vars like `PARTITION_BASE_URL`, `INTEGRATION_TESTER`, etc.). Mapping is per-service in the workflow input.

**Failure modes:**
- Key Vault access denied → managed identity missing `Key Vault Secrets User` role
- Test connection refused → service not actually ready (rollout wait insufficient, or pod crashed post-readiness)
- Test failures (real) → upload JUnit report, fail job
- Maven download flake → already covered by existing Maven settings

### 5.4 Cross-cutting: Build Pipeline Composition

The full updated `template-workflows/validate.yml` (and parallel structure in `build.yml`) job graph:

```
check-initialization
        │
        ▼
check-repo-state
        │
        ▼
   java-build          (existing — modified to use -P partition-azure)
        │
        ▼
   docker-build        (NEW)
        │
        ▼
     deploy            (NEW)
        │
        ▼
integration-test       (NEW)
        │
        ▼
  code-validation      (existing)
```

Note: `code-validation` runs in parallel with the new jobs in the existing structure. We can keep it parallel — it doesn't depend on deploy.

---

## 6. Authentication & Authorization

### 6.1 Federated Identity Setup (per service fork)

For each service fork (one-time setup, automated via script):

1. **Create User-Assigned Managed Identity:**
   ```
   az identity create \
     --name "spi-ci-${SERVICE}" \
     --resource-group "${RG_IDENTITIES}" \
     --location "${LOCATION}"
   ```

2. **Add federated credential for GitHub Actions:**
   ```
   az identity federated-credential create \
     --name "github-actions-${SERVICE}" \
     --identity-name "spi-ci-${SERVICE}" \
     --resource-group "${RG_IDENTITIES}" \
     --issuer "https://token.actions.githubusercontent.com" \
     --subject "repo:${ORG}/${SERVICE}:ref:refs/heads/main" \
     --audience "api://AzureADTokenExchange"
   ```
   Repeat with `:ref:refs/heads/fork_integration`, `:ref:refs/heads/fork_upstream`, and `:pull_request` subjects.

3. **AKS RBAC:**
   ```
   # Cluster-level: allow getting credentials
   az role assignment create \
     --assignee "${IDENTITY_PRINCIPAL_ID}" \
     --role "Azure Kubernetes Service Cluster User Role" \
     --scope "/subscriptions/.../managedClusters/${AKS_NAME}"

   # Namespace-level: edit on osdu namespace (via K8s RoleBinding)
   kubectl create rolebinding "spi-ci-${SERVICE}" \
     --namespace osdu \
     --clusterrole edit \
     --user "${IDENTITY_OBJECT_ID}"
   ```

4. **Key Vault access:**
   ```
   az role assignment create \
     --assignee "${IDENTITY_PRINCIPAL_ID}" \
     --role "Key Vault Secrets User" \
     --scope "${KV_RESOURCE_ID}"
   ```

5. **GitHub repo configuration:**
   - Add **secrets:** `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
   - Add **variables:** `AKS_RESOURCE_GROUP`, `AKS_CLUSTER_NAME`, `KEYVAULT_NAME`, `GATEWAY_URL`, `SERVICE_NAME`, `K8S_NAMESPACE`

This is roughly ~20 steps per service. Automation is essential — see Section 7.

### 6.2 GitHub Actions OIDC integration

The workflow uses `azure/login@v2` with OIDC:

```yaml
- uses: azure/login@v2
  with:
    client-id: ${{ secrets.AZURE_CLIENT_ID }}
    tenant-id: ${{ secrets.AZURE_TENANT_ID }}
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

Requires `permissions: id-token: write` at job or workflow level.

### 6.3 Permission summary

| Identity | Permission | Scope | Purpose |
|----------|-----------|-------|---------|
| `GITHUB_TOKEN` | `packages: write` | Service repo's GHCR namespace | Push container images |
| `GITHUB_TOKEN` | `id-token: write` | Workflow run | Mint OIDC token for Azure login |
| Managed Identity | AKS Cluster User | AKS resource | Get kubeconfig |
| Managed Identity | K8s `edit` role | `osdu` namespace | Patch deployments |
| Managed Identity | Key Vault Secrets User | Shared KV | Read acceptance test secrets |
| AKS kubelet identity | AcrPull | (Not needed — GHCR is public) | N/A |

---

## 7. Infrastructure Requirements

### 7.1 What `osdu-spi-stack` provides today

- AKS Automatic cluster (provisioned via `spi up`)
- Flux CD extension installed and reconciling from stack git repo
- `osdu` namespace with 9 services deployed from community.opengroup.org images
- Istio Gateway exposing `/api/partition/v1/*` etc.
- Key Vault with workload identity secrets
- Workload Identity Service Account (`workload-identity-sa`) in osdu namespace

### 7.2 What must be added/changed

**One-time, per cluster:**

1. **CI mode toggle in stack:** Document/script the "switch to CI mode" sequence:
   ```
   flux suspend kustomization --all -n flux-system
   ```
   Could become a new `spi reconcile --ci-mode` subcommand in the stack CLI.

2. **Identity resource group:** Dedicated RG to host all per-fork managed identities, separate from the main spi-stack RG so identities survive cluster teardowns:
   ```
   az group create --name "rg-osdu-spi-ci-identities" --location "..."
   ```

**Per service fork (8x):**

3. **Managed identity** — see Section 6.1.
4. **GitHub secrets/variables** — see Section 6.1.
5. **K8s RoleBinding** in osdu namespace — see Section 6.1.

### 7.3 Shared cluster state

A few values are shared across all forks and should be exposed as **organization-level GitHub variables** (set once for `danielscholl-osdu` org, inherited by all repos):

| Variable | Value (example) | Notes |
|----------|----------------|-------|
| `AKS_RESOURCE_GROUP` | `spi-stack-ci` | RG hosting the cluster |
| `AKS_CLUSTER_NAME` | `aks-spi-stack-ci` | Cluster name |
| `KEYVAULT_NAME` | `kv-spi-stack-ci` | Shared KV for test secrets |
| `GATEWAY_URL` | `https://gateway.spi-ci.example.com` | Gateway base URL |
| `K8S_NAMESPACE` | `osdu` | All services in one namespace |
| `AZURE_TENANT_ID` | `<tenant-guid>` | Shared tenant |
| `AZURE_SUBSCRIPTION_ID` | `<sub-guid>` | Shared subscription |

Per-fork variables (must be set per repo):

| Variable | Value (per fork) |
|----------|------------------|
| `AZURE_CLIENT_ID` | The managed identity's client ID — unique per fork |
| `SERVICE_NAME` | `partition`, `entitlements`, etc. |

### 7.4 Image-pull from GHCR

Because GHCR packages are public (D4), AKS pulls without authentication. **No image pull secret required.**

If at any point a service's GHCR package gets accidentally made private, AKS pulls will fail with `ErrImagePull`. Add a CI step that verifies package visibility:

```bash
gh api "/users/${ORG}/packages/container/${SERVICE}/visibility" \
  --jq '.visibility' | grep -q 'public'
```

### 7.5 Cluster CI-mode invariants

When the cluster is "in CI mode":
- All Flux Kustomizations are suspended
- All HelmReleases are technically still "managed" but Flux is not reconciling
- Deployments live in their last-known state from Flux's last reconciliation
- CI workflows can `kubectl set image` freely
- `helm` and `flux` CLI users should be aware not to manually reconcile

To leave CI mode (e.g., for a baseline refresh):
1. Optionally reset images to their HelmRelease-declared values
2. `flux resume kustomization --all -n flux-system`
3. Flux reconciles, services revert to community images (or whatever the HelmRelease points at)

---

## 8. Operational Considerations

### 8.1 Concurrency between services

All 8 services share the `osdu` namespace. If `partition` and `entitlements` deploys race, the cluster sees:

```
T0: partition CI starts, target deploy/partition
T0: entitlements CI starts, target deploy/entitlements
```

No direct conflict — different deployments. **But** the acceptance tests for partition may depend on entitlements being healthy, and vice versa. A cross-service test failure may not be the testing service's fault.

**Mitigation:** Per-service concurrency, not cluster-wide:

```yaml
concurrency:
  group: spi-stack-${{ vars.SERVICE_NAME }}
  cancel-in-progress: false
```

This allows two services to deploy in parallel (different deployments) but two PRs for the same service queue. If cross-service contention causes test flakes, upgrade to cluster-wide `spi-stack-osdu-deploy`.

### 8.2 Cluster cleanup / drift

After many CI runs the cluster has drifted from Flux's declared state. To reset:

```
flux resume kustomization --all -n flux-system
# wait for reconciliation
flux suspend kustomization --all -n flux-system
```

This brings the cluster back to upstream community images. Useful weekly or when chasing strange behavior.

### 8.3 Test report integration

Acceptance test JUnit XML is uploaded as artifact. PR status is posted via existing `.github/actions/pr-status/` infrastructure (already used by validate.yml for build status):

```yaml
- name: Post integration test status
  uses: ./.github/actions/pr-status
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    pr_number: ${{ github.event.pull_request.number }}
    status_items: |
      ["✓ Integration Tests Passed", "Deploy: <commit-sha>"]
```

### 8.4 Cluster outage handling

If the cluster is unreachable (network, Azure outage, cluster down for maintenance), every CI run fails at the deploy step. Options:

- **A.** Fail loud — make deploy a required check, broken cluster means no merges. Operationally honest.
- **B.** Mark deploy as optional/advisory check when cluster unreachable, allow merges. Risk: regressions land unvalidated.

(A) is the recommended starting point. Add a `cluster-health-check` job at the front of deploy that fails fast with a clear message if the cluster is down — at least operators know what to fix.

### 8.5 Cost & resource bounds

Per CI run on the cluster:
- One pod restart per deploy (the patched service)
- Acceptance tests typically read-mostly, ~50 API calls
- Existing services keep running — no scaling event

Expected cost: negligible per run (cluster is already running). The cluster itself (AKS + CosmosDB + Service Bus + Storage) is the cost; CI usage doesn't materially add to it.

GHCR storage: each image ~300MB, retained per tag. With 8 services × ~50 PRs/month × image-per-PR, expect ~120GB/month accumulation. GHCR storage is free for public packages, so no cost concern — but auto-delete old tags via a retention policy to keep the listing manageable.

### 8.6 Flaky test handling

Integration tests against a live cluster will flake. Causes:
- Service still warming up despite probes
- Cross-service contention from concurrent runs
- Cluster network hiccups
- Test data drift

**Mitigation pattern:**
- Retry the acceptance test job up to 2x on failure
- Tests that flake more than 2x are real failures
- Track flake rate per test as a quality metric over time

```yaml
- name: Run acceptance tests
  uses: nick-fields/retry@v3
  with:
    timeout_minutes: 10
    max_attempts: 2
    command: cd partition-acceptance-test && mvn verify
```

### 8.7 Image immutability

`ghcr.io/...:<sha>` is immutable per build — same SHA = same image. `ghcr.io/...:<branch>` is mutable — represents "latest on that branch."

Deploy step should use **sha-tagged image** for reproducibility:

```bash
kubectl set image deployment/partition partition=ghcr.io/.../partition@sha256:<digest> -n osdu
```

Use the digest, not the tag, for the deploy. The branch tag is for humans browsing GHCR.

---

## 9. Implementation Plan

The work is sequenced in five phases, with explicit exit criteria for each.

### 9.1 Phase 0 — Manual Proof of Concept

**Duration:** 1-3 days  
**Goal:** Prove the deploy loop works end-to-end before committing to workflow YAML. Surface all auth/networking gotchas in interactive debug, not via 10 GitHub Actions runs.

**Scope:** Use existing `danielscholl-osdu/partition` fork and existing spi-stack cluster. No engineering system changes.

**Steps:**

1. **Build locally:**
   ```
   cd danielscholl-osdu/partition
   mvn -P partition-azure clean install
   ```
   Verify: `provider/partition-azure/target/*-spring-boot.jar` exists and is ~50MB.

2. **Containerize:**
   ```
   docker build -f devops/azure/Dockerfile -t ghcr.io/danielscholl-osdu/partition:test .
   docker run --rm ghcr.io/danielscholl-osdu/partition:test  # smoke test
   ```

3. **Push to GHCR:**
   ```
   gh auth token | docker login ghcr.io -u danielscholl-osdu --password-stdin
   docker push ghcr.io/danielscholl-osdu/partition:test
   gh api -X PATCH /user/packages/container/partition/visibility -f visibility=public
   ```

4. **Manually provision managed identity** for `danielscholl-osdu/partition` (Section 6.1 steps).

5. **Cluster CI-mode:**
   ```
   az aks get-credentials --resource-group <rg> --name <cluster>
   flux suspend kustomization --all -n flux-system
   ```

6. **Deploy via kubectl:**
   ```
   kubectl set image deployment/partition partition=ghcr.io/danielscholl-osdu/partition:test -n osdu
   kubectl rollout status deployment/partition -n osdu --timeout=5m
   ```

7. **Acceptance tests:**
   ```
   # Pull secrets from KV
   export PARTITION_BASE_URL=https://gateway/api/partition/v1
   export INTEGRATION_TESTER=$(az keyvault secret show ...)
   # ... other env vars
   cd partition-acceptance-test
   mvn verify
   ```

**Exit criteria:**
- Image is in GHCR, public, pullable
- Deployment is running the new image (verify via `kubectl describe pod`)
- Gateway returns valid responses to partition API endpoints
- Acceptance tests run to completion (pass or fail is OK — just must run)
- All authentication paths exercised and documented
- All Key Vault secret names captured for later automation

**Output artifact:** A Markdown document in this design directory (`POC-NOTES.md`) capturing every gotcha, every command actually used, every error encountered.

### 9.2 Phase 1 — Sandbox Engineering System Setup

**Duration:** 0.5-1 day  
**Goal:** Establish the safe iteration environment.

**Steps:**

1. **Fork `Azure/osdu-spi`** to `danielscholl-osdu/osdu-spi`. Use GitHub UI (Forks default to private — make it public to mirror official).

2. **Reconfigure `danielscholl-osdu/partition` template sync** to pull from sandbox instead of `Azure/osdu-spi`. This is a config change in the fork — likely a repo variable referencing the upstream template URL. Refer to ADR-012 / `template-sync.yml` for the exact mechanism.

3. **Verify template-sync from sandbox reaches partition:** make a trivial change in sandbox (`README.md` whitespace), wait for next template-sync run on partition, confirm PR opens.

**Exit criteria:**
- Sandbox repo exists and tracks Azure/osdu-spi as upstream
- Partition fork pulls templates from sandbox
- Round-trip update (sandbox → partition) works via template-sync

### 9.3 Phase 2 — Workflow Implementation in Sandbox

**Duration:** 1-2 weeks  
**Goal:** Build the new workflow stages in the sandbox engineering system. Iterate until end-to-end green on `danielscholl-osdu/partition`.

**Work items (each is one or more PRs in sandbox):**

| # | Work item | Component |
|---|-----------|-----------|
| W1 | Restrict java-build to `-P partition-azure` | Modify `.github/actions/java-build/action.yml` to accept `maven_profile` input |
| W2 | New composite action `docker-build` | `.github/actions/docker-build/action.yml` |
| W3 | New composite action `aks-deploy` | `.github/actions/aks-deploy/action.yml` |
| W4 | New composite action `integration-test` | `.github/actions/integration-test/action.yml` |
| W5 | Wire new jobs into `template-workflows/build.yml` | Append jobs after `java-build` |
| W6 | Wire new jobs into `template-workflows/validate.yml` | Same |
| W7 | Update `template-workflows/release.yml` to tag images with release version | Optional but recommended |
| W8 | Add cluster-health-check pre-flight | `.github/actions/cluster-health-check/` |
| W9 | Add Flux-suspend assertion in deploy action | Inside `aks-deploy/action.yml` |

**Per work item:** PR in sandbox → template-sync pushes to partition → partition workflow runs → debug → iterate.

**Per work item exit criteria:** corresponding stage runs green on partition for 5 consecutive runs (PR open, push commits, merge).

**Phase exit criteria:**
- Full pipeline green on partition for 10 consecutive runs
- Manual deploy/test scenarios still work (sandbox didn't break manual workflows)
- POC-NOTES.md gaps all closed

### 9.4 Phase 3 — Per-Fork Infrastructure Automation

**Duration:** 2-3 days  
**Goal:** Make onboarding a new service fork a single-script operation.

**Deliverable:** A script (likely in `osdu-spi-stack/scripts/` since it's infra-adjacent, or in a new `osdu-spi-onboarding/` repo):

```
./scripts/onboard-service.sh \
  --service partition \
  --org danielscholl-osdu \
  --aks-cluster aks-spi-stack-ci \
  --aks-rg spi-stack-ci
```

What it does:
1. Creates managed identity in identities RG
2. Adds federated credentials for all relevant ref subjects
3. Assigns AKS Cluster User role to identity
4. Creates K8s RoleBinding in osdu namespace
5. Assigns Key Vault Secrets User role
6. Outputs JSON with `AZURE_CLIENT_ID` and other per-fork values for the operator to paste into GitHub repo settings (or sets them via `gh` if appropriate auth is available)

**Exit criteria:**
- Re-run onboarding on partition (idempotent) — no errors
- Run onboarding on a second service (e.g., entitlements) when ready — produces a working CI loop with no manual steps beyond pasting two secret values

### 9.5 Phase 4 — PR Back to Official `Azure/osdu-spi`

**Duration:** 1-2 days  
**Goal:** Land the validated design in the official engineering system.

**Steps:**

1. **Diff sandbox vs official:**
   ```
   git remote add upstream https://github.com/Azure/osdu-spi
   git fetch upstream main
   git diff upstream/main..main -- .github/template-workflows/ .github/actions/
   ```
   Confirm only the intended changes.

2. **Open PR against Azure/osdu-spi** with:
   - All template-workflow changes
   - All composite action additions
   - **New ADRs:** drafts in Section 12 (ADR-032 through ADR-035)
   - **New product specs:** `docker-build-workflow-spec.md`, `deploy-workflow-spec.md`, `integration-test-workflow-spec.md`
   - Updates to `architecture.md`, `workflow-strategy.md`

3. **Pre-merge checks:**
   - All existing service forks are notified (announcement issue or comment)
   - Operators are aware they'll need to provision managed identity per service before their next PR
   - Sandbox proof points referenced in PR description

4. **Merge sequence:**
   - Merge ADRs first (documentation, no risk)
   - Merge composite actions second (code, but no triggers wired)
   - Merge template-workflows last (live trigger change)

**Exit criteria:**
- PR merged
- Official `Azure/osdu-spi` template-sync run propagates to existing service forks (partition will get the change — should be a no-op since it already has the equivalent from sandbox)

### 9.6 Phase 5 — Rollout to Remaining Services

**Duration:** 1 day per service, parallelizable  
**Goal:** All 8 services on the new CI loop.

**Order (suggested):**
1. Partition (done — reference)
2. Entitlements
3. Legal
4. Schema
5. Storage
6. File
7. Indexer
8. Search

Per service:
- Initialize fork from `Azure/osdu-spi` (existing init workflow, ADR-006)
- Run onboarding script (Phase 3 deliverable)
- Verify first CI run on the new fork's main goes green
- Add per-service acceptance test secrets to shared Key Vault if not already present

**Exit criteria:**
- All 8 services have green CI loops
- Onboarding script needed no per-service patches (proves generality)

### 9.7 Schedule estimate

| Phase | Duration | Cumulative |
|-------|---------|-----------|
| Phase 0: Manual POC | 1-3 days | 1-3 d |
| Phase 1: Sandbox setup | 0.5-1 day | 1.5-4 d |
| Phase 2: Workflow implementation | 5-10 days | 6-14 d |
| Phase 3: Onboarding automation | 2-3 days | 8-17 d |
| Phase 4: PR back to official | 1-2 days | 9-19 d |
| Phase 5: Per-service rollout | 1 day × 7 services | 16-26 d |

Roughly **3-5 weeks** end-to-end, with most time in Phase 2 (workflow iteration) and Phase 5 (per-service rollout, parallelizable).

---

## 10. Risks & Mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|-----------|
| R1 | Flux is accidentally resumed mid-CI, reverting deployed image | M | H | Pre-flight assertion in deploy action; ops doc clearly marks cluster as "CI mode" |
| R2 | Cross-service test flakes due to shared namespace | H | M | Per-service concurrency lock first; escalate to cluster-wide if needed |
| R3 | GHCR package accidentally goes private, AKS pulls fail | L | H | Visibility check in workflow; surface error early |
| R4 | Federated credential subject claim mismatch (branch ref edge cases) | M | M | Wildcard subject `ref:refs/heads/*` covers all branches; explicit `pull_request` subject for PR events |
| R5 | Acceptance tests depend on stale data from previous run | M | M | Cluster reset weekly (manual `flux resume` + suspend cycle); tests should be idempotent |
| R6 | Cluster outage blocks all PR merges | L | H | Make deploy check non-blocking under cluster-down (advisory mode toggleable via repo variable) |
| R7 | Image build is slow (~5min), drags out PR cycle | M | L | Multi-stage Dockerfile, layer caching, build only Azure profile |
| R8 | Eight services × 50 PRs/month = 400 deploys/month, cluster gets noisy | M | L | Acceptable; cluster is non-prod |
| R9 | Sandbox fork drifts from official, hard to PR back | M | M | Daily sync from official to sandbox; small PRs, not one big bang |
| R10 | Onboarding script depends on operator having Azure permissions to create identities | H | L | Document required RBAC; could be run from a centralized "ops" identity |
| R11 | Acceptance test credentials leak via Key Vault misconfig | L | H | KV RBAC scoped per service identity to read-only on specific secret prefixes |
| R12 | Maven profile name varies across services (`-P partition-azure` vs `-P entitlements-azure`) | H | L | Profile name as composite-action input; per-service repo variable |

---

## 11. Open Questions

These need answers before Phase 0 / during Phase 0:

| # | Question | Owner | When needed |
|---|----------|-------|-------------|
| Q1 | What is the gateway URL for the shared spi-stack CI cluster? | User | Phase 0 step 7 |
| Q2 | What are the exact Key Vault secret names the acceptance tests need? | Discovered in Phase 0 step 7 | Phase 0 |
| Q3 | Does the existing spi-stack RG have a dedicated identities RG, or do we create one? | User | Phase 0 step 4 |
| Q4 | Should release-please-tagged images be pushed to a separate "release" registry path or just tagged differently in GHCR? | Design decision | Phase 2 W7 |
| Q5 | Per-service Maven profile names — is it always `<service>-azure`? Need to confirm for entitlements, legal, schema, etc. | Inspect each fork during Phase 2 | Phase 2 |
| Q6 | Does the spi-stack `osdu-spi-init` chart provision deployments for SPI services, or only the community.opengroup.org images? Need to confirm a `Deployment/partition` exists for kubectl to patch. | User / inspect cluster | Phase 0 |
| Q7 | If we want to test rollback scenarios in integration tests, do we need a "previous good image" pointer? | Defer to post-MVP | Phase 5+ |
| Q8 | Are integration tests fast enough to run on every PR (<10min) or do we need a separate "deep" suite? | Measured in Phase 0 | Phase 2 |

---

## 12. Appendices

### Appendix A — Workflow YAML Sketches

**A.1. Modified `template-workflows/validate.yml` (excerpt — new jobs only):**

```yaml
  docker-build:
    name: "🐳 Docker Build"
    needs: [check-initialization, check-repo-state, java-build]
    if: |
      needs.check-repo-state.outputs.is_initialized == 'true' &&
      needs.check-repo-state.outputs.is_java_repo == 'true' &&
      needs.java-build.outputs.build_result == 'success' &&
      github.actor != 'dependabot[bot]'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    outputs:
      image_digest: ${{ steps.build.outputs.image_digest }}
      image_ref: ${{ steps.build.outputs.image_ref }}
    steps:
      - uses: actions/checkout@v5
      - uses: actions/download-artifact@v5
        with:
          name: build-artifacts
          path: .
      - id: build
        uses: ./.github/actions/docker-build
        with:
          dockerfile_path: devops/azure/Dockerfile
          image_name: ${{ vars.SERVICE_NAME }}
          registry: ghcr.io
          org: ${{ github.repository_owner }}

  deploy:
    name: "🚀 Deploy to spi-stack"
    needs: [docker-build]
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    concurrency:
      group: spi-stack-${{ vars.SERVICE_NAME }}
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v5
      - uses: ./.github/actions/aks-deploy
        with:
          azure_client_id: ${{ secrets.AZURE_CLIENT_ID }}
          azure_tenant_id: ${{ secrets.AZURE_TENANT_ID }}
          azure_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          aks_resource_group: ${{ vars.AKS_RESOURCE_GROUP }}
          aks_cluster_name: ${{ vars.AKS_CLUSTER_NAME }}
          namespace: ${{ vars.K8S_NAMESPACE }}
          deployment_name: ${{ vars.SERVICE_NAME }}
          image_ref: ${{ needs.docker-build.outputs.image_ref }}

  integration-test:
    name: "🧪 Integration Tests"
    needs: [deploy]
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v5
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - uses: ./.github/actions/integration-test
        with:
          test_dir: ${{ vars.SERVICE_NAME }}-acceptance-test
          gateway_url: ${{ vars.GATEWAY_URL }}
          keyvault_name: ${{ vars.KEYVAULT_NAME }}
          secret_map: ${{ vars.ACCEPTANCE_TEST_SECRET_MAP }}
```

**A.2. `docker-build/action.yml` sketch:**

```yaml
name: 'Docker Build & Push'
inputs:
  dockerfile_path:
    default: 'devops/azure/Dockerfile'
  build_context:
    default: '.'
  image_name:
    required: true
  registry:
    default: 'ghcr.io'
  org:
    default: ${{ github.repository_owner }}
outputs:
  image_digest:
    value: ${{ steps.push.outputs.digest }}
  image_ref:
    value: ${{ steps.tag.outputs.image_ref }}
runs:
  using: composite
  steps:
    - name: Log in to GHCR
      shell: bash
      run: echo "${{ github.token }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin
    - name: Compute tags
      id: tag
      shell: bash
      run: |
        SHORT_SHA=$(echo ${{ github.sha }} | cut -c1-12)
        IMAGE="${{ inputs.registry }}/${{ inputs.org }}/${{ inputs.image_name }}"
        echo "tags=${IMAGE}:${SHORT_SHA},${IMAGE}:${GITHUB_REF_NAME//\//-}" >> $GITHUB_OUTPUT
        echo "image_ref=${IMAGE}:${SHORT_SHA}" >> $GITHUB_OUTPUT
    - uses: docker/setup-buildx-action@v3
    - name: Build & push
      id: push
      uses: docker/build-push-action@v6
      with:
        context: ${{ inputs.build_context }}
        file: ${{ inputs.dockerfile_path }}
        push: true
        tags: ${{ steps.tag.outputs.tags }}
        cache-from: type=gha
        cache-to: type=gha,mode=max
```

**A.3. `aks-deploy/action.yml` sketch:**

```yaml
name: 'AKS Set Image & Wait'
inputs:
  azure_client_id: { required: true }
  azure_tenant_id: { required: true }
  azure_subscription_id: { required: true }
  aks_resource_group: { required: true }
  aks_cluster_name: { required: true }
  namespace: { default: 'osdu' }
  deployment_name: { required: true }
  image_ref: { required: true }
  rollout_timeout: { default: '5m' }
runs:
  using: composite
  steps:
    - uses: azure/login@v2
      with:
        client-id: ${{ inputs.azure_client_id }}
        tenant-id: ${{ inputs.azure_tenant_id }}
        subscription-id: ${{ inputs.azure_subscription_id }}
    - name: Get AKS credentials
      shell: bash
      run: |
        az aks get-credentials \
          --resource-group ${{ inputs.aks_resource_group }} \
          --name ${{ inputs.aks_cluster_name }}
    - name: Assert Flux suspended
      shell: bash
      run: |
        running=$(kubectl get kustomizations -n flux-system -o json 2>/dev/null | \
          jq -r '.items[] | select(.spec.suspend != true) | .metadata.name')
        if [ -n "$running" ]; then
          echo "::error::Flux not suspended: $running. Run 'flux suspend kustomization --all -n flux-system'"
          exit 1
        fi
    - name: Set image
      shell: bash
      run: |
        kubectl set image deployment/${{ inputs.deployment_name }} \
          ${{ inputs.deployment_name }}=${{ inputs.image_ref }} \
          -n ${{ inputs.namespace }}
    - name: Wait for rollout
      shell: bash
      run: |
        kubectl rollout status deployment/${{ inputs.deployment_name }} \
          -n ${{ inputs.namespace }} \
          --timeout=${{ inputs.rollout_timeout }}
    - name: Pod status on failure
      if: failure()
      shell: bash
      run: |
        kubectl describe deployment/${{ inputs.deployment_name }} -n ${{ inputs.namespace }}
        kubectl logs deployment/${{ inputs.deployment_name }} -n ${{ inputs.namespace }} --tail=200
```

### Appendix B — Draft ADRs

**ADR-032: CI/CD Deploy Loop via Suspended Flux**

> **Status:** Proposed  
> **Context:** The OSDU SPI engineering system produces validated Maven artifacts but no container images, deployments, or integration test signal. The runtime infrastructure (osdu-spi-stack) uses Flux GitOps for production-style reconciliation but this is incompatible with a per-PR CI cadence that needs to mutate deployments freely.  
> **Decision:** Run the shared osdu-spi-stack cluster with Flux fully suspended for the duration of CI/CD operation. Per-PR workflows use `kubectl set image` directly on Deployments to swap in newly-built container images, then run acceptance tests against the live service. Flux is only resumed during planned cluster baseline refresh.  
> **Consequences:** (+) Per-PR cadence achievable with sub-minute deploy latency. (+) No race conditions with Flux reconciliation. (+) Simple deploy mechanism, no Helm dynamics in CI. (-) Cluster state drifts from declared HelmRelease state. (-) Requires explicit ops awareness of "CI mode." (-) Operators cannot rely on Flux to self-heal during CI cycles.

**ADR-033: GHCR as Service Image Registry**

> **Status:** Proposed  
> **Context:** SPI service Docker images need to be hosted in a registry that GH Actions can push to with no extra auth, and AKS can pull from. Candidates: ACR, GHCR.  
> **Decision:** Use GHCR with packages set to public visibility. Push via `GITHUB_TOKEN`, pull anonymously from AKS.  
> **Consequences:** (+) No image-pull-secret provisioning in cluster. (+) No cross-cloud auth wiring. (+) Free storage for public packages. (-) Image visibility tied to package settings — accidental private setting breaks pulls. (-) Not co-located with cluster (negligible latency in practice).

**ADR-034: Federated Identity for Actions → Azure**

> **Status:** Proposed  
> **Context:** GH Actions workflows need authenticated access to Azure (AKS, Key Vault) to deploy and run integration tests. Static credentials (`AZURE_CREDENTIALS` JSON) are deprecated and a security risk.  
> **Decision:** Per service fork, provision a User-Assigned Managed Identity with federated credentials for the fork's GitHub Actions OIDC token. Workflows use `azure/login@v2` with the identity's client ID. No static secrets stored in GitHub.  
> **Consequences:** (+) No long-lived secrets. (+) Per-fork blast radius — compromise of one fork's CI doesn't affect others. (-) ~20 setup steps per fork; automation required. (-) Federated subject claim must match exactly; debugging mismatches is tedious.

**ADR-035: Azure-Only Maven Profile Restriction**

> **Status:** Proposed  
> **Context:** Forked OSDU services contain multiple cloud provider profiles (AWS, Azure, IBM, GC, Core+, GC-Quarkus). Only Azure is relevant to SPI work; building others is wasted CPU and irrelevant unit-test signal.  
> **Decision:** Configure the engineering system's Maven build to use `-P <service>-azure` profile only. Profile name is a per-fork variable.  
> **Consequences:** (+) Faster builds (~3-5x reduction in modules built). (+) Unit-test results are 100% Azure-relevant. (-) Lose signal on whether upstream changes break other providers — acceptable since SPI doesn't ship those.

### Appendix C — Cluster Setup Checklist

Pre-Phase 0:

- [ ] Confirm shared spi-stack cluster is running (`uv run spi status`)
- [ ] Confirm Flux is suspended (`flux get all -n flux-system`)
- [ ] Confirm `osdu` namespace has deployments for all services (`kubectl get deployments -n osdu`)
- [ ] Confirm gateway URL is reachable (`curl https://<gateway>/api/partition/v1/info`)
- [ ] Identify Key Vault name and confirm RBAC model (`az keyvault list`)
- [ ] Identify identities RG (create if needed)
- [ ] Verify ability to create managed identities (`az ad sp list --show-mine`)

Pre-Phase 1:

- [ ] Fork osdu-spi to sandbox org
- [ ] Note current template-sync upstream URL in partition fork
- [ ] Confirm template-sync workflow is functional in partition

Pre-Phase 4:

- [ ] All Phase 2 work items merged to sandbox
- [ ] Partition CI on sandbox is green for 10+ runs
- [ ] POC-NOTES.md captures resolutions to every gotcha
- [ ] Onboarding script tested re-running on partition (idempotent)

### Appendix D — Glossary

- **Engineering system:** `Azure/osdu-spi` — the template repository. Defines workflows, actions, configs that flow to service forks.
- **Service fork:** A forked OSDU service repo (`danielscholl-osdu/partition`, etc.) that inherits from the engineering system.
- **Sandbox engineering system:** `danielscholl-osdu/osdu-spi` (proposed) — fork of the official template used for safe iteration.
- **Stack:** `osdu-spi-stack` — runtime infrastructure repo providing AKS + Flux + Helm chart.
- **CI cluster:** The single shared AKS instance brought up by `spi up`, kept with Flux suspended for CI/CD use.
- **Template-sync:** The daily workflow that propagates changes from engineering system to service forks.
- **Cascade:** The branch-flow process (upstream → fork_upstream → fork_integration → main) for incorporating upstream OSDU changes.
- **Federated credential:** Azure AD construct allowing a managed identity to be assumed via an OIDC token from GitHub Actions, without storing static secrets.

---

**End of design.** Open questions, comments, and revisions welcome before promoting any section to ADR / spec / implementation.

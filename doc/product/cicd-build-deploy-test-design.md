# OSDU SPI CI/CD: Build, Deploy, Integration Test
## Detailed Design & Implementation Plan

**Status:** Draft v2 — pre-implementation design, post-review refinement
**Authors:** Daniel Scholl
**Target System:** `Azure/osdu-spi` engineering template + `osdu-spi-stack` runtime + 8 service forks

> **Companion docs:**
> - **Work breakdown & sub-issue catalog:** [`cicd-implementation-plan.md`](./cicd-implementation-plan.md) — 17 sub-issue specs, dependency graph, wave strategy, fork-regeneration runbook
> - **Live epic:** [#1](https://github.com/danielscholl-osdu/osdu-spi/issues/1)
> - **POC notes (Phase 0 output):** [`cicd-poc-notes.md`](./cicd-poc-notes.md) *(created during Phase 0 by the `POC` sub-issue)*

**Revision history:**
- **v1** — initial design from brainstorming
- **v2** — incorporated review findings: locked validate.yml-only deploy stages (D12); added per-service `K8S_DEPLOYMENT_NAME`/`K8S_CONTAINER_NAME` variables (D13); pinned trust boundaries for workflow events (D14, ADR-036); cascade-driven pushes deploy (D15); promoted Q6 to Phase 0 prerequisite; added OIDC validation step to Phase 0; added cross-service contamination / test data isolation handling (§8.8, §8.9); split Flux invariant into permanent steady state + planned-outage baseline refresh (§7.5); GHCR public-visibility compliance gate; expanded risks (R13–R17)

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

**`danielscholl-osdu/partition`** — First SPI service fork. Initialized from `Azure/osdu-spi` template. Contains:
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

- **C1.** New stages run on the same cadence as today's per-PR validation (PR events + push to `main`/`fork_integration`/`fork_upstream`). They are appended jobs in `template-workflows/validate.yml` **only**. `template-workflows/build.yml` keeps its Maven-build-only signal for feature-branch pushes — adding deploy stages there would cause duplicate `kubectl set image` calls to race on the same shared `Deployment` whenever both workflows fire on a PR sync event (see D12).
- **C2.** Container registry: **GHCR**, fork-owned. Packages must be **public** (decided by user) so AKS can pull without per-fork image-pull-secrets. Public visibility must be confirmed acceptable under the publishing org's container-registry policy **before Phase 4**; the design's fallback if public is disallowed is documented in §7.4.
- **C3.** Maven build restricted to **`-P partition-azure`** (or the Azure-equivalent profile for each service). Other cloud provider profiles are not built. Faster validate, smaller blast radius.
- **C4.** Deploy target: **single shared `osdu-spi-stack` AKS environment**. Already running. Flux is **permanently suspended** as a steady state — not just "during CI" — because there is no per-service "CI mode" toggle for a shared cluster. Resuming Flux is a planned-outage operation requiring a CI freeze across all 8 forks (see §7.5, §8.2).
- **C5.** Deploy mechanism: **`kubectl set image`** directly on existing Deployments. No Helm from CI, no HelmRelease editing — Flux is suspended, deployments live untouched. Requires the Helm chart in `osdu-spi-stack` to materialize each service's `Deployment` with a stable, predictable resource name and container name. These names are exposed as **per-service GitHub repo variables** (`K8S_DEPLOYMENT_NAME`, `K8S_CONTAINER_NAME`) rather than derived from `SERVICE_NAME`, to insulate CI from chart-naming changes (see D13).
- **C6.** Fork is independent at runtime: no cross-repo commits, no PRs to `osdu-spi-stack` from a service fork. Forks do **share** infrastructure (cluster, gateway URL, Key Vault), so a shared-infrastructure change (gateway DNS, KV rename) is a coordinated update across all forks.
- **C7.** Implementation must be proven in a sandbox fork of the engineering system before any change lands in `Azure/osdu-spi`.
- **C8.** New deploy/integration-test jobs run only when the PR head repo equals the base repo (no `pull_request_target` from external forks), and never on `dependabot[bot]`. The shared cluster's federated identity must not be exposed to attacker-controlled PR code. See §5.5 for the trust-boundary model.

### 2.3 Non-goals

- **NG1.** Production-grade deployment. The CI cluster is for validation, not customer-facing serving.
- **NG2.** Per-PR ephemeral environments. Cost-prohibitive; deferred.
- **NG3.** Replacing Flux GitOps for the spi-stack. Flux still owns the initial baseline; CI just patches on top.
- **NG4.** Building or deploying non-Azure provider profiles. Out of scope for SPI work.
- **NG5.** *Automatic* rollback on test failure. CI cluster is allowed to remain in a broken state between runs; the next CI run for the same service overwrites it. **However**, the deploy step DOES capture the previous-running digest (`previous_digest` output, §5.2), and a manual `restore-deployment` workflow_dispatch action is available so an operator can roll a single service back to its last-known-good digest in seconds without re-running the original PR (§8.9). The line we draw is "no auto-rollback decisions made by CI"; explicit human-triggered restore is in scope.

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
| D12 | New deploy/integration-test stages live in `validate.yml` only, not `build.yml` | Both workflows fire on PR sync today; deploying from both would race `kubectl set image` on the same `Deployment` |
| D13 | Per-service repo variables for `K8S_DEPLOYMENT_NAME` and `K8S_CONTAINER_NAME`, not derived from `SERVICE_NAME` | Helm chart may name resources `osdu-spi-service-partition` / container `app`; service slug is not load-bearing on the cluster |
| D14 | New stages do **not** run on `pull_request_target` from external forks, nor for `dependabot[bot]` | Cluster federated identity must never run attacker-controlled PR code; dependabot has its own validation path |
| D15 | Cascade-driven pushes to `fork_integration` **do** trigger deploy+integration-test | Catches upstream regressions before they reach `main`; same trust level as merge-to-main |

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
- Image pushed to `ghcr.io/<org>/<service>:sha-<short-sha>` (always — for humans browsing GHCR)
- Image pushed to `ghcr.io/<org>/<service>:<branch>-snapshot` on push to a protected branch (matches Maven `-Drevision=${branch}-SNAPSHOT`)
- Image pushed to `ghcr.io/<org>/<service>:<version>` on release-please-created tag push (e.g. `:v1.2.3`)
- Action emits `image_repository` (e.g. `ghcr.io/<org>/<service>`) and `image_digest` (e.g. `sha256:abc123…`) outputs

> **Digest format note.** `docker/build-push-action@v6` emits `outputs.digest` with the `sha256:` prefix already included. Callers compose the deploy reference as `${image_repository}@${image_digest}` — **do not** prepend `sha256:` again, or you'll get an invalid `@sha256:sha256:…` reference that `kubectl set image` will accept but the kubelet will fail to pull.

**Deploy always uses the digest reference `${image_repository}@${image_digest}`, never a tag.** GHCR tags are mutable in principle (a manual re-tag or a follow-up build could move `:sha-<short-sha>` to a different content hash), so passing a tag to `kubectl set image` weakens the guarantee that "what we tested is what runs." Pinning by digest closes that gap. Branch/version tags are documentation, not deployment references.

**Trigger:** Runs in `validate.yml` after `java-build` succeeds. Gated by `C8` — does **not** run for `pull_request_target` from an external head repo, nor for `dependabot[bot]`. See §5.5.

**Implementation surface:**

| Artifact | Type | Location |
|----------|------|----------|
| `docker-build` job | Job block | `template-workflows/validate.yml` only — added after `java-build` (per D12, not in `build.yml`) |
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
  image_repository:       full repo path (e.g. 'ghcr.io/<org>/<service>')
  image_digest:           sha256 digest of pushed image (e.g. 'sha256:abc123…')
  image_tags:             comma-separated tags pushed (for human/log use only)
```

Callers MUST compose the deploy reference as `${image_repository}@${image_digest}`; never pass a tag to deploy.

**Failure modes:**
- Dockerfile missing → job fails with clear message pointing at `devops/azure/Dockerfile`
- JAR artifact missing (java-build skipped or failed) → job is skipped (`needs: java-build`)
- GHCR push fails (rate limit, network) → job fails, retried by re-running workflow
- Image too large (>1GB) → warning surfaced, not blocking initially
- First-time push creates a new GHCR package as **private by default** — onboarding script (Phase 3) flips visibility to public via `gh api -X PATCH .../visibility`. Until that runs once per service, deploys will fail with `ErrImagePull`.

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
| `deploy` job | Job block | `template-workflows/validate.yml` only (per D12) |
| `aks-deploy` composite action | Composite action | `.github/actions/aks-deploy/action.yml` |

**Composite action contract:**

```
inputs:
  azure_client_id:        required (from repo secret)
  azure_tenant_id:        required
  azure_subscription_id:  required
  aks_resource_group:     required (from org-level variable)
  aks_cluster_name:       required (from org-level variable)
  namespace:              required (from org-level variable, e.g. 'osdu')
  deployment_name:        required (from per-service repo variable K8S_DEPLOYMENT_NAME — NOT derived from SERVICE_NAME, see D13)
  container_name:         required (from per-service repo variable K8S_CONTAINER_NAME — chart may name the container 'app' or similar)
  image_repository:       required (e.g. 'ghcr.io/<org>/<service>')
  image_digest:           required (e.g. 'sha256:abc123…' — the prefix is part of the value, do not strip or double-add). Action composes the deploy ref as `${image_repository}@${image_digest}`. Tags are not accepted.
  rollout_timeout:        default '5m'

outputs:
  rollout_status:         'success' | 'timeout' | 'failed'
  previous_digest:        sha256 digest that was running BEFORE this deploy (captured pre-patch, used by restore-deployment workflow on failure rollback — see §8.9)
  deployed_digest:        sha256 digest actually running AFTER rollout (for downstream pin-verification)
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

This is essential as a fail-fast gate. **However**, a pre-flight check alone does **not** protect a long-running acceptance test from someone running `flux resume` mid-run. The integration-test job carries a **post-rollout digest verification** (§5.3) that re-reads the pod's current image and fails the run if it no longer matches the digest we just deployed.

**Concurrency lock (per-service):**

```yaml
concurrency:
  group: spi-stack-${{ vars.SERVICE_NAME }}
  cancel-in-progress: false
```

Per-service, not cluster-wide. Two different services' deploys can run in parallel because they target different `Deployment` resources; only same-service PR runs queue. `cancel-in-progress: false` because cancelling a deploy mid-rollout leaves the cluster in a partially-deployed state. See §8.1 for the trade-off and the conditions under which we'd escalate to a cluster-wide lock.

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
| `integration-test` job | Job block | `template-workflows/validate.yml` only (per D12) |
| `integration-test` composite action | Composite action | `.github/actions/integration-test/action.yml` |

**Composite action contract.** Action takes only explicit inputs; never reads `vars.*` or `secrets.*` directly. Workflow caller wires variables in.

```
inputs:
  test_dir:               required (caller passes from per-service repo variable ACCEPTANCE_TEST_DIR; partition convention is '<service>-acceptance-test')
  namespace:              required (caller passes from K8S_NAMESPACE)
  deployment_name:        required (caller passes from K8S_DEPLOYMENT_NAME)
  container_name:         required (caller passes from K8S_CONTAINER_NAME)
  gateway_url:            required (caller passes from GATEWAY_URL)
  keyvault_name:          required (caller passes from KEYVAULT_NAME)
  secret_map:             required (JSON map of env-var-name → kv-secret-name; differs per service)
  dependencies:           optional (JSON map of dependency-service-name → gateway health-endpoint path; e.g. '{"partition":"/api/partition/v1/info"}'. When non-empty, probed at start of run; result drives `cluster_state` output and PR label but never the job exit code)
  maven_goal:             default 'verify'
  maven_profile:          optional (e.g. '<service>-azure')
  expected_digest:        required (sha256 digest from deploy job; integration-test re-reads pod image and fails if mismatched — guards against mid-test Flux resume / pod restart with stale image)

outputs:
  test_result:            'pass' | 'fail' | 'pass-advisory' (tests passed AND cluster was unhealthy at start — informational only)
  test_report_url:        link to uploaded JUnit XML artifact
  cluster_state:          'healthy' | 'contaminated' (per cross-service health probe at start of run)
```

**Exit-code semantics (required-check compatible).** The job always exits with a binary success/failure code so branch-protection enforcement of G2 is unambiguous:

| Test outcome | Cluster state | Job exit | `test_result` | PR label applied |
|--------------|---------------|----------|---------------|------------------|
| Pass | Healthy | success | `pass` | (none) |
| Pass | Contaminated (a dependency was unhealthy at probe time) | **success** | `pass-advisory` | `ci/cluster-was-contaminated` — reviewers see this and know the pass may not be fully authoritative |
| Fail | Healthy | failure | `fail` | (none) — your code |
| Fail | Contaminated | failure | `fail` | `ci/cluster-was-contaminated` — reviewer can decide whether to retry once cluster is clean, but the merge gate is still closed |

The `advisory` concept is **metadata only** (a PR label and a step-summary comment). It never relaxes the required check. If cluster contamination is producing real test failures and you need to merge anyway, that's a break-glass conversation (admin override), not a per-PR variable.

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

The updated `template-workflows/validate.yml` job graph (new jobs marked NEW). Per D12, these stages do **not** appear in `build.yml`:

```
check-initialization
        │
        ▼
check-repo-state
        │
        ├──────────────────────────────┐
        ▼                              ▼
   java-build                    code-validation (existing — runs in parallel,
        │                                          independent of deploy chain)
        ▼
   docker-build        (NEW — gated by §5.5 trust rules)
        │
        ▼
     deploy            (NEW — per-service concurrency, Flux pre-check)
        │
        ▼
integration-test       (NEW — digest verification, cross-service health probe)
```

`code-validation` (commit linting, branch checks) is unchanged and parallel — it does not depend on the deploy chain.

### 5.5 Workflow trust boundaries

The new jobs hold a federated identity with `Azure Kubernetes Service Cluster User Role` + namespace `edit` + `Key Vault Secrets User`. Running them on attacker-controlled code is a path to cluster-wide compromise across all 8 forks. The trust model:

| Event | Code source | Secret access | Deploy stages run? |
|---|---|---|---|
| `push` to `main` / `fork_integration` / `fork_upstream` | Repo HEAD (post-merge) | Yes | **Yes** |
| `pull_request` from internal branch (head repo == base repo) | PR HEAD | Yes | **Yes** |
| `pull_request` from external fork | PR HEAD | No (GH default) | No — would fail at `azure/login` anyway, but explicitly skipped to avoid noise |
| `pull_request_target` (base-repo context) | PR HEAD (checked out via explicit ref) | Yes | **No** — too dangerous; would let a PR exfiltrate the federated identity by running arbitrary code in a workflow that has secret access |
| `dependabot[bot]` PR | PR HEAD | Limited (`secrets.DEPENDABOT_SECRETS`) | No — dependabot-validation.yml is the dependency-update path |
| `workflow_dispatch` | Repo HEAD at chosen ref | Yes | Yes (manual gate is the operator) |
| Tag push (release-please) | Tagged commit (already in `main`) | Yes | **No** — tag pushes go through `release.yml`, NOT `validate.yml`. `release.yml` only re-tags the existing image with the semver (W7); it does not re-deploy, since deploy already ran on the merge-to-main that produced the tagged commit. The federated credential still needs `refs/tags/v*` because `release.yml` authenticates to GHCR for the re-tag. |
| Cascade workflow push to `fork_integration` | Cascade-resolved tree | Yes | Yes — see §5.6 |

**Gating clause used by docker-build / deploy / integration-test jobs:**

```yaml
if: |
  (
    needs.check-initialization.outputs.initialized == 'true' &&
    needs.check-repo-state.outputs.is_java_repo == 'true' &&
    needs.java-build.outputs.build_result == 'success' &&
    github.actor != 'dependabot[bot]' &&
    github.event_name != 'pull_request_target' &&
    (github.event_name != 'pull_request' ||
     github.event.pull_request.head.repo.full_name == github.repository)
  ) || (
    github.event_name == 'workflow_dispatch' &&
    inputs.force_full_pipeline == true
  )
```

The first half is the trust-boundary admission (per the table above). The second half is the W13 manual escape hatch: a `workflow_dispatch` from an operator who has push access to the repo is, by definition, a trusted invocation — and is the only way to force a full pipeline run when `paths-ignore` would otherwise skip the trigger (the canonical case being a template-sync PR whose only changes are under `.github/`). Both halves must be present; omitting the W13 admission means `force_full_pipeline` lands as dead weight.

For external-fork PRs we accept the reduced safety net: maintainers must do the historical "checkout, build, sanity-test locally" before merge. Documented in CONTRIBUTING.

### 5.6 Cascade workflow interaction

`cascade.yml` pushes upstream changes through `fork_upstream` → `fork_integration` → `main`. Each push to a protected branch triggers `validate.yml` (push trigger). Under D15, **cascade-driven pushes do trigger the new deploy stages** — catching upstream regressions before they reach `main` is exactly the signal this design is meant to provide.

Implications:

- Cascade runs are bot-driven, but the bot identity (`github-actions[bot]`) does have access to the federated identity. The gating clause in §5.5 admits cascade pushes because they are `push` events to protected branches, not PRs.
- If a cascade push deploys a broken upstream change and integration tests fail, the cascade PR (cascade also opens a PR on `main` after `fork_integration`) is held back by required-check failure — the desired behaviour.
- Cascade concurrency: cascade itself has its own concurrency lock; combined with our per-service deploy concurrency, two cascades for the same service serialize correctly.

---

## 6. Authentication & Authorization

### 6.1 Federated Identity Setup (per service fork)

For each service fork (one-time setup, automated via script — see §9.4).

**Operator preconditions** (verified by the onboarding script before any change is attempted):

- `az` CLI logged into the target tenant with `Owner` or `User Access Administrator` on the identities resource group + the AKS resource (to create managed identities and role assignments)
- `kubectl` configured against the target AKS cluster with `cluster-admin` (to create RoleBindings)
- `gh` CLI authenticated against the target org with admin on the target repo (SSO-authorized) — to write secrets/variables/rulesets
- The target fork's `Deployment/<name>` actually exists in the `osdu` namespace (script does `kubectl get -n osdu deployment/<name>` and fails if absent — this is C3's tie-in)

Steps:

1. **Create User-Assigned Managed Identity:**
   ```
   az identity create \
     --name "spi-ci-${SERVICE}" \
     --resource-group "${RG_IDENTITIES}" \
     --location "${LOCATION}"
   ```

2. **Add federated credentials for GitHub Actions** — every event that needs Azure auth needs a subject. Use wildcard subjects where the GitHub federated-credential editor accepts them, otherwise enumerate:

   | Trigger | Federated-credential subject |
   |---|---|
   | Push to / PR to any branch | `repo:${ORG}/${SERVICE}:ref:refs/heads/*` (wildcard) |
   | Pull request events | `repo:${ORG}/${SERVICE}:pull_request` |
   | Release-please tag push (`v*`) | `repo:${ORG}/${SERVICE}:ref:refs/tags/*` |
   | Environment-scoped (if `environments:` used for gating) | `repo:${ORG}/${SERVICE}:environment:<env-name>` |

   Wildcard subjects require Azure AD to be configured to accept the wildcard pattern (controlled by an Entra ID feature flag; if unavailable, enumerate explicit refs `main`, `fork_integration`, `fork_upstream`).
   ```
   az identity federated-credential create \
     --name "github-actions-${SERVICE}-branches" \
     --identity-name "spi-ci-${SERVICE}" \
     --resource-group "${RG_IDENTITIES}" \
     --issuer "https://token.actions.githubusercontent.com" \
     --subject "repo:${ORG}/${SERVICE}:ref:refs/heads/*" \
     --audience "api://AzureADTokenExchange"
   ```
   …repeat for PR and tag subjects.

3. **AKS RBAC:**
   ```
   # Cluster-level: allow getting credentials
   az role assignment create \
     --assignee "${IDENTITY_PRINCIPAL_ID}" \
     --role "Azure Kubernetes Service Cluster User Role" \
     --scope "/subscriptions/.../managedClusters/${AKS_NAME}"
   ```

   **Namespace-level access uses two least-privilege Roles, NOT the built-in `edit` ClusterRole.** `edit` grants delete/create across most resource kinds in the namespace, which is far more than the CI workflow needs (it only patches one specific Deployment + reads pods/events/logs for diagnostics). Define a custom Role per service and bind only it:

   ```yaml
   # Role: spi-ci-<service>-deploy  (in namespace osdu)
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: spi-ci-${SERVICE}-deploy
     namespace: osdu
   rules:
     # The named deployment: read + watch (rollout status) + patch (set image)
     - apiGroups: ["apps"]
       resources: ["deployments"]
       resourceNames: ["${K8S_DEPLOYMENT_NAME}"]
       verbs: ["get", "list", "watch", "patch"]
     - apiGroups: ["apps"]
       resources: ["deployments/scale"]
       resourceNames: ["${K8S_DEPLOYMENT_NAME}"]
       verbs: ["get", "patch"]
     - apiGroups: ["apps"]
       resources: ["deployments/status"]
       resourceNames: ["${K8S_DEPLOYMENT_NAME}"]
       verbs: ["get"]
     # ReplicaSets: kubectl rollout status walks the deployment → replicaset → pod chain.
     # ReplicaSet names are dynamic ("<deployment>-<hash>") so resourceNames cannot pin them;
     # namespace-scoped read is the tightest realistic restriction.
     - apiGroups: ["apps"]
       resources: ["replicasets"]
       verbs: ["get", "list", "watch"]
     # Pods: needed for pod selector lookup (digest verification), log capture, and
     # rollout status watching. Pod names are dynamic, same caveat as ReplicaSets.
     - apiGroups: [""]
       resources: ["pods"]
       verbs: ["get", "list", "watch"]
     - apiGroups: [""]
       resources: ["pods/log"]
       verbs: ["get", "list"]
     # Events: failure diagnostics ("Why did the rollout time out?")
     - apiGroups: [""]
       resources: ["events"]
       verbs: ["get", "list", "watch"]
   ---
   # RoleBinding: bind the above Role to the federated identity (subject form per AKS auth mode)
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: spi-ci-${SERVICE}-deploy
     namespace: osdu
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: Role
     name: spi-ci-${SERVICE}-deploy
   subjects: [...]   # see auth-mode note below
   ---
   # Role: spi-ci-flux-read  (in namespace flux-system, read-only)
   # Needed so the deploy action's "Flux suspended" pre-check can list Kustomizations.
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: spi-ci-flux-read
     namespace: flux-system
   rules:
     - apiGroups: ["kustomize.toolkit.fluxcd.io"]
       resources: ["kustomizations"]
       verbs: ["get", "list"]
   # Bound to ALL service-fork identities (one RoleBinding per identity, or one for a Group).
   ```

   **What this Role explicitly does NOT grant:** create/delete on anything, scale on non-named deployments, secrets read, configmaps write, exec into pods, port-forward, attach to running containers, anything in `apps/*/finalizers`. If you find yourself needing one of these for the CI loop, that's a signal to revisit the design rather than expand the Role.

   **The RoleBinding subject form depends on the AKS cluster's auth mode** — Phase 0 gate 0b answers which applies:
   - **AKS-managed Entra ID (recommended):** subject is `kind: User`, `name: <IDENTITY_PRINCIPAL_OID>`, `apiGroup: rbac.authorization.k8s.io`
   - **Local accounts disabled:** same User form, no fallback
   - **Workload Identity SA passthrough:** subject is `kind: ServiceAccount` — different model, only chosen if Phase 0 reveals the cluster requires it

   `kubectl auth can-i patch deployments/${K8S_DEPLOYMENT_NAME} -n osdu --as=<principal-oid>` is the Phase 0 acceptance check.

4. **Key Vault access:**
   ```
   az role assignment create \
     --assignee "${IDENTITY_PRINCIPAL_ID}" \
     --role "Key Vault Secrets User" \
     --scope "${KV_RESOURCE_ID}"
   ```
   For tighter scoping, restrict to specific secret prefixes (e.g., `${SERVICE}-*`) using KV access policies once the per-service secret naming convention is captured in Phase 0.

5. **GitHub repo configuration:**
   - **Secrets:** `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
   - **Per-service repo variables:** `AZURE_CLIENT_ID` (also as var for use in `if:` expressions), `SERVICE_NAME`, `K8S_DEPLOYMENT_NAME`, `K8S_CONTAINER_NAME`, `ACCEPTANCE_TEST_DIR`, `ACCEPTANCE_TEST_SECRET_MAP`, `MAVEN_PROFILE` (e.g. `partition-azure`)
   - **Org-level variables (set once, inherited):** `AKS_RESOURCE_GROUP`, `AKS_CLUSTER_NAME`, `K8S_NAMESPACE` (= `osdu`), `KEYVAULT_NAME`, `GATEWAY_URL`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`

This is roughly ~20 steps per service. Automation is essential — see §9.4.

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
| Managed Identity | Custom Role `spi-ci-${SERVICE}-deploy` (patch one named Deployment + read pods/events/logs) | `osdu` namespace | Patch only its own Deployment; diagnose its pods |
| Managed Identity | Custom Role `spi-ci-flux-read` (get/list Kustomizations) | `flux-system` namespace | Pre-flight check that Flux is suspended |
| Managed Identity | Key Vault Secrets User | Shared KV (scoped per-service if possible) | Read acceptance test secrets |
| AKS kubelet identity | AcrPull | (Not needed — GHCR is public per D4) | N/A unless §7.4 fallback to ACR is activated |

The federated identity has **no** write access to: cluster-scoped resources, the `osdu-spi-stack` repo, the engineering-template repo, KV management plane, or any tenant-wide resources. Compromise of one fork's identity does not propagate beyond its own service's namespace footprint.

---

## 7. Infrastructure Requirements

### 7.1 What `osdu-spi-stack` provides today

- AKS Automatic cluster (provisioned via `spi up`)
- Flux CD extension installed and reconciling from stack git repo
- `osdu` namespace with 9 services deployed from community.opengroup.org images
- Istio Gateway exposing `/api/partition/v1/*` etc.
- Key Vault with workload identity secrets
- Workload Identity Service Account (`workload-identity-sa`) in osdu namespace

**Deployment-name contract** (foundational to the `kubectl set image` model — verify before Phase 0):

The generic Helm chart `software/charts/osdu-spi-service/` materializes one `Deployment` per service. **The exact resource name and container name as rendered into the cluster** are the values used in `K8S_DEPLOYMENT_NAME` / `K8S_CONTAINER_NAME` (D13). For each service fork during onboarding, the script captures these via:

```
kubectl get deployment -n osdu -l app.kubernetes.io/component=${SERVICE} -o jsonpath='{.items[0].metadata.name}'
kubectl get deployment -n osdu <NAME> -o jsonpath='{.spec.template.spec.containers[0].name}'
```

If the chart names resources unpredictably (e.g., includes a release-name prefix), the stack repo must be updated to expose stable names — a coordinated change with `osdu-spi-stack` owners.

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

Per-fork variables (must be set per repo by the onboarding script):

| Variable | Value (per fork) | Why per-fork |
|----------|------------------|---------------|
| `AZURE_CLIENT_ID` | The managed identity's client ID — unique per fork | One identity per service for blast-radius isolation (ADR-034) |
| `SERVICE_NAME` | `partition`, `entitlements`, etc. | Identifies the service in workflow ergonomics; **not** authoritative for cluster resources |
| `K8S_DEPLOYMENT_NAME` | Actual chart-rendered Deployment name | Insulate CI from chart naming changes (D13) |
| `K8S_CONTAINER_NAME` | Actual container name inside the Deployment | Same — chart may use `app` or `service` rather than service slug |
| `MAVEN_PROFILE` | `partition-azure`, `entitlements-azure`, etc. | Profile naming differs across services (Q5) |
| `ACCEPTANCE_TEST_DIR` | `partition-acceptance-test` | Verified per-service during Phase 5; default is `<service>-acceptance-test` |
| `ACCEPTANCE_TEST_SECRET_MAP` | JSON, e.g. `{"PARTITION_BASE_URL":"partition-base-url","INTEGRATION_TESTER":"int-tester-id",…}` | Each service's acceptance tests read a different set of env vars; map declares the env→KV-secret binding |
| `ACCEPTANCE_TEST_DEPENDENCIES` | JSON, e.g. `{"partition":"/api/partition/v1/info","legal":"/api/legal/v1/info"}` (empty `{}` for services with no upstream deps) | Per §8.9, integration-test probes each dependency's gateway health endpoint before tests; populates `cluster_state` for PR-label decisions. Audit per-service in Phase 5. |

### 7.4 Image-pull from GHCR

Because GHCR packages are public (D4), AKS pulls without authentication. **No image pull secret required.**

**Compliance precondition (resolve before Phase 4):** confirm that public-visibility container packages are acceptable under the publishing org's GitHub container policy. For the sandbox org (`danielscholl-osdu`) this is operator-controlled and fine. For `Azure/osdu-spi`-derived production forks this requires explicit sign-off — Azure org may have a policy disallowing public packages on first-party repos.

If a CI step accidentally bakes a secret into a layer (e.g., an `ARG` exposed via `RUN curl -H "Authorization: Bearer …"`), it would become publicly downloadable. The Dockerfile in each service repo must be auditable for this and the CI step should verify there are no `RUN` lines that consume `${{ secrets.* }}` (Dockerfile lint is acceptable here).

If at any point a service's GHCR package gets accidentally made private, AKS pulls will fail with `ErrImagePull`. The first push creates a package as **private by default**, so the onboarding script (Phase 3) explicitly flips visibility to public on first run, and a CI step continuously verifies it.

> **GHCR API endpoint depends on package ownership.** Packages pushed by a repo under an organization are owned by that org; packages pushed by a user-owned repo are owned by the user. The visibility flip + read endpoints differ:
> - **Org-owned package** (this design's default; `danielscholl-osdu/<service>` pushes to `ghcr.io/danielscholl-osdu/<service>`): `/orgs/{ORG}/packages/container/{SERVICE}/visibility`
> - **User-owned package** (only if the publishing repo is under a personal account): `/user/packages/container/{SERVICE}/visibility` (writes to *your own* packages) or `/users/{USER}/packages/container/{SERVICE}` (reads someone else's)
>
> The onboarding script and the W12 CI verification must pick the right one based on whether `${{ github.repository_owner }}` is an org or a user. `gh api /users/{owner}` returns `"type": "Organization"` vs `"User"` — that's the discriminator.

```bash
# Read visibility (org-owned package — the design's default)
gh api "/orgs/${ORG}/packages/container/${SERVICE}" \
  --jq '.visibility' | grep -q 'public'
```

**Fallback if public GHCR is disallowed:**

| Option | Mechanism | Trade-off |
|---|---|---|
| **A. ACR + AcrPull on kubelet** | Push to existing `osdu-spi-stack` ACR; AKS kubelet identity already has AcrPull via stack provisioning | Best fit if Azure org policy forbids public images; requires push-to-ACR federated identity instead of `GITHUB_TOKEN`; cross-cloud auth wiring |
| **B. Private GHCR + per-fork image-pull-secret** | Keep GHCR but provision `regcred` Secret in `osdu` namespace per service | Adds onboarding step; brings back the very thing D4 wanted to avoid; secret rotation becomes an operational concern |

Decision deferred until Azure org policy is confirmed (Phase 0 compliance check).

### 7.5 Cluster CI-mode invariants

The cluster is **permanently in CI mode as steady state** (C4). "CI mode" is not a transient toggle — there is no per-service or per-PR switch to flip it on and off. Resuming Flux is a planned-outage operation, not a routine action.

When the cluster is in CI mode (its normal state):
- All Flux Kustomizations are suspended
- All HelmReleases are technically still "managed" but Flux is not reconciling
- Deployments live in their last-known state from Flux's last reconciliation, with images progressively replaced by `kubectl set image` from CI
- CI workflows can `kubectl set image` freely
- `helm` and `flux` CLI users must not manually reconcile or resume

**Baseline refresh procedure** (planned-outage; coordinate across all 8 forks):

1. Announce a CI freeze window in the engineering org (e.g., a pinned issue or org-level workflow that pauses cascade and template-sync).
2. Verify no in-flight workflow runs are mid-deploy (`gh run list --status in_progress` across forks).
3. `flux resume kustomization --all -n flux-system` — Flux reconciles, services revert to community images (or whatever the HelmRelease points at).
4. Wait for reconciliation to converge (`flux get all -n flux-system`).
5. `flux suspend kustomization --all -n flux-system` — return cluster to CI mode.
6. Notify the org that CI is unfrozen.

The stack repo should expose this as a single `spi cluster baseline-refresh` subcommand that drives the above, including the announcement plumbing.

**Detection that CI mode has been violated** (defense in depth):

- `aks-deploy` pre-flight check (§5.2) — fails fast at the start of every deploy
- `integration-test` post-rollout digest check (§5.3) — fails the run if the deployed image was reverted mid-test
- An optional cluster-wide cron that posts to a Slack/issue channel if any Kustomization shows `spec.suspend != true`

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

After many CI runs the cluster has drifted from Flux's declared state. The reset procedure is the **baseline refresh** documented in §7.5 — it is a planned outage that requires a CI freeze across all 8 forks, not a casual cron.

Frequency depends on how much drift accumulates. Initial target: monthly during the rollout phase, quarterly thereafter unless investigating a specific symptom.

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

**GHCR retention policy** (set per service by onboarding script):
- `:sha-<short-sha>` — keep for **30 days**. Long enough to debug a regression to a specific commit; short enough to bound growth.
- `:<branch>-snapshot` — keep last **5** tags per branch. Always shows recent activity per branch without piling up.
- `:<version>` (release-please semver tags) — **keep indefinitely**. These are the auditable artifacts.
- `:pr-<n>` — keep last **2** per PR; delete when PR closes. *Optional — only if we tag per-PR explicitly; default is to rely on `:sha-*` for PRs.*

Set via the [container-retention GitHub action](https://github.com/actions/delete-package-versions) or `gh api -X DELETE ...` in a scheduled workflow.

**GHA cache budget:** GHA gives each repo 10 GB of cache. Today each fork uses Maven cache (~1–2 GB). With the new design adding `cache-from: type=gha,mode=max` for Docker buildx layers (often 1–3 GB per service after `mvn install` artifacts get layered), per-fork usage will climb to 3–5 GB. Within budget for a single service, but the engineering-template repo itself running its own self-test workflows in `.github/workflows/` (e.g. `dev-ci.yml`) needs its caching strategy reviewed during Phase 2.

If cache eviction becomes a bottleneck:
- Switch Docker layer cache to a registry-backed cache (`type=registry,ref=ghcr.io/<org>/<svc>:buildcache`) — no GHA cache pressure
- Use `cache-from: type=gha,scope=docker-<service>` to scope per service explicitly

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

`ghcr.io/...:sha-<short>` is immutable per build — same SHA = same image. `ghcr.io/...:<branch>-snapshot` is mutable — represents "latest on that branch."

Deploy step uses the **digest** (output from `docker/build-push-action`), not the tag:

```bash
kubectl set image deployment/${K8S_DEPLOYMENT_NAME} ${K8S_CONTAINER_NAME}=ghcr.io/<org>/<svc>@sha256:<digest> -n osdu
```

This guarantees the integration-test step can re-verify the running pod's image against the exact digest we set.

### 8.8 Cross-service test data isolation

The shared `osdu` namespace + concurrent CI runs across 8 services means acceptance tests will trip over each other unless they:

- Create test data with a **per-run unique prefix** — e.g., partition tenant IDs derived from `${SHORT_SHA}-${RUN_ID}`, not hard-coded `test-001`
- Clean up after themselves on success (best-effort on failure — failure cleanup is unreliable, so naming must be unique enough that residue is harmless)
- Tolerate **other** test data sitting in the cluster (don't assume "no partitions exist except mine")

For services whose acceptance tests don't follow this discipline today, Phase 5 includes a per-service audit. If a service's tests cannot be made isolation-safe, fall back to an exclusive cluster-wide concurrency lock for that service's runs (downgrade from per-service to cluster-wide for that one service).

Per-service status — to be filled in during Phase 0/Phase 5 audit:

| Service | Test data isolation strategy | Status |
|---|---|---|
| partition | TBD | Audit in Phase 0 |
| entitlements | TBD | Audit in Phase 5 |
| legal | TBD | Audit in Phase 5 |
| schema | TBD | Audit in Phase 5 |
| storage | TBD | Audit in Phase 5 |
| file | TBD | Audit in Phase 5 |
| indexer | TBD | Audit in Phase 5 |
| search | TBD | Audit in Phase 5 |

### 8.9 Cross-service contamination from broken deploys

NG5 ("CI cluster is allowed to remain in a broken state between runs; next run overwrites") interacts poorly with cross-service test dependencies. Concrete scenario:

1. PR-A on `partition` deploys a buggy image. Partition pod is `CrashLoopBackOff`.
2. PR-B on `entitlements` opens 10 minutes later. Entitlements acceptance tests need to call `/api/partition/v1/partitions` to bootstrap.
3. Entitlements tests fail with `503 Service Unavailable` from gateway → partition.
4. PR-B author has no context for why their unrelated change broke CI.

**Mitigations (combined):**

- **Cross-service health probe** (per-service `ACCEPTANCE_TEST_DEPENDENCIES` map declares which dependencies to check, see §5.3 + §7.3): before running tests, GET each dependency's `/info` endpoint. The probe result populates `cluster_state` (`healthy` / `contaminated`) and drives a PR label. **It never changes the job exit code** — required-check semantics (G2) are preserved. See §5.3 exit-code table.
- **Manual `restore-deployment` workflow** (in scope for v1; modifies NG5; **implemented by W14** at `.github/template-workflows/restore-deployment.yml`): the deploy step captures `previous_digest` before patching. A workflow_dispatch-triggered job lets an operator restore a service to its last-known-good digest:
  ```
  gh workflow run restore-deployment.yml \
    -f service=partition \
    -f digest=sha256:<previous-good-digest>
  ```
  This is for the common case where one bad deploy is poisoning everyone else's tests and you want to unstick the cluster without waiting for the original PR author to push a fix. Not auto-triggered — humans decide when to use it.
- **Dependency graph documentation**: each service's acceptance tests document which other services they call via the per-service `ACCEPTANCE_TEST_DEPENDENCIES` variable. Phase 5 captures this. Tests that depend on multiple other services are higher contamination risk.

A "service health badge" surfaced on the spi-stack repo README, updated by a 5-minute cron in `osdu-spi-stack`, lets a PR author quickly check "is the cluster healthy right now?" before assuming a test failure is their bug.

---

## 9. Implementation Plan

The work is sequenced in five phases, with explicit exit criteria for each.

### 9.1 Phase 0 — Manual Proof of Concept

**Effort:** M
**Goal:** Prove the deploy loop works end-to-end before committing to workflow YAML. Surface all auth/networking gotchas in interactive debug, not via 10 GitHub Actions runs.

**Scope:** Use existing `danielscholl-osdu/partition` fork and existing spi-stack cluster. No engineering system changes.

**Step 0 — Prerequisites** (settle before any other Phase 0 step; each is a binary gate).

> **Run 0c FIRST**, before anything else in Phase 0 — including before booting up the manual deploy loop. Gate 0c (Azure org policy on public GHCR packages) is an email-and-meeting conversation, not engineering work. If the answer is "no public packages," §7.4 fallback A (ACR + AcrPull) or B (private GHCR + per-fork imagePullSecret) replaces D4 — which restructures W2, W3, and ONBOARD. Discovering that after Wave B agents have shipped composite actions is the largest avoidable rework in this plan. Spend a day waiting for an answer; save a week of rework.

| # | Check | Why it gates | Blocks |
|---|---|---|---|
| **0c** | **(RUN FIRST)** Confirm Azure org policy permits public GHCR packages for the publishing org. For `danielscholl-osdu` sandbox: OK. For `Azure/osdu-spi`-derived production: get explicit sign-off. | If disallowed, design switches to §7.4 fallback A or B — this changes the shape of W2, W3, ONBOARD. | **W2 finalization** (registry choice), **W3 finalization** (pull-auth path), **ONBOARD finalization** (visibility step or pull-secret step), **Phase 4 PR back to upstream** (compliance sign-off required pre-merge) |
| 0a | Confirm Helm chart materializes `Deployment/<name>` in `osdu` namespace for partition. Capture the exact `metadata.name` and container name. | If the chart names resources unpredictably, `kubectl set image deployment/partition` won't find anything (C5/D13). | **W3 merge** (action assumes specific naming) |
| 0b | Confirm AKS auth mode (Entra-managed vs. local-accounts-disabled vs. WI SA). | Drives the RoleBinding form in §6.1 step 3. | **W3 merge** (action's RBAC binding form), **ONBOARD merge** (script's RBAC step) |
| 0d | Confirm gateway URL stability — is the DNS owned and stable, or does it change on cluster re-provisioning? | A regenerable gateway URL means every fork's `GATEWAY_URL` var is a moving target. | **W4 merge** (integration-test consumes the URL) |
| 0e | Capture partition's acceptance-test data isolation strategy (does it use unique prefixes? clean up?). | Feeds §8.8 audit. If isolation is weak, partition's CI uses cluster-wide concurrency lock instead of per-service. | **W4 merge** (action's concurrency wiring and `cluster_state` semantics depend on the answer) |
| 0f | Verify operator has the RBAC required by the onboarding script (§6.1 preconditions). | If the operator can't create identities or write secrets to the repo, Phase 3 is blocked. | **ONBOARD merge** (script's preconditions check is meaningless if there's no test environment) |

**Hard-blocker rule:** Agent-authored work for `W3`, `W4`, `ONBOARD` can be drafted (PR opened) with documented assumptions, but **cannot merge** until the listed gates above are closed. `W5` (wire validate.yml) additionally cannot merge until **Phase 0 step 4a (OIDC validation)** is green on at least the four required event subjects. Reviewing PRs against unsettled gates wastes agent context — revisions for "we picked the wrong assumption" are predictable and avoidable.

**Steps:**

1. **Build locally:**
   ```
   cd danielscholl-osdu/partition
   mvn -P partition-azure clean install
   ```
   Verify: `provider/partition-azure/target/*-spring-boot.jar` exists and is ~50MB. Capture exact JAR path/filename for the Dockerfile reference.

2. **Containerize:**
   ```
   docker build -f devops/azure/Dockerfile -t ghcr.io/danielscholl-osdu/partition:poc .
   docker run --rm ghcr.io/danielscholl-osdu/partition:poc  # smoke test (port-forward or healthcheck)
   ```

3. **Push to GHCR:**
   ```
   gh auth token | docker login ghcr.io -u danielscholl-osdu --password-stdin
   docker push ghcr.io/danielscholl-osdu/partition:poc
   # NOTE: danielscholl-osdu is an org, so the package is org-owned.
   # For user-owned packages the endpoint is /user/packages/... — see §7.4 guidance.
   gh api -X PATCH /orgs/danielscholl-osdu/packages/container/partition/visibility -f visibility=public
   ```

4. **Manually provision managed identity** for `danielscholl-osdu/partition` per §6.1 steps 1-5. Use the RoleBinding form determined by step 0b.

4a. **Validate the OIDC path end-to-end.** Use the checked-in `.github/template-workflows/oidc-smoke-test.yml` workflow (delivered by the `POC` sub-issue) that exercises only `azure/login@v2` + `az aks get-credentials` + `kubectl get deployments -n osdu`:
   ```yaml
   - uses: azure/login@v2
     with:
       client-id: ${{ secrets.AZURE_CLIENT_ID }}
       tenant-id: ${{ secrets.AZURE_TENANT_ID }}
       subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
   - run: az aks get-credentials -g $RG -n $CLUSTER
   - run: kubectl get deployments -n osdu
   ```
   Run from each federated-credential subject we'll need at production: dispatch on `main`, on a feature branch via push, via PR open, and (when release flow lands) on a tag push. Each one that fails surfaces a missing or mismatched federated credential — fix before W2/W3 are written.

   **The workflow is a checked-in artifact, not a throwaway.** Re-run it any time federated credentials are edited (subject claims added, rotated identities, etc.). It's the only repeatable proof the credential is correctly configured.

5. **Cluster CI-mode:**
   ```
   az aks get-credentials --resource-group <rg> --name <cluster>
   # Verify Flux state — should be suspended by now per §7.5 invariant
   flux get all -n flux-system
   # If anything is reconciling, this is a violation of C4/§7.5 — pause and investigate
   flux suspend kustomization --all -n flux-system  # idempotent
   ```

6. **Deploy via kubectl** (use the names captured in step 0a):
   ```
   kubectl set image deployment/${K8S_DEPLOYMENT_NAME} ${K8S_CONTAINER_NAME}=ghcr.io/danielscholl-osdu/partition:poc -n osdu
   kubectl rollout status deployment/${K8S_DEPLOYMENT_NAME} -n osdu --timeout=5m
   ```

7. **Acceptance tests:**
   ```
   # Pull secrets from KV — capture exact names; this becomes ACCEPTANCE_TEST_SECRET_MAP
   export PARTITION_BASE_URL=https://gateway/api/partition/v1
   export INTEGRATION_TESTER=$(az keyvault secret show ...)
   # ... other env vars
   cd partition-acceptance-test
   time mvn verify   # capture runtime — feeds Q8: is this <10min for per-PR cadence?
   ```

**Exit criteria:**
- Step 0 prerequisites all answered (one row per gate, written into POC notes)
- Image is in GHCR, public, pullable
- Step 4a OIDC validation green on at least: main push, feature-branch push, PR sync (head=base), tag push (use a throwaway tag)
- Deployment is running the new image (verify `kubectl get deployment -o jsonpath='{.spec.template.spec.containers[0].image}'`)
- Gateway returns valid responses to partition API endpoints
- Acceptance tests run to completion (pass or fail is OK — just must run; runtime captured)
- All authentication paths exercised and documented
- All Key Vault secret names captured for later automation
- Per-service test data isolation strategy captured (gate 0e)

**Output artifact:** A Markdown document committed to the design directory at `doc/product/cicd-poc-notes.md` capturing every gotcha, every command actually used, every error encountered. **Do not capture secret values** — only secret names, KV references, and resource IDs. The file is checked into a public repo.

### 9.2 Phase 1 — Sandbox Engineering System Setup

**Effort:** XS
**Status:** Largely complete; one verification step outstanding.

**Goal:** Establish the safe iteration environment.

**Steps:**

1. ✅ **Fork `Azure/osdu-spi`** to `danielscholl-osdu/osdu-spi`.

2. ✅ **Reconfigure `danielscholl-osdu/partition` template sync** to pull from sandbox instead of `Azure/osdu-spi`. Per ADR-012 / `template-sync.yml`, this is the `TEMPLATE_REPO_URL` repo variable on partition.

3. **Pending — verify template-sync round-trip works** (sandbox → partition PR): make a trivial change in sandbox (e.g., comment update in a template-workflow), trigger the daily `sync.yml` on partition manually via `workflow_dispatch`, confirm a PR opens against `fork_upstream`. This must work before Phase 2 begins, because Phase 2's iteration model assumes "edit sandbox → see change applied to partition" works.

**Exit criteria:**
- Sandbox repo exists and tracks Azure/osdu-spi as upstream ✅
- Partition fork pulls templates from sandbox ✅
- Round-trip update (sandbox → partition) works via template-sync ⏳ (gate to Phase 2)

### 9.3 Phase 2 — Workflow Implementation in Sandbox

**Effort:** L (13 work items; sub-issues are mostly XS/S/M individually — see `cicd-implementation-plan.md`)
**Goal:** Build the new workflow stages in the sandbox engineering system. Iterate until end-to-end green on `danielscholl-osdu/partition`.

**Work items (each is one or more PRs in sandbox):**

| # | Work item | Component |
|---|-----------|-----------|
| W1 | Parameterize `java-build` profile | Modify `.github/actions/java-build/action.yml` to accept `maven_profile` input; existing default is "no profile" (`mvn clean install`); new behaviour: when `maven_profile` is set, append `-P <profile>` |
| W2 | New composite action `docker-build` | `.github/actions/docker-build/action.yml` (digest output, immutable `:sha-*` + mutable `:<branch>-snapshot` tags) |
| W3 | New composite action `aks-deploy` | `.github/actions/aks-deploy/action.yml` (Flux pre-check, RoleBinding mode-aware kubectl, deploys by digest, emits `deployed_digest` output) |
| W4 | New composite action `integration-test` | `.github/actions/integration-test/action.yml` (digest verification, cross-service health probe, JUnit upload, retry-on-flake) |
| W5 | Wire new jobs into `template-workflows/validate.yml` **only** | Per D12. `build.yml` is untouched. New jobs gated by the §5.5 trust clause. |
| W6 | ~~`build.yml` wiring~~ | **Removed.** Was a duplicate per D12. |
| W7 | Update `template-workflows/release.yml` to tag images with release version | **Mandatory** (was optional). On release-please tag push, build + tag image as `:<version>`; do not re-deploy from `release.yml` (deploy already happened on merge to main). |
| W8 | Cluster-health-check pre-flight | `.github/actions/cluster-health-check/` — checks: cluster nodes Ready, gateway responds 2xx, Flux still suspended. Used by `deploy` and optionally as a scheduled health badge. |
| W9 | Flux-suspend assertion in deploy action | Inside `aks-deploy/action.yml` (pre-check) + `integration-test` post-rollout digest check (§5.3) |
| W10 | Update branch-protection rulesets to add new required checks | Modify `.github/rulesets/default-branch.json` to require `🐳 Docker Build`, `🚀 Deploy to spi-stack`, `🧪 Integration Tests` on PRs to `main`. Verify init workflow / template-sync propagates the rule update to existing forks. |
| W11 | Image-retention scheduled workflow | New `.github/template-workflows/ghcr-retention.yml` runs weekly, deletes GHCR tags per §8.5 policy. |
| W12 | GHCR-visibility verification step | Step inside `docker-build` action that checks the package is public; fails the job (with a clear error pointing at onboarding script) if not. |
| W13 | Add `workflow_dispatch` "force-full-pipeline" path to validate.yml | Today `validate.yml` `paths-ignore` excludes `.github/actions/**` and `.github/template-workflows/**`. That means template-sync PRs whose ONLY change is workflow/action files **do not trigger validate.yml**, breaking the sandbox→partition iteration loop. Fix: add a `workflow_dispatch` input that forces the new deploy/test stages to run against the current HEAD regardless of paths-ignore, so the operator can manually trigger a verification run after each template-sync. Document the trigger explicitly in W5 acceptance criteria. |
| W14 | New `template-workflows/restore-deployment.yml` workflow | Consumes W3's `previous_digest` output (or any known-good digest copied from a prior run's logs). `workflow_dispatch` with `service` + `digest` inputs; validates digest format; same trust-boundary protection and per-service concurrency as the deploy job; calls `aks-deploy` directly with the supplied digest. Without W14, `previous_digest` is dead-weight and §8.9's restore loop is undeliverable. |

**Per work item:** PR in sandbox → template-sync pushes to partition → operator manually triggers `validate.yml` via `workflow_dispatch` on partition (because template-sync changes are paths-ignored) → debug → iterate.

**Per work item exit criteria:** corresponding stage runs green on partition for 5 consecutive runs covering varied event types (PR open, PR sync, merge to main, cascade-driven push — not 5 whitespace pushes).

**Phase exit criteria:**
- Full pipeline green on partition for **10 substantive runs** covering at least 3 of: (a) PR open with code change, (b) PR sync with subsequent commit, (c) merge to main, (d) cascade-driven push to `fork_integration`, (e) release-please tag push. Whitespace-only pushes do not count.
- Manual deploy/test scenarios still work (sandbox didn't break manual `kubectl set image` workflows)
- `doc/product/cicd-poc-notes.md` gaps all closed
- Required-check enforcement (W10) confirmed in partition repo: a PR with intentionally failing integration test cannot merge to `main`

### 9.4 Phase 3 — Per-Fork Infrastructure Automation

**Effort:** M (cross-repo: lands in `osdu-spi-stack`)
**Goal:** Make onboarding a new service fork a single-command operation.

**Deliverable:** Extend the existing `spi` Python CLI in `osdu-spi-stack` with a new `onboard` subcommand (rather than a standalone bash script — `spi` already has the `az`/`kubectl` plumbing, retry logic, and JSON handling that an idempotent shell script would have to reinvent):

```
uv run spi onboard \
  --service partition \
  --org danielscholl-osdu \
  --aks-cluster aks-spi-stack-ci \
  --aks-rg spi-stack-ci \
  --identities-rg rg-osdu-spi-ci-identities
```

What it does, in order (each step is idempotent):

1. **Verify operator preconditions** (per §6.1 preconditions block). Fail fast with a clear remediation message if `az`/`kubectl`/`gh` aren't authenticated with the right roles.
2. Verify the target fork's `Deployment` exists in `osdu` (gate from §7.1). Capture `K8S_DEPLOYMENT_NAME` and `K8S_CONTAINER_NAME` as outputs.
3. Create managed identity in identities RG (skip if exists).
4. Add federated credentials for all relevant ref subjects (wildcard if supported; explicit otherwise). Reconcile if already present.
5. Assign AKS Cluster User role to identity (skip if assigned).
6. Create K8s RoleBinding in `osdu` namespace using the auth-mode-appropriate form (§6.1 step 3) — `kubectl apply` of a generated manifest, so reruns are safe.
7. Assign Key Vault Secrets User role (scoped per-service if KV access policy is in use).
8. **Flip GHCR package visibility to public** for `ghcr.io/<org>/<service>` (creates the package via a dummy push if it doesn't exist yet, then patches visibility). Set the retention policy per §8.5.
9. Write GitHub repo secrets (`AZURE_CLIENT_ID`/`AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID`) and per-service variables (everything in §7.3 per-fork table).
10. **Update branch-protection ruleset** on the target repo to include the new required checks (W10 lands the template; this step pushes the per-repo config).
11. Output a summary block to stdout: identity object ID, all variables set, KV secret expectations (operator must populate the KV secrets out of band — see §11 Q2).

**Exit criteria:**
- Re-run onboarding on partition (idempotent) — no errors, no duplicate role assignments, no secret overwrites unless `--force-rewrite-secrets`.
- Run onboarding on a second service (e.g., entitlements) once Phase 5 starts — produces a working CI loop with no manual steps beyond populating per-service Key Vault secrets.
- `--dry-run` mode prints the plan without making changes (useful for review).

### 9.5 Phase 4 — PR Back to Official `Azure/osdu-spi`

**Effort:** S (mostly coordination; no new code beyond what Phase 2 produced)
**Goal:** Land the validated design in the official engineering system.

**Pre-step — re-check ADR numbering:**
The design proposes ADR-032 through ADR-035 (and ADR-036 for security/trust boundaries — see §12 Appendix B). The latest ADR in `Azure/osdu-spi` at the time of writing this design was 031. Before opening the PR, run:
```
ls Azure/osdu-spi/doc/src/adr/0*.md | tail -10
```
…and renumber the new ADRs if upstream has merged additional ones in the interim.

**Steps:**

1. **Diff sandbox vs official:**
   ```
   git remote add upstream https://github.com/Azure/osdu-spi
   git fetch upstream main
   git diff upstream/main..main -- .github/template-workflows/ .github/actions/
   ```
   Confirm only the intended changes (no stray fork-resource updates leaking in).

2. **Open PR against Azure/osdu-spi** with:
   - All template-workflow changes (validate.yml additions only, per D12)
   - All composite action additions (`docker-build`, `aks-deploy`, `integration-test`, `cluster-health-check`)
   - `java-build` action change (new `maven_profile` input)
   - Ruleset changes for required-check enforcement (W10)
   - GHCR retention scheduled workflow (W11)
   - **New ADRs:** drafts in §12 Appendix B (ADR-032 through ADR-036, renumbered per pre-step if needed)
   - **New product specs:** `docker-build-workflow-spec.md`, `deploy-workflow-spec.md`, `integration-test-workflow-spec.md`
   - Updates to `architecture.md`, `workflow-strategy.md`
   - This design doc itself (`cicd-build-deploy-test-design.md`) + Phase 0 notes (`cicd-poc-notes.md`, with secret values redacted)

3. **Pre-merge checks:**
   - All existing service forks are notified (announcement issue or comment in each, scripted)
   - Operators are aware they'll need to provision managed identity per service before their next PR (linked: §6.1 + onboarding command)
   - Sandbox proof points referenced in PR description (link to 10+ green runs)
   - Compliance sign-off for GHCR-public visibility captured (gate 0c)

4. **Merge sequence:**
   - Merge ADRs first (documentation, no risk)
   - Merge composite actions second (code, but no triggers wired)
   - Merge template-workflows last (live trigger change)

**Exit criteria:**
- PR merged
- Official `Azure/osdu-spi` template-sync run propagates to existing service forks (partition will get the change — should be a no-op since it already has the equivalent from sandbox)

**Sandbox lifecycle after merge:**

The sandbox (`danielscholl-osdu/osdu-spi`) is **kept long-lived** rather than archived, for two reasons:
1. Future template changes can be developed and validated against `danielscholl-osdu/partition` before PRing back to `Azure/osdu-spi` — the same risk-isolation pattern that this design needed.
2. The sandbox absorbs upstream changes daily (template-sync from `Azure/osdu-spi`) so it stays current.

`danielscholl-osdu/partition`'s `TEMPLATE_REPO_URL` is **switched back to `Azure/osdu-spi`** after this PR merges. The sandbox keeps tracking upstream but no longer feeds partition. To use the sandbox again later (for another template change), the variable can be re-pointed.

### 9.6 Phase 5 — Rollout to Remaining Services

**Effort:** M total — each service is S (initialize + onboard + per-service audit + first CI run); 7 services, parallelizable across operators
**Goal:** All 8 services on the new CI loop.

**Order (by dependency, not alphabet — so each newly-onboarded service has its acceptance-test dependencies already running):**

1. Partition (done — reference; required by all others)
2. Entitlements (depends on partition)
3. Legal (depends on partition)
4. Schema (depends on partition + entitlements)
5. Storage (depends on partition + legal + schema)
6. Search (depends on storage; lower acceptance-test dependency footprint than indexer)
7. Indexer (depends on storage + search — onboard *after* search per note below)
8. File (depends on storage)

Indexer and Search are coupled for event-driven indexing — both can deploy independently but acceptance tests for one may need the other running. Onboard search first so its gateway is healthy by the time indexer's tests run.

Per service:
- Initialize fork from `Azure/osdu-spi` (existing init workflow, ADR-006)
- **Per-service audit** (one-time): capture `K8S_DEPLOYMENT_NAME`, `K8S_CONTAINER_NAME`, `MAVEN_PROFILE`, `ACCEPTANCE_TEST_DIR`, `ACCEPTANCE_TEST_SECRET_MAP`, test data isolation strategy (§8.8). Document in `doc/product/service-onboarding-<service>.md`.
- Run onboarding command (`spi onboard ...`) — Phase 3 deliverable
- Populate per-service KV secrets (one-time, manual or via stack provisioning)
- Verify first CI run on the new fork's main goes green
- Update §8.8 isolation status table

**Exit criteria:**
- All 8 services have green CI loops on a representative event (PR open + merge to main)
- Onboarding script needed no per-service patches (proves generality)
- §8.8 audit table fully populated
- Each fork's `Deployment` was found and patched successfully — confirming the chart-name convention holds across services

### 9.7 Effort summary

| Phase | Effort | Notes |
|-------|--------|-------|
| Phase 0 — Manual POC + prerequisite gates + OIDC validation | **M** | Operator-driven; gates surface answers Phase 2 needs |
| Phase 1 — Sandbox setup | **XS** | One verify step left |
| Phase 2 — Workflow implementation | **L** | 13 work items; mostly XS/S/M individually, parallelizable per [`cicd-implementation-plan.md`](./cicd-implementation-plan.md) |
| Phase 3 — Onboarding automation (Python CLI extension) | **M** | Cross-repo: lands in `osdu-spi-stack` |
| Phase 4 — PR back to official | **S** | Coordination + diff + ADR renumbering |
| Phase 5 — Per-service rollout | **M** | Each service is S; 7 services, parallelizable across operators |

T-shirt sizes describe **effort scale**, not wall-clock time. Real elapsed time depends on operator count, review cycles, and how many gate answers from Phase 0 trigger Phase 2 revisions. See the implementation plan for per-sub-issue sizing.

---

## 10. Risks & Mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|-----------|
| R1 | Flux is accidentally resumed mid-CI, reverting deployed image | M | H | Pre-flight assertion in deploy action (§5.2); post-rollout digest verification at start of integration-test (§5.3); §7.5 codifies Flux suspension as permanent invariant, baseline refresh is planned-outage only |
| R2 | Cross-service test flakes due to shared namespace | H | M | Per-service concurrency lock first; escalate to cluster-wide for services that can't meet §8.8 isolation discipline |
| R3 | GHCR package accidentally goes private, AKS pulls fail | L | H | W12 in-workflow visibility check; W11 onboarding script sets/restores public |
| R4 | Federated credential subject claim mismatch (branch ref edge cases, tags) | M | M | Wildcard `refs/heads/*` and `refs/tags/*` subjects; explicit `pull_request` subject; Phase 0 step 4a validates every event type before W3 |
| R5 | Acceptance tests depend on stale data from previous run | M | M | Per-run unique prefixes (§8.8); planned baseline refresh (§8.2) when drift accumulates; tests should be idempotent |
| R6 | Cluster outage blocks all PR merges | L | H | Cluster-health-check pre-flight (W8) emits clear "cluster down" error; ops can flip a repo variable to make integration-test advisory during a known outage |
| R7 | Image build is slow (~5min), drags out PR cycle | M | L | Multi-stage Dockerfile, layer caching (GHA or registry-backed), build only Azure profile |
| R8 | Eight services × 50 PRs/month = 400 deploys/month, cluster gets noisy | M | L | Acceptable; cluster is non-prod |
| R9 | Sandbox fork drifts from official, hard to PR back | M | M | Daily sync from official to sandbox; small PRs, not one big bang; sandbox remains long-lived post-Phase-4 (§9.5) |
| R10 | Onboarding script depends on operator having Azure permissions to create identities | H | L | §6.1 preconditions block; CLI fails fast with remediation message; centralized "ops" identity may be used for batch onboarding |
| R11 | Acceptance test credentials leak via Key Vault misconfig | L | H | KV RBAC scoped per service identity to read-only on specific secret prefixes; PR template warns against committing KV secret values |
| R12 | Maven profile name varies across services (`-P partition-azure` vs `-P entitlements-azure`) | H | L | `MAVEN_PROFILE` per-service repo variable; java-build action accepts it as input |
| **R13** | **`pull_request_target` deploy path executes attacker-controlled PR code with cluster credentials** | **L (today) / M (post-rollout)** | **VH** | **C8/D14 — gating clause in §5.5 excludes `pull_request_target` and `dependabot[bot]` from new jobs entirely; trust-boundary table is authoritative** |
| **R14** | **Azure org policy forbids public GHCR packages, killing D4 strategy** | **M** | **H** | **Phase 0 gate 0c surfaces this before any workflow YAML is written; §7.4 fallbacks A (ACR + AcrPull) and B (private GHCR + image-pull-secret) documented** |
| **R15** | **Broken deploy from service A leaves the cluster in a state that fails service B's tests for reasons unrelated to B's PR** | **H** | **M** | **Cross-service health probe in integration-test (§5.3, §8.9); `test_result: advisory` distinguishes contamination from genuine failure; v2 may add last-known-good rollback** |
| **R16** | **Helm chart names cluster resources unpredictably; `kubectl set image deployment/partition` finds no such resource** | **M** | **VH** | **D13 — `K8S_DEPLOYMENT_NAME`/`K8S_CONTAINER_NAME` as per-service variables captured during onboarding; Phase 0 gate 0a verifies before workflow code is written** |
| **R17** | **Phase 0 manual proof never exercises the federated identity / OIDC path; surprises only land in Phase 2** | **H (without mitigation)** | **M** | **Phase 0 step 4a — minimal `workflow_dispatch` workflow validates `azure/login@v2` for every subject before W3 begins** |

---

## 11. Open Questions

Questions that have been resolved by this design pass are listed with their resolution; remaining open questions are owned by Phase 0.

**Resolved during design refinement:**

| # | Question | Resolution |
|---|----------|------------|
| Q4 | Should release-please-tagged images be pushed to a separate "release" registry path or just tagged differently in GHCR? | Same path, additional `:<version>` tag on release-please tag push (D5/D12). `release.yml` only adds the tag — does **not** re-deploy, since deploy already happened on merge-to-main. |
| Q6 | Does the spi-stack chart provision `Deployment/<service>` resources? | **Promoted to Phase 0 gate 0a — must be verified before any other Phase 0 step.** If chart doesn't materialize Deployments with predictable names, design switches to D13 (per-service `K8S_DEPLOYMENT_NAME` variables); if chart doesn't materialize Deployments at all, design is invalidated and we revisit. |
| Q7 | If we want to test rollback scenarios in integration tests, do we need a "previous good image" pointer? | Deferred to v2 (post-MVP). Last-known-good fallback is captured in §8.9 as a future enhancement, not in scope for initial rollout. |

**Phase 0 must answer:**

| # | Question | Owner | Phase 0 step |
|---|----------|-------|--------------|
| Q1 | What is the gateway URL for the shared spi-stack CI cluster? | User | Step 0d (stability) + step 7 (value) |
| Q2 | What are the exact Key Vault secret names the acceptance tests need? | Discovered in step 7 | Step 7 |
| Q3 | Does the existing spi-stack RG have a dedicated identities RG, or do we create one? | User | Step 0f / step 4 |
| Q5 | Per-service Maven profile names — is it always `<service>-azure`? | Inspect each fork during Phase 5 (partition known: `partition-azure`) | Captured as `MAVEN_PROFILE` repo variable during onboarding |
| Q8 | Are integration tests fast enough to run on every PR (<10min)? | Measured in Phase 0 step 7 (partition); each service measures during Phase 5 onboarding | Step 7 |
| Q8-contingency | **If runtime exceeds budget**, the documented fallback (do not redesign the pipeline; pick one): (**a**) per-PR runs a tagged smoke subset via Maven `-Dgroups=...` (or surefire `<includes>`), full suite runs on merge-to-main as a separate non-blocking workflow; (**b**) per-PR deploy + sample probe (a handful of API calls against gateway), full suite runs nightly on a scheduled workflow. Decision is per-service — partition may afford (a), a slower service may need (b). | Operator at Phase 5 onboarding time | Captured in `cicd-poc-notes.md` per service |
| **Q9 (new)** | What AKS auth mode is the spi-stack cluster using (Entra-managed, local-accounts-disabled, Workload Identity SA passthrough)? Determines K8s RoleBinding syntax. | User / inspect cluster | Step 0b |
| **Q10 (new)** | Does the Azure org policy permit public GHCR packages for production publishing? (Sandbox org is fine.) | User / Azure security contact | Step 0c, blocks Phase 4 |
| **Q11 (new)** | Is the gateway URL stable across cluster re-provisioning, or DNS-regenerated? | User | Step 0d |
| **Q12 (new)** | Per-service test data isolation — does partition's acceptance-test create uniquely-prefixed data and clean up? | Audit existing partition tests | Step 0e |
| **Q13 (new)** | Per-service acceptance-test dependency graph — which services' tests call which other services' APIs? | Audit each acceptance-test pom + source | Phase 5 onboarding |

---

## 12. Appendices

### Appendix A — Workflow YAML Sketches

**A.1. Modified `template-workflows/validate.yml` (excerpt — new jobs only). Note the `if:` clause on `docker-build` implements the §5.5 trust boundary; downstream jobs inherit by `needs:`.**

```yaml
  docker-build:
    name: "🐳 Docker Build"
    needs: [check-initialization, check-repo-state, java-build]
    if: |
      (
        needs.check-repo-state.outputs.is_initialized == 'true' &&
        needs.check-repo-state.outputs.is_java_repo == 'true' &&
        needs.java-build.outputs.build_result == 'success' &&
        github.actor != 'dependabot[bot]' &&
        github.event_name != 'pull_request_target' &&
        (github.event_name != 'pull_request' ||
         github.event.pull_request.head.repo.full_name == github.repository)
      ) || (
        github.event_name == 'workflow_dispatch' &&
        inputs.force_full_pipeline == true
      )
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    outputs:
      image_repository: ${{ steps.build.outputs.image_repository }}
      image_digest: ${{ steps.build.outputs.image_digest }}
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
    if: needs.docker-build.result == 'success'
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    concurrency:
      group: spi-stack-${{ vars.SERVICE_NAME }}
      cancel-in-progress: false
    outputs:
      previous_digest: ${{ steps.deploy.outputs.previous_digest }}
      deployed_digest: ${{ steps.deploy.outputs.deployed_digest }}
    steps:
      - uses: actions/checkout@v5
      - id: deploy
        uses: ./.github/actions/aks-deploy
        with:
          azure_client_id: ${{ secrets.AZURE_CLIENT_ID }}
          azure_tenant_id: ${{ secrets.AZURE_TENANT_ID }}
          azure_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          aks_resource_group: ${{ vars.AKS_RESOURCE_GROUP }}
          aks_cluster_name: ${{ vars.AKS_CLUSTER_NAME }}
          namespace: ${{ vars.K8S_NAMESPACE }}
          deployment_name: ${{ vars.K8S_DEPLOYMENT_NAME }}
          container_name: ${{ vars.K8S_CONTAINER_NAME }}
          image_repository: ${{ needs.docker-build.outputs.image_repository }}
          image_digest: ${{ needs.docker-build.outputs.image_digest }}

  integration-test:
    name: "🧪 Integration Tests"
    needs: [deploy]
    if: needs.deploy.result == 'success'
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
          test_dir: ${{ vars.ACCEPTANCE_TEST_DIR }}
          gateway_url: ${{ vars.GATEWAY_URL }}
          keyvault_name: ${{ vars.KEYVAULT_NAME }}
          secret_map: ${{ vars.ACCEPTANCE_TEST_SECRET_MAP }}
          maven_profile: ${{ vars.MAVEN_PROFILE }}
          expected_digest: ${{ needs.deploy.outputs.deployed_digest }}
          cross_service_health: 'true'
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
  image_repository:
    value: ${{ steps.tag.outputs.image_repository }}
  image_digest:
    value: ${{ steps.push.outputs.digest }}   # sha256:... from docker/build-push-action
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
        echo "image_repository=${IMAGE}" >> $GITHUB_OUTPUT
        # Always tag with sha-* (for humans; deploy uses the digest, not this tag)
        TAGS="${IMAGE}:sha-${SHORT_SHA}"
        # On protected-branch push, also tag with <branch>-snapshot (matches Maven revision)
        if [[ "${GITHUB_EVENT_NAME}" == "push" && "${GITHUB_REF_TYPE}" == "branch" ]]; then
          BRANCH_SLUG="${GITHUB_REF_NAME//\//-}"
          TAGS="${TAGS},${IMAGE}:${BRANCH_SLUG}-snapshot"
        fi
        # On tag push (release-please), also tag with the semver
        if [[ "${GITHUB_REF_TYPE}" == "tag" ]]; then
          TAGS="${TAGS},${IMAGE}:${GITHUB_REF_NAME}"
        fi
        echo "tags=${TAGS}" >> $GITHUB_OUTPUT
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
    # steps.push.outputs.digest is the canonical immutable identifier callers should use
    # when composing the deploy reference: ${image_repository}@${image_digest}
    # IMPORTANT: docker/build-push-action emits `digest` already prefixed with "sha256:".
    # Do not prepend "sha256:" again — that produces an invalid "@sha256:sha256:..." reference.
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
  namespace: { required: true }
  deployment_name: { required: true }
  container_name: { required: true }
  image_repository: { required: true }   # e.g. ghcr.io/<org>/<service>
  image_digest:     { required: true }   # e.g. sha256:abc123...
  rollout_timeout:  { default: '5m' }
outputs:
  previous_digest:
    value: ${{ steps.capture-previous.outputs.digest }}
  deployed_digest:
    value: ${{ steps.verify.outputs.digest }}
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
    - name: Assert Flux suspended (pre-flight)
      shell: bash
      run: |
        running=$(kubectl get kustomizations -n flux-system -o json 2>/dev/null | \
          jq -r '.items[] | select(.spec.suspend != true) | .metadata.name')
        if [ -n "$running" ]; then
          echo "::error::Flux not suspended: $running. Cluster is not in CI mode. See §7.5."
          exit 1
        fi
    - name: Capture previous digest (for restore)
      id: capture-previous
      shell: bash
      run: |
        # Derive pod selector from the deployment itself (don't assume label conventions);
        # then read the currently running container's imageID -> digest.
        SELECTOR=$(kubectl get deployment ${{ inputs.deployment_name }} \
          -n ${{ inputs.namespace }} \
          -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' | sed 's/,$//')
        IMAGE_ID=$(kubectl get pods -n ${{ inputs.namespace }} -l "$SELECTOR" \
          -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="${{ inputs.container_name }}")].imageID}' 2>/dev/null || echo "")
        DIGEST="${IMAGE_ID##*@}"
        echo "digest=${DIGEST}" >> $GITHUB_OUTPUT
        echo "Previous digest: ${DIGEST:-<unknown>}"
    - name: Set image (by digest)
      shell: bash
      run: |
        kubectl set image deployment/${{ inputs.deployment_name }} \
          ${{ inputs.container_name }}=${{ inputs.image_repository }}@${{ inputs.image_digest }} \
          -n ${{ inputs.namespace }}
    - name: Wait for rollout
      shell: bash
      run: |
        kubectl rollout status deployment/${{ inputs.deployment_name }} \
          -n ${{ inputs.namespace }} \
          --timeout=${{ inputs.rollout_timeout }}
    - name: Capture deployed digest
      id: verify
      shell: bash
      run: |
        SELECTOR=$(kubectl get deployment ${{ inputs.deployment_name }} \
          -n ${{ inputs.namespace }} \
          -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' | sed 's/,$//')
        IMAGE_ID=$(kubectl get pods -n ${{ inputs.namespace }} -l "$SELECTOR" \
          -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="${{ inputs.container_name }}")].imageID}')
        DIGEST="${IMAGE_ID##*@}"
        echo "digest=${DIGEST}" >> $GITHUB_OUTPUT
        echo "Deployed digest: ${DIGEST}"
    - name: Pod status on failure
      if: failure()
      shell: bash
      run: |
        kubectl describe deployment/${{ inputs.deployment_name }} -n ${{ inputs.namespace }}
        kubectl logs deployment/${{ inputs.deployment_name }} -n ${{ inputs.namespace }} --tail=200
```

**A.4. `integration-test/action.yml` — selected excerpts.** Note: the action takes **explicit inputs**; it never reads `vars.*` or `secrets.*` directly. All workflow context is passed in at the call site. Pod selectors are derived from the live deployment, not assumed.

```yaml
# action.yml inputs (excerpt — full contract in §5.3):
inputs:
  namespace: { required: true }
  deployment_name: { required: true }
  container_name: { required: true }
  expected_digest: { required: true }
  dependencies: { required: false }   # JSON: {"partition":"/api/partition/v1/info", ...}
  gateway_url: { required: true }
  keyvault_name: { required: true }
  secret_map: { required: true }      # JSON: {"PARTITION_BASE_URL":"partition-base-url", ...}
```

```yaml
    - name: Verify deployed digest still running
      shell: bash
      env:
        NAMESPACE: ${{ inputs.namespace }}
        DEPLOYMENT: ${{ inputs.deployment_name }}
        CONTAINER: ${{ inputs.container_name }}
        EXPECTED: ${{ inputs.expected_digest }}
      run: |
        # Derive the pod selector from the deployment itself (don't assume label conventions)
        SELECTOR=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
          -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' | sed 's/,$//')
        CURRENT=$(kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" \
          -o jsonpath="{.items[0].status.containerStatuses[?(@.name==\"$CONTAINER\")].imageID}")
        CURRENT_DIGEST="${CURRENT##*@}"
        if [ "$CURRENT_DIGEST" != "$EXPECTED" ]; then
          echo "::error::Pod is running ${CURRENT_DIGEST} but deploy set ${EXPECTED}. Possible Flux resume, pod restart with stale image, or cross-service overwrite."
          exit 1
        fi
```

```yaml
    - name: Cross-service health probe
      id: health
      shell: bash
      env:
        DEPS: ${{ inputs.dependencies }}
        GW:   ${{ inputs.gateway_url }}
      run: |
        # DEPS is a JSON map of dependency-service-name -> health-endpoint path
        STATE=healthy
        if [ -n "$DEPS" ] && [ "$DEPS" != "{}" ]; then
          for svc in $(jq -r 'keys[]' <<< "$DEPS"); do
            path=$(jq -r --arg s "$svc" '.[$s]' <<< "$DEPS")
            code=$(curl -s -o /dev/null -w '%{http_code}' "${GW}${path}" || echo "000")
            if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
              echo "::warning::Dependency $svc unhealthy at ${GW}${path} (HTTP $code)"
              STATE=contaminated
            fi
          done
        fi
        echo "cluster_state=$STATE" >> $GITHUB_OUTPUT
```

```yaml
    - name: Load acceptance-test secrets from Key Vault (masked, multiline-safe)
      shell: bash
      env:
        KV: ${{ inputs.keyvault_name }}
        MAP: ${{ inputs.secret_map }}
      run: |
        for env_name in $(jq -r 'keys[]' <<< "$MAP"); do
          secret_name=$(jq -r --arg k "$env_name" '.[$k]' <<< "$MAP")
          value=$(az keyvault secret show --vault-name "$KV" --name "$secret_name" --query value -o tsv)
          # Mask the value in logs BEFORE writing it to GITHUB_ENV
          echo "::add-mask::$value"
          # Heredoc form supports multiline secrets safely
          {
            printf '%s<<__SECRET_EOF__\n' "$env_name"
            printf '%s\n' "$value"
            printf '__SECRET_EOF__\n'
          } >> "$GITHUB_ENV"
        done
```

Note the `cluster_state` output drives a PR label downstream (see §5.3 exit-code table); it does not gate the job's success/failure exit.

### Appendix B — Draft ADRs

> **ADR convention reminder.** ADRs in `doc/src/adr/` are mutable Design Records — no `Status:` field, no dates, no retrospective content. The drafts below show Context / Decision / Consequences only. Agents authoring these as files in `doc/src/adr/` should match the structure of an existing ADR (e.g. `031-template-sync-duplicate-prevention.md`) for sectioning, but **omit the `## Status` section** even though legacy ADRs include one.

**ADR-032: CI/CD Deploy Loop via Suspended Flux**

> **Context:** The OSDU SPI engineering system produces validated Maven artifacts but no container images, deployments, or integration test signal. The runtime infrastructure (osdu-spi-stack) uses Flux GitOps for production-style reconciliation but this is incompatible with a per-PR CI cadence that needs to mutate deployments freely.
> **Decision:** Run the shared osdu-spi-stack cluster with Flux fully suspended for the duration of CI/CD operation. Per-PR workflows use `kubectl set image` directly on Deployments to swap in newly-built container images, then run acceptance tests against the live service. Flux is only resumed during planned cluster baseline refresh.
> **Consequences:** (+) Per-PR cadence achievable with sub-minute deploy latency. (+) No race conditions with Flux reconciliation. (+) Simple deploy mechanism, no Helm dynamics in CI. (-) Cluster state drifts from declared HelmRelease state. (-) Requires explicit ops awareness of "CI mode." (-) Operators cannot rely on Flux to self-heal during CI cycles.

**ADR-033: GHCR as Service Image Registry**

> **Context:** SPI service Docker images need to be hosted in a registry that GH Actions can push to with no extra auth, and AKS can pull from. Candidates: ACR, GHCR.
> **Decision:** Use GHCR with packages set to public visibility. Push via `GITHUB_TOKEN`, pull anonymously from AKS.
> **Consequences:** (+) No image-pull-secret provisioning in cluster. (+) No cross-cloud auth wiring. (+) Free storage for public packages. (-) Image visibility tied to package settings — accidental private setting breaks pulls. (-) Not co-located with cluster (negligible latency in practice).

**ADR-034: Federated Identity for Actions → Azure**

> **Context:** GH Actions workflows need authenticated access to Azure (AKS, Key Vault) to deploy and run integration tests. Static credentials (`AZURE_CREDENTIALS` JSON) are deprecated and a security risk.
> **Decision:** Per service fork, provision a User-Assigned Managed Identity with federated credentials for the fork's GitHub Actions OIDC token. Workflows use `azure/login@v2` with the identity's client ID. No static secrets stored in GitHub.
> **Consequences:** (+) No long-lived secrets. (+) Per-fork blast radius — compromise of one fork's CI doesn't affect others. (-) ~20 setup steps per fork; automation required. (-) Federated subject claim must match exactly; debugging mismatches is tedious.

**ADR-035: Azure-Only Maven Profile Restriction**

> **Context:** Forked OSDU services contain multiple cloud provider profiles (AWS, Azure, IBM, GC, Core+, GC-Quarkus). Only Azure is relevant to SPI work; building others is wasted CPU and irrelevant unit-test signal.
> **Decision:** Configure the engineering system's Maven build to use `-P <service>-azure` profile only. Profile name is a per-fork variable.
> **Consequences:** (+) Faster builds (~3-5x reduction in modules built). (+) Unit-test results are 100% Azure-relevant. (-) Lose signal on whether upstream changes break other providers — acceptable since SPI doesn't ship those.

**ADR-036: Workflow Trust Boundaries for CI/CD with Cluster Credentials**

> **Context:** The new docker-build/deploy/integration-test jobs hold a federated identity with `Azure Kubernetes Service Cluster User`, namespaced `edit` on the shared `osdu` namespace, and `Key Vault Secrets User`. The default GitHub Actions trigger surface (especially `pull_request_target`, but also dependabot PRs and external-fork PRs) can place attacker-controlled code in a context that has access to repo secrets. Running the new jobs in those contexts would expose the cluster federated identity to attacker code, risking compromise across all 8 forks.
> **Decision:** The new jobs run only when **all** of the following hold:
> - Event is `push` to a protected branch, OR `pull_request` from a head repo equal to the base repo, OR `workflow_dispatch`, OR a tag push.
> - Actor is not `dependabot[bot]` (dependabot-validation.yml is the dependency-update path; dependabot does not need cluster access).
> - Event is not `pull_request_target`.
> External-fork PRs lose deploy/test signal — maintainers must validate locally before merge. Cascade-driven pushes to `fork_integration` **do** trigger deploy (treated equivalently to a maintainer push).
> **Consequences:** (+) Cluster credentials are never exposed to attacker-controlled code. (+) Trust model is explicit and uniformly applied across forks. (-) External contributors get reduced CI signal on their PRs; maintainer must run validation in a trusted context before merge. (-) The `if:` clause is verbose and easy to forget when adding new sensitive jobs — must be enforced via review template.

### Appendix C — Cluster Setup Checklist

Pre-Phase 0 (gates from §9.1 step 0):

- [ ] Confirm shared spi-stack cluster is running (`uv run spi status`)
- [ ] Confirm Flux is suspended (`flux get all -n flux-system` — every Kustomization shows `Suspended: True`)
- [ ] **Gate 0a:** Confirm `osdu` namespace has a `Deployment` per service; capture exact `metadata.name` and container name for partition
- [ ] **Gate 0b:** Identify AKS auth mode (Entra-managed vs. local-accounts-disabled vs. Workload Identity SA)
- [ ] **Gate 0c:** Confirm public GHCR packages are allowed under the publishing org's policy (sandbox OK; production needs explicit sign-off pre-Phase-4)
- [ ] **Gate 0d:** Confirm gateway URL stability (stable DNS or regenerated per cluster?)
- [ ] **Gate 0e:** Capture partition acceptance-test data isolation strategy (unique prefixes? cleanup?)
- [ ] **Gate 0f:** Verify operator has the RBAC required by the onboarding script (§6.1 preconditions)
- [ ] Confirm gateway URL is reachable (`curl https://<gateway>/api/partition/v1/info`)
- [ ] Identify Key Vault name and confirm RBAC model (`az keyvault list`)
- [ ] Identify identities RG (create if needed)
- [ ] Verify ability to create managed identities (`az ad sp list --show-mine`)

Pre-Phase 1:

- [x] Fork osdu-spi to sandbox org
- [x] Note current template-sync upstream URL in partition fork
- [ ] Confirm template-sync workflow is functional in partition (sandbox → partition round-trip — see §9.2 step 3, currently the only outstanding Phase 1 item)

Pre-Phase 4:

- [ ] All Phase 2 work items (W1–W12) merged to sandbox
- [ ] Partition CI on sandbox is green for 10+ **substantive** runs (per §9.3 phase exit criteria)
- [ ] `doc/product/cicd-poc-notes.md` captures resolutions to every gotcha
- [ ] Onboarding command (`spi onboard`) tested re-running on partition (idempotent)
- [ ] ADR numbers re-checked vs. upstream `Azure/osdu-spi`
- [ ] GHCR-public compliance sign-off obtained (Gate 0c)

### Appendix D — Glossary

- **Engineering system:** `Azure/osdu-spi` — the template repository. Defines workflows, actions, configs that flow to service forks.
- **Service fork:** A forked OSDU service repo (`danielscholl-osdu/partition`, etc.) that inherits from the engineering system.
- **Sandbox engineering system:** `danielscholl-osdu/osdu-spi` — fork of the official template used for safe iteration. Kept long-lived after Phase 4 (§9.5).
- **Stack:** `osdu-spi-stack` — runtime infrastructure repo providing AKS + Flux + Helm chart, plus the `spi` Python CLI.
- **CI cluster:** The single shared AKS instance brought up by `spi up`. **Permanently in CI mode (Flux suspended) as steady state** (C4 / §7.5).
- **CI mode:** Cluster state with all Flux Kustomizations suspended. Permanent steady state for this design, not a transient toggle.
- **Baseline refresh:** Planned-outage operation (§7.5) that temporarily resumes Flux to reset cluster state, then re-suspends. Requires CI freeze across all forks.
- **Template-sync:** The daily workflow that propagates changes from engineering system to service forks.
- **Cascade:** The branch-flow process (upstream → fork_upstream → fork_integration → main) for incorporating upstream OSDU changes. Triggers deploy (D15).
- **Federated credential:** Azure AD construct allowing a managed identity to be assumed via an OIDC token from GitHub Actions, without storing static secrets.
- **Trust boundary:** The §5.5 / ADR-036 rule set defining which workflow events are allowed to use the cluster federated identity.
- **Deployed digest:** The sha256 digest captured from a running pod after `kubectl rollout status` succeeds. Used to verify mid-test that the deployed image is still what's running (§5.3, §8.7).

---

**End of design.** Open questions, comments, and revisions welcome before promoting any section to ADR / spec / implementation.

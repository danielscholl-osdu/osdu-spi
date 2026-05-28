# CI/CD Phase 0 — Proof-of-Concept Notes

> **Do not commit secret or sensitive values.** Record variable/secret **names**, Key Vault
> references, and the *shape* of a finding only — never live credentials, tenant/subscription
> identifiers, operator PII, or concrete infrastructure endpoints. Actual values live in the
> cluster, Key Vault, or per-repo Actions variables, not in this repo (which mirrors upstream).

Operational record for the Phase 0 prerequisite gates (epic #1, design §6). Full authoritative
context: [cicd-build-deploy-test-design.md](cicd-build-deploy-test-design.md). This doc captures
the *resolution* of each gate plus the per-service variable **names** the Deploy-lane workflows
consume — so later slots can rely on a consistent Question / Finding / Resolution structure.

## Cluster under test

| Field | Value |
|---|---|
| Context | `spi-stack-dks` |
| AKS cluster / RG | `spi-stack-dks` (name doubles as RG) |
| Service namespace | `osdu` |
| Operator | redacted — Microsoft FTE; identity tracked outside git |
| Subscription | redacted — see internal runbook |

## Gate results

Each gate uses **Question / Finding / Resolution**. Sensitive specifics are referenced by the
Actions variable / secret **name** that carries them; values are not committed.

### Gate 0c — Container registry choice ✅ Resolved

- **Question:** Where do CI service images live — public GHCR, MCR, or private GHCR/ACR?
- **Finding:** Observable Azure-org precedent normalizes public GHCR for CI/tooling containers;
  MCR's "no direct GHCR" policy targets customer-shipped product containers, not CI test artifacts.
- **Resolution:** Proceed with **public GHCR** on the `danielscholl-osdu` sandbox + reference fork.
  A future MCR/ACR pivot is deferred to Phase 4 upstream review (design §7.4 *"Migration-swap scope"*:
  MCR/ACR paths are localized; private-GHCR fallback is broader-touch). Build lane can fire now.

### Gate 0a — Deployment materializes; capture per-service names ✅ Resolved

- **Question:** Does the chart render a `Deployment` in `osdu`, and what are its names?
- **Finding:** The `partition` Helm chart renders one Deployment with a single container; both names match.
- **Resolution:** Per-service variables (non-sensitive — safe to record):

  | Variable | Value |
  |---|---|
  | `K8S_DEPLOYMENT_NAME` | `osdu-partition` |
  | `K8S_CONTAINER_NAME` | `osdu-partition` |

  Deploy shape: `kubectl set image deployment/osdu-partition osdu-partition=<image>@<digest> -n osdu`.

### Gate 0b — AKS auth mode → RoleBinding syntax ✅ Resolved

- **Question:** What auth mode is the cluster in, and how does that shape the deploy identity's grant?
- **Finding:** `disableLocalAccounts=true` (Entra-only; no local kubeconfig) **and**
  `aadProfile.enableAzureRbac=true` (authorization is Azure RBAC for Kubernetes, not k8s-native RBAC alone).
- **Resolution:** The GitHub deploy identity is granted via an **Azure role assignment**
  (AKS RBAC Writer, or a namespace-scoped custom role on `osdu`) — provisioned cluster-side by
  `spi onboard`. A plain k8s `RoleBinding` alone is insufficient. The OIDC issuer needed for the
  federated credential is captured as variable **`AKS_OIDC_ISSUER_URL`** (value stored outside git).
  The pod's app-runtime workload identity (SA `workload-identity-sa`; client-id carried as
  **`WORKLOAD_IDENTITY_CLIENT_ID`**, tenant as **`AZURE_TENANT_ID`**) is **separate** from the
  deploy identity and unused by CI.

### Gate 0d — Gateway URL stability ✅ Resolved

- **Question:** Is the service gateway URL stable, or regenerated per cluster?
- **Finding:** Stable DNS backed by a **Static** public IP; all 13 services share the host via
  path-based `HTTPRoute`s on the `spi-gateway` (Gateway API, Istio class). The hostname embeds the
  cluster name, so it is stable *within* a cluster but regenerated per cluster.
- **Resolution:** Store the endpoint as a per-cluster Actions variable **`GATEWAY_URL`** (value not
  committed). Never hardcode the host/IP in workflow YAML.

### Gate 0f — Operator RBAC ✅ Resolved (operator side)

- **Question:** Does the operator hold the Azure + Kubernetes + GitHub access Phase 0 needs?
- **Finding:** Azure: authenticated (operator redacted above). Kubernetes:
  `kubectl auth can-i patch deployments/osdu-partition -n osdu` → `yes`. GitHub: repo admin on
  `danielscholl-osdu/osdu-spi` (branch-protection ruleset applied directly).
- **Resolution:** Operator-side access is sufficient. Still to verify when `spi onboard` runs:
  operator can create the federated credential + Azure role assignment for the *deploy* identity
  (distinct from the operator's own access).

### Gate 0e — Acceptance-test data isolation ⏳ Open

- **Question:** How does the partition acceptance-test suite isolate data (unique prefixes? cleanup?)?
- **Finding:** Not answerable from the cluster — lives in the `danielscholl-osdu/partition`
  acceptance-test suite.
- **Resolution:** Pending — inspect the partition repo's acceptance tests; track separately.

### Step 4a — OIDC smoke test ⏳ Blocked

- **Question:** Does the federated-credential path work for every event subject?
- **Finding:** `.github/template-workflows/oidc-smoke-test.yml` does not exist yet (sub-issue #11).
- **Resolution:** Blocked on #11. Issuer is captured as `AKS_OIDC_ISSUER_URL`; once the workflow
  lands, re-run for each event subject (main push, feature push, PR sync, tag push).

## Flux steady state — action taken

Design §7.5 assumes Flux reconciliation is permanently suspended ("CI mode as steady state").
The cluster did **not** reflect this: all kustomizations were active, and `osdu-partition` is
rendered by HelmRelease `partition` under Kustomization `spi-osdu-services` (`interval=10m`).
Unsuspended, that reverts CI's `kubectl set image` within ≤10m via Helm drift correction.

Suspended both levels so the deploy POC holds (HelmRelease alone is insufficient — the
Kustomization re-applies the HelmRelease manifest and clears its suspend flag):

```
flux suspend kustomization spi-osdu-services
flux suspend helmrelease partition
```

Resume (restores GitOps reconciliation):

```
flux resume helmrelease partition
flux resume kustomization spi-osdu-services
```

Whether this suspension becomes the permanent steady state is an `osdu-spi-stack` decision,
not this repo's.

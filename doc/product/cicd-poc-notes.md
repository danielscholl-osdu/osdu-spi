# CI/CD Phase 0 — Proof-of-Concept Notes

Operational record for the Phase 0 prerequisite gates (epic #1, design §6). Captures the
values the Deploy-lane workflows consume as per-service variables, the cluster auth shape
that drives RoleBinding syntax, and gotchas surfaced while validating the deploy loop by hand.

## Cluster under test

| | |
|---|---|
| Context | `spi-stack-dks` |
| AKS cluster / RG | `spi-stack-dks` / `spi-stack-dks` |
| Service namespace | `osdu` |
| Operator | `dascholl@microsoft.com` (subscription `MCI-ENERGY-OSDU-DEVELOPER`) |

## Gate results

### 0a — Deployment materializes; capture per-service names ✅

The `partition` Helm chart renders `Deployment/osdu-partition` in `osdu`. Per-service variables:

| Variable | Value |
|---|---|
| `K8S_DEPLOYMENT_NAME` | `osdu-partition` |
| `K8S_CONTAINER_NAME` | `osdu-partition` |

Deploy command shape: `kubectl set image deployment/osdu-partition osdu-partition=<image>@<digest> -n osdu`.

### 0b — AKS auth mode → RoleBinding syntax ✅

| Property | Value | Consequence |
|---|---|---|
| `disableLocalAccounts` | `true` | No local kubeconfig; all access is Entra (AAD). |
| `aadProfile.enableAzureRbac` | `true` | Authorization is **Azure RBAC for Kubernetes**, not k8s-native RBAC alone. |
| OIDC issuer | `https://eastus2.oic.prod-aks.azure.com/58975fd3-…/dc3a99c8-…/` | Needed for the GitHub federated credential (step 4a). |

Implication for W3 (`aks-deploy`): the GitHub deploy identity is granted via an **Azure role
assignment** (AKS RBAC Writer, or a custom role scoped to the `osdu` namespace) — this is what
`spi onboard` provisions cluster-side. A plain k8s `RoleBinding` is not sufficient on its own
because local accounts are disabled and Azure RBAC governs authz.

The pod's app-runtime identity (`workload-identity-sa`, client-id `3eb2ec95-…`) is **separate**
from the deploy identity and is not used by CI.

### 0d — Gateway URL stability ✅

Stable DNS on a **Static** public IP — safe to treat as a per-cluster constant:

```
https://spi-stack-dks-ingress.eastus2.cloudapp.azure.com   (PIP 4.152.225.187, allocation=Static)
```

All 13 services share the host via path-based `HTTPRoute`s on the `spi-gateway` (Gateway API,
Istio class). The hostname embeds the cluster name, so it is stable **within** a cluster but
regenerated per cluster → store as a per-cluster CI variable (e.g. `GATEWAY_URL`), never hardcode.

### 0f — Operator RBAC ✅ (operator side)

- **Azure**: authenticated as `dascholl@microsoft.com`.
- **Kubernetes**: `kubectl auth can-i patch deployments/osdu-partition -n osdu` → `yes`.
- **GitHub**: repo admin on `danielscholl-osdu/osdu-spi` (branch-protection ruleset applied directly).

Still to verify when `spi onboard` runs: operator can create the federated credential and the
Azure role assignment for the *deploy* identity (distinct from operator's own access above).

### 0e — Acceptance-test data isolation ⏳ open

Not answerable from the cluster — lives in the `danielscholl-osdu/partition` acceptance-test
suite (unique partition prefixes? post-run cleanup?). Track separately.

### 4a — OIDC smoke test ⏳ blocked

`.github/template-workflows/oidc-smoke-test.yml` does not exist yet (sub-issue #11). Issuer URL
above is captured for when it lands; re-run for each event subject (main push, feature push,
PR sync, tag push) once checked in.

## Flux steady state — action taken

Design §7.5 assumes Flux reconciliation is permanently suspended ("CI mode as steady state").
The cluster did **not** reflect this: all kustomizations were active (`READY=True`, no suspend),
and `osdu-partition` is rendered by HelmRelease `partition` under Kustomization `spi-osdu-services`
(`interval=10m`). An unsuspended state reverts CI's `kubectl set image` within ≤10m via Helm
drift correction.

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

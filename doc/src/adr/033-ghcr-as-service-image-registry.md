# ADR-033: GHCR as Service Image Registry

## Context

- SPI service images are CI test artifacts consumed by the shared `spi-stack` AKS cluster.
- The publishing-org policy context differs from customer-shipped product containers:
  - Microsoft MCR onboarding policy (`aka.ms/mcr/onboarding`) applies to customer product container publishing.
  - SPI service images are internal CI/tooling artifacts, so the policy scope does not require immediate MCR publishing.
- Observable precedent in `github.com/Azure` normalizes public GHCR usage for CI/tooling containers:
  - 300+ public GHCR packages exist (as observed in the ADR-033 design analysis snapshot).
  - Examples include Eraser (~1.55B downloads), `azd`, `kubelogin`, `c3`, and `azure-workload-identity`.

## Decision

- Use **public GHCR** as the SPI service image registry.
- Keep image publication aligned with current CI/test-consumer needs in the shared `spi-stack` AKS environment.
- Defer MCR migration as a future decision rather than a current requirement.

## Consequences

- Positive:
  - Fast path for publishing and consuming service images in existing SPI CI workflows.
  - Aligns with established Azure GitHub ecosystem practices for tooling/CI containers.
  - Avoids unnecessary onboarding overhead for non-customer-facing artifacts.
- Trade-off:
  - If policy interpretation or artifact scope changes, registry choice may need to be swapped later.

## Alternatives Considered

- **Option A — ACR + existing `AcrPull` (or future MCR path)**:
  - Viable fallback and aligns with §7.4 future migration framing.
  - Migration-swap scope is **localized**:
    - Touches only the visibility helper used by `W2`, `ONBOARD-INIT-A`, and `SETTINGS-APPLY`.
  - Deferred for now because current GHCR approach already satisfies CI/test-artifact needs.

- **Option B — private GHCR + per-fork `imagePullSecret`**:
  - Viable fallback but **broader-touch** operationally.
  - Requires additional implementation beyond the visibility helper:
    - `regcred` Secret creation in the `osdu` namespace.
    - Chart-level `imagePullSecrets:` wiring.
    - Secret-provisioning step in `ONBOARD`.
  - Not selected due to higher rollout and maintenance complexity across forks.

[← ADR-031](031-template-sync-duplicate-prevention.md) | :material-arrow-up: [Catalog](index.md)

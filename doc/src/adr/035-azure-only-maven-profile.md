# ADR-035: Azure-Only Maven Profile Restriction

## Status
**Accepted** - 2026-06-01

## Context

- CI currently has the ability to build multiple cloud-provider Maven profiles (Azure, AWS, IBM, GC), but this repository is focused on Azure SPI delivery.
- Running non-Azure profiles in every SPI CI run increases build cost and time without providing direct release value for Azure deliverables.
- Teams need a per-service configuration mechanism so each repository can select the profile CI should execute.

## Decision

- CI builds only the Azure Maven profile for each service (`-P <service>-azure`).
- The configuration knob is a per-service repository variable: `MAVEN_PROFILE`.
- Workflow logic reads `MAVEN_PROFILE` and passes it to Maven profile selection during CI execution.

## Consequences

- **Positive**
  - Faster and cheaper CI for Azure SPI service repositories.
  - Clear, repository-local control of profile selection through `MAVEN_PROFILE`.
- **Negative**
  - Reduced signal for regressions in non-Azure provider profiles (AWS/IBM/GC), because those profiles are no longer validated in the standard SPI CI path.
- **Neutral**
  - Cross-provider validation, when needed, must be handled outside this default CI path.

## Alternatives Considered

- Continue building all provider profiles in every CI run.
  - Rejected due to higher runtime/cost and lower relevance to Azure-focused delivery.

---

[← ADR-031](031-template-sync-duplicate-prevention.md) | :material-arrow-up: [Catalog](index.md)

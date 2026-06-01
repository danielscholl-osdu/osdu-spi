# ADR-035: Azure-Only Maven Profile Restriction

## Context

- Forked OSDU services carry multiple cloud-provider Maven profiles (Azure, AWS, IBM, GC, Core+, GC-Quarkus). Only Azure is relevant to SPI work.
- Building and unit-testing the non-Azure profiles in every SPI CI run is wasted CPU and irrelevant signal.
- Each service needs a per-repository control point so CI selects only the profile that matters for that fork.

## Decision

- CI builds only the Azure Maven profile for each service (`-P <service>-azure`).
- The control point is a per-service repository variable: `MAVEN_PROFILE` (e.g. `partition-azure`).
- Workflow logic reads `MAVEN_PROFILE` and passes it to Maven profile selection during CI. An empty or unset value must fail fast rather than silently degrade to a full multi-provider build.

## Consequences

- **Positive**
  - Faster, cheaper CI (~3–5× fewer modules built) for Azure SPI service repositories.
  - Unit-test results are 100% Azure-relevant.
  - Clear, repository-local control of profile selection through `MAVEN_PROFILE`.
- **Negative**
  - Lost signal on whether upstream changes break other providers (AWS/IBM/GC) — acceptable since SPI does not ship those.
- **Neutral**
  - Cross-provider validation, when needed, is handled outside this default CI path.

## Alternatives Considered

- **Continue building all provider profiles in every CI run** — rejected: higher runtime/cost and low relevance to Azure-focused delivery.

## Related

- [ADR-025](025-java-maven-build-architecture.md) — the Java/Maven build architecture this profile restriction narrows.

---

[← ADR-034](034-federated-identity-actions-to-azure.md) | :material-arrow-up: [Catalog](index.md)

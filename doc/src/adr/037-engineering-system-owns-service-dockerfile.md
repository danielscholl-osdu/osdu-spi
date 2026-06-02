# ADR-037: Engineering System Owns the Canonical Service Dockerfile

## Context

- The `docker-build` / `docker-push` jobs (W5a) need a Dockerfile to turn each service's JARs into a container image. The merged `docker-build` action defaulted `dockerfile_path` to `devops/azure/Dockerfile` — assuming every service fork ships its own usable Dockerfile.
- That assumption does not hold. The `partition` reference fork's in-repo `provider/partition-azure/Dockerfile` is stale and unusable for this pipeline: it bases on `openjdk:8-jdk-alpine` (CI builds JDK17), `COPY`s a fictional `partition-aks-1.0.0.jar` (the real artifact is `partition-azure-<version>-spring-boot.jar`), and uses a module-relative build context. Other services may carry a different Dockerfile, an outdated one, or none at all.
- OSDU itself does not treat the Dockerfile as service-owned. Its GitLab pipeline clones a shared `service-base-image` repository and copies `java/Dockerfile` into each service at build time; the recipe is service-agnostic via a `JAR_FILE` build-arg, and the AppInsights agent is baked into the base image at `/opt/agents/`.
- The deployable JAR is built from source by our own `java-build` job and consumed as the `build-artifacts` artifact; the image build is a COPY-prebuilt step, not a Maven run (ADR-025, and the docker-build action contract). The OSDU Maven registry is used only to resolve build **dependencies** — never to fetch the service's own deployable JAR.

## Decision

- The engineering system (`osdu-spi`) owns a single canonical Java service Dockerfile at `build/Dockerfile`, synced to every fork via `sync-config.json` (`directories[]`, `sync_all`). Service forks do not supply their own Dockerfile for CI; the `docker-build` action default `dockerfile_path` becomes `build/Dockerfile`.
- The recipe mirrors the OSDU community `service-base-image/java/Dockerfile`: `COPY ${JAR_FILE} app.jar` into a base image, with the JVM / AppInsights / MSI environment the community image expects. No Maven runs inside the image build.
- `JAR_FILE` is supplied by the caller as a build-arg pointing at the JAR our `java-build` job produced — default `provider/<SERVICE_NAME>-azure/target/*-spring-boot.jar`, overridable per service via `vars.SERVICE_TARGET_JAR`. The JAR is always one we built from source; it is never a prebuilt artifact pulled from OSDU's Maven registry.
- `BASE_IMAGE` is an `ARG`, defaulting to OSDU's `alpine-zulu17` for runtime parity with the community image. Keeping it an `ARG` makes a later registry pivot (mirror the base into GHCR, or move to a public base) a one-line change with no Dockerfile rework.

## Consequences

### Positive

- One Dockerfile to audit and patch (base CVE bumps, JVM flags) for all forks — no per-fork drift.
- A new or Dockerfile-less service builds an image with zero per-service Docker work: onboarding sets `SERVICE_NAME` (and `MAVEN_PROFILE`), and the canonical Dockerfile arrives via sync.
- The image provably ships the JAR we compiled from source, not a third-party artifact.

### Negative

- The base-image default points at OSDU's GitLab container registry (`community.opengroup.org:5555`). If a GitHub Actions runner cannot pull it anonymously, the build fails at `FROM` — that is the signal to mirror the base into GHCR or move to a public base, a `BASE_IMAGE` swap rather than a redesign.
- A service whose JAR deviates from the `<name>-azure/target/*-spring-boot.jar` convention must set `vars.SERVICE_TARGET_JAR`.
- A fork can no longer trivially diverge its Dockerfile — intentional, consistent with the template/engineering-system model (ADR-003).

### Neutral

- Stale in-repo Dockerfiles in service forks become simply unused by CI; they may be removed upstream later but do not block the pipeline.

## Alternatives Considered

- **Service-owned Dockerfile (the original default)** — rejected: partition's is stale and wrong, not every service has one, and the model produces per-fork drift and silent build failures.
- **Pull the prebuilt service JAR from OSDU's Maven registry** — rejected: the build lane must build and ship our own JAR for provenance; OSDU's own pipeline also builds the JAR itself and uses the registry only for dependencies.
- **Build-from-source inside the Dockerfile (multi-stage `mvn package`)** — rejected: duplicates the `java-build` job, loses the shared Maven cache and the coverage path, and slows every image build.

---

[← ADR-036](036-workflow-trust-boundaries.md) | :material-arrow-up: [Catalog](index.md)

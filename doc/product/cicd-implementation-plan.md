# OSDU SPI CI/CD: Implementation Plan & Sub-Issue Catalog

**Status:** Active
**Companion to:** [`cicd-build-deploy-test-design.md`](./cicd-build-deploy-test-design.md)
**Live epic (this fork):** [#1](https://github.com/danielscholl-osdu/osdu-spi/issues/1)

---

## Purpose

This document is the **canonical work breakdown** for the CI/CD pipeline epic. It serves three audiences:

1. **Humans orchestrating the rollout** — track which slots are in flight, which are blocked, what's next.
2. **Copilot / Claude Code agents** assigned to a single sub-issue — understand context, see where your slice fits, find the design-doc references your task points at.
3. **Forkers** rebuilding this repo from scratch — regenerate the 17 GitHub issues with one script run.

## How to use this document

> [!IMPORTANT]
> **If you are an agent assigned to a single sub-issue:** read **only** the section for your assigned slot plus the design-doc sections it references. Do not implement anything else in this catalog unless you have been explicitly assigned the corresponding GitHub issue.

> [!NOTE]
> **Drift policy.** GitHub issues are the live progress tracker. This catalog is the authoritative spec. If they disagree on *what* a sub-issue should do, the catalog wins (regenerate the issue from this doc). If they disagree on *whether the sub-issue is done*, the GitHub issue wins (that's its job).

## Identifier convention

Each sub-issue has a **slot ID** (`W1`, `W7`, `ADR-032`, `POC`, `ONBOARD`, `SPECS`) that is stable across regenerations, and a **live issue number** (`#2`, `#3`, …) that changes when the issues are recreated on a fresh fork. References in this doc use slot IDs; the live mapping appears in the [Live mapping](#live-mapping) section below.

---

## Dependency map

```mermaid
graph TD
    classDef batch1 fill:#dbeafe,stroke:#1e40af,color:#1e3a8a
    classDef batch2 fill:#fef3c7,stroke:#a16207,color:#713f12
    classDef human fill:#fee2e2,stroke:#b91c1c,color:#7f1d1d
    classDef adr fill:#dcfce7,stroke:#15803d,color:#14532d

    subgraph Batch1["Batch 1 — parallel, no blocking deps"]
        W1["W1<br/>java-build profile"]:::batch1
        W2["W2<br/>docker-build"]:::batch1
        W3["W3<br/>aks-deploy"]:::batch1
        W4["W4<br/>integration-test"]:::batch1
        W8["W8<br/>cluster-health-check"]:::batch1
        W7["W7<br/>release.yml tag"]:::batch1
        W10["W10<br/>rulesets"]:::batch1
        W11["W11<br/>GHCR retention"]:::batch1
        POC["POC<br/>POC skeleton"]:::batch1
        ONBOARD["ONBOARD<br/>spi onboard CLI<br/>(cross-repo)"]:::batch1
        ADR32["ADR-032"]:::adr
        ADR33["ADR-033"]:::adr
        ADR34["ADR-034"]:::adr
        ADR35["ADR-035"]:::adr
        ADR36["ADR-036"]:::adr
        SPECS["SPECS<br/>workflow specs"]:::adr
    end

    subgraph Batch2["Batch 2 — after Batch 1"]
        W5["W5<br/>wire validate.yml"]:::batch2
    end

    subgraph Phase0["Phase 0 — human-driven, parallel with everything"]
        G["Gates 0a-0f<br/>cluster + org policy"]:::human
        OIDC["Step 4a<br/>OIDC validation"]:::human
        MANUAL["Steps 1-7<br/>manual deploy + tests"]:::human
    end

    W1 --> W5
    W2 --> W5
    W3 --> W5
    W4 --> W5

    W2 -. soft .-> W7
    W2 -. soft .-> W11

    G -. informs .-> W3
    G -. informs .-> ONBOARD
    OIDC -. informs .-> W5
```

## Wave strategy

Spawn agents in waves to avoid review overload. Each wave is fully parallel internally.

| Wave | Slots | Why this order |
|------|-------|----------------|
| **A — ground the design** | `ADR-032`, `ADR-033`, `ADR-034`, `ADR-035`, `ADR-036`, `POC` | Docs-only; reviewers reading these understand decisions before judging the code waves |
| **B — composite actions** | `W1`, `W2`, `W3`, `W4`, `W8` | The substantive code; review for design adherence |
| **C — plumbing + specs** | `W7`, `W10`, `W11`, `SPECS` | Lighter scope; runs parallel with Wave B |
| **D — cross-repo** | `ONBOARD` | Different repo (`osdu-spi-stack`); no contention with anything else |
| **Final — wire it together** | `W5` | Blocked by Wave B (`W1`, `W2`, `W3`, `W4`) |

**Phase 0 runs in parallel with all waves**, human-driven. Gate findings may trigger small revisions to Wave B (e.g., Gate 0b might flip `W3`'s RoleBinding form). Plan for that — it's normal, not a setback.

## Live mapping

The 17 sub-issues as currently filed on this fork (`danielscholl-osdu/osdu-spi`):

| Slot | Issue | Title |
|------|-------|-------|
| `W1` | [#2](https://github.com/danielscholl-osdu/osdu-spi/issues/2) | W1: Add maven_profile input to java-build action |
| `W2` | [#3](https://github.com/danielscholl-osdu/osdu-spi/issues/3) | W2: New docker-build composite action |
| `W3` | [#4](https://github.com/danielscholl-osdu/osdu-spi/issues/4) | W3: New aks-deploy composite action |
| `W4` | [#5](https://github.com/danielscholl-osdu/osdu-spi/issues/5) | W4: New integration-test composite action |
| `W5` | [#6](https://github.com/danielscholl-osdu/osdu-spi/issues/6) | W5: Wire new jobs into validate.yml |
| `W7` | [#7](https://github.com/danielscholl-osdu/osdu-spi/issues/7) | W7: Add release-version image tag to release.yml |
| `W10` | [#8](https://github.com/danielscholl-osdu/osdu-spi/issues/8) | W10: Update branch-protection ruleset for new required checks |
| `W11` | [#9](https://github.com/danielscholl-osdu/osdu-spi/issues/9) | W11: GHCR retention scheduled workflow |
| `W8` | [#10](https://github.com/danielscholl-osdu/osdu-spi/issues/10) | W8: New cluster-health-check composite action |
| `POC` | [#11](https://github.com/danielscholl-osdu/osdu-spi/issues/11) | Create POC notes skeleton (cicd-poc-notes.md) |
| `ONBOARD` | [#12](https://github.com/danielscholl-osdu/osdu-spi/issues/12) | Phase 3: Extend spi CLI with 'onboard' subcommand (cross-repo) |
| `ADR-032` | [#13](https://github.com/danielscholl-osdu/osdu-spi/issues/13) | ADR-032: Author 'CI/CD Deploy Loop via Suspended Flux' |
| `ADR-033` | [#14](https://github.com/danielscholl-osdu/osdu-spi/issues/14) | ADR-033: Author 'GHCR as Service Image Registry' |
| `ADR-034` | [#15](https://github.com/danielscholl-osdu/osdu-spi/issues/15) | ADR-034: Author 'Federated Identity for Actions to Azure' |
| `ADR-035` | [#16](https://github.com/danielscholl-osdu/osdu-spi/issues/16) | ADR-035: Author 'Azure-Only Maven Profile Restriction' |
| `ADR-036` | [#17](https://github.com/danielscholl-osdu/osdu-spi/issues/17) | ADR-036: Author 'Workflow Trust Boundaries for CI/CD' |
| `SPECS` | [#18](https://github.com/danielscholl-osdu/osdu-spi/issues/18) | Create docker-build / deploy / integration-test workflow specs |

---

## Sub-issue specifications

Each subsection below is a copy-pasteable issue body. The H3 header is the issue title.

---

### W1: Add maven_profile input to java-build action

**Slot:** `W1` &nbsp;|&nbsp; **Label:** `enhancement` &nbsp;|&nbsp; **Blocked by:** None

**Context:**
Today `.github/actions/java-build/action.yml` runs `mvn clean install` with no `-P` flag, building all cloud provider modules. The new CI/CD design (D5, ADR-035) restricts service builds to the Azure profile (e.g. `partition-azure`) to speed builds and narrow the unit-test signal. The profile name is a per-service repo variable.

**Task:**
Add an optional input `maven_profile` to the action. When set, the Maven command appends `-P <profile>`. When unset, behaviour is unchanged so existing forks don't break before they set the variable.

**Files:**
- `.github/actions/java-build/action.yml`

**Acceptance criteria:**
- [ ] `maven_profile` input declared with `required: false`, no default
- [ ] When `maven_profile` is non-empty, Maven CLI options include `-P <maven_profile>`
- [ ] When `maven_profile` is empty, behaviour is identical to today (verified by reading the modified script for unconditional branches)
- [ ] No other inputs/outputs changed; no breaking changes for existing callers

**Reference:** Design doc §9.3 W1 and Appendix B ADR-035.

**Out of scope:** Wiring `maven_profile` into validate.yml (that's W5).

---

### W2: New docker-build composite action

**Slot:** `W2` &nbsp;|&nbsp; **Label:** `enhancement` &nbsp;|&nbsp; **Blocked by:** None

**Context:**
The new pipeline needs a composite action that builds a service container image from the Maven JAR artifacts and pushes it to GHCR. Image references are immutable per SHA (`:sha-<short>`), with additional mutable tags for branches (`:<branch>-snapshot`) and release-please versions (`:<version>`). Also verifies the GHCR package is public (W12 — covered by this issue).

**Task:**
Create `.github/actions/docker-build/action.yml` per the Appendix A.2 sketch in the design doc.

The action:
- Logs into GHCR via `GITHUB_TOKEN`
- Computes tags: `:sha-<short>` always, `:<branch>-snapshot` on push, `:<version>` on tag push
- Builds and pushes via `docker/build-push-action@v6` with GHA layer cache
- Verifies the resulting GHCR package is public; fails with a clear error pointing to the onboarding script if private

**Files:**
- `.github/actions/docker-build/action.yml` (new)

**Acceptance criteria:**
- [ ] Action declares inputs per §5.1 contract (`dockerfile_path`, `build_context`, `image_name`, `registry`, `org`, `jar_artifact_name`, `build_args`)
- [ ] Outputs `image_digest` (sha256) and `image_ref` (full tag string)
- [ ] Tag computation matches §5.1 + Appendix A.2
- [ ] GHA cache wired (`cache-from: type=gha, cache-to: type=gha,mode=max`)
- [ ] Visibility check step fails with clear message if package is private
- [ ] No hardcoded secrets

**Reference:** Design doc §5.1 + Appendix A.2 + §7.4 + §9.3 W2/W12.

**Out of scope:** Wiring into validate.yml (W5). Image retention policy (W11).

---

### W3: New aks-deploy composite action

**Slot:** `W3` &nbsp;|&nbsp; **Label:** `enhancement` &nbsp;|&nbsp; **Blocked by:** None

**Context:**
Composite action that authenticates to Azure via OIDC, asserts Flux is suspended, runs `kubectl set image`, waits for rollout, captures the deployed image digest for downstream verification. Per D13, deployment_name and container_name come from per-service repo variables (not derived from SERVICE_NAME).

**Task:**
Create `.github/actions/aks-deploy/action.yml` per Appendix A.3.

**Files:**
- `.github/actions/aks-deploy/action.yml` (new)

**Acceptance criteria:**
- [ ] All inputs per §5.2 contract (`azure_*`, `aks_*`, `namespace`, `deployment_name`, `container_name`, `image_ref`, `rollout_timeout`)
- [ ] Outputs `deployed_digest` (sha256 from the running pod, not the image we asked to deploy)
- [ ] Flux-suspend pre-check fails fast if any Kustomization is reconciling (§5.2)
- [ ] Uses `azure/login@v2`; permissions block declares `id-token: write`
- [ ] `kubectl set image` correctly references `${container_name}` (not deployment_name twice)
- [ ] Failure path captures `kubectl describe` + tail of logs as an artifact
- [ ] RoleBinding-form assumption documented as a comment (initial: Entra-managed; Phase 0 gate 0b may change)

**Reference:** Design doc §5.2 + Appendix A.3 + §9.3 W3/W9.

**Out of scope:** Concurrency lock (defined at workflow level in W5). Cluster-health-check (W8).

---

### W4: New integration-test composite action

**Slot:** `W4` &nbsp;|&nbsp; **Label:** `enhancement` &nbsp;|&nbsp; **Blocked by:** None

**Context:**
Composite action that pulls acceptance test secrets from Key Vault, verifies the pod is still running the digest we just deployed (defending against mid-test Flux resume), probes cross-service health, then runs the service's acceptance-test Maven module against the gateway URL.

**Task:**
Create `.github/actions/integration-test/action.yml` per §5.3 contract and Appendix A.4 sketch.

**Files:**
- `.github/actions/integration-test/action.yml` (new)

**Acceptance criteria:**
- [ ] All inputs per §5.3 contract (`test_dir`, `gateway_url`, `keyvault_name`, `secret_map`, `maven_goal`, `maven_profile`, `expected_digest`, `cross_service_health`)
- [ ] Outputs `test_result` (`pass`/`fail`/`advisory`) and `test_report_url`
- [ ] Digest-verification step runs at the start, fails with clear message if pod image doesn't match `expected_digest` (§8.9, Appendix A.4)
- [ ] Cross-service health probe (when enabled) returns `advisory` instead of `fail` if any dependency is unhealthy
- [ ] Secret retrieval loop reads `secret_map` JSON, populates env vars from KV
- [ ] JUnit XML uploaded as artifact
- [ ] `nick-fields/retry@v3` wraps acceptance test invocation (max 2 attempts) (§8.6)

**Reference:** Design doc §5.3 + Appendix A.4 + §8.6 + §8.9.

**Out of scope:** Wiring into validate.yml (W5).

---

### W5: Wire new jobs into validate.yml

**Slot:** `W5` &nbsp;|&nbsp; **Label:** `enhancement` &nbsp;|&nbsp; **Blocked by:** `W1`, `W2`, `W3`, `W4`

**Context:**
Append docker-build, deploy, integration-test jobs to `template-workflows/validate.yml`. New jobs gate on the §5.5 trust boundary clause. Per D12, the same jobs do NOT go into `build.yml`.

**Task:**
Edit `.github/template-workflows/validate.yml` to add three new jobs per Appendix A.1.

The `if:` clause on `docker-build` enforces:
- Not `pull_request_target`
- Not `dependabot[bot]`
- For `pull_request`, head repo must equal base repo

Downstream jobs (`deploy`, `integration-test`) inherit gating via `needs:`.

**Files:**
- `.github/template-workflows/validate.yml`

**Acceptance criteria:**
- [ ] Three new jobs (`docker-build`, `deploy`, `integration-test`) appended after `java-build`
- [ ] `if:` clause on `docker-build` matches §5.5 trust boundary table
- [ ] `deploy` job uses per-service concurrency group `spi-stack-${{ vars.SERVICE_NAME }}` (per-service, not cluster-wide — §5.2)
- [ ] `deploy` outputs `deployed_digest`; passed into `integration-test` via `expected_digest`
- [ ] `integration-test` references `vars.ACCEPTANCE_TEST_DIR`, `vars.K8S_DEPLOYMENT_NAME`, `vars.K8S_CONTAINER_NAME` (not derived from `SERVICE_NAME`)
- [ ] `permissions:` block includes `id-token: write`, `packages: write`, `contents: read`
- [ ] `code-validation` job remains in parallel (unchanged)
- [ ] **No changes to `build.yml`**

**Reference:** Design doc §5.4–§5.5 + Appendix A.1.

**Out of scope:** Modifying build.yml. Branch-protection changes (W10).

---

### W7: Add release-version image tag to release.yml

**Slot:** `W7` &nbsp;|&nbsp; **Label:** `enhancement` &nbsp;|&nbsp; **Blocked by:** `W2` (soft — scaffold in parallel, integrate after)

**Context:**
When release-please merges a release PR and creates a tag (e.g. `v1.2.3`), the existing image (built on merge to main) needs to be re-tagged with the version. Per design, release.yml does NOT re-deploy — deploy already happened on the merge to main.

**Task:**
Update `.github/template-workflows/release.yml` to add a tag-pull-tag-push step that takes the existing `:sha-<short-sha>` image and tags it as `:<version>`. Use `docker buildx imagetools create` (or `crane`) so the manifest is re-tagged without rebuilding.

**Files:**
- `.github/template-workflows/release.yml`

**Acceptance criteria:**
- [ ] On release-please tag-create event, the existing GHCR image is re-tagged with the version
- [ ] No re-deploy or re-test triggered by tag
- [ ] If the source SHA tag doesn't exist, job fails with a clear message ("release tag created without a build behind it")

**Reference:** Design doc §5.1, §9.3 W7.

**Out of scope:** Anything related to deploy or integration-test on tag events.

---

### W8: New cluster-health-check composite action

**Slot:** `W8` &nbsp;|&nbsp; **Label:** `enhancement` &nbsp;|&nbsp; **Blocked by:** None

**Context:**
Pre-flight check used by `deploy` and optionally by a scheduled health-badge workflow. Distinguishes "cluster is down" from "your code is broken" so PR authors aren't blamed for infra outages.

**Task:**
Create `.github/actions/cluster-health-check/action.yml` performing:
- `kubectl get nodes` — all Ready
- HTTP probe to `${gateway_url}/api/partition/v1/info` (or generic health probe) — 2xx
- `kubectl get kustomizations -n flux-system` — all suspended (per §7.5 invariant)

**Files:**
- `.github/actions/cluster-health-check/action.yml` (new)

**Acceptance criteria:**
- [ ] Action takes inputs: `gateway_url`, `flux_namespace` (default `flux-system`)
- [ ] Outputs: `status` (`healthy`/`degraded`/`down`) and `summary` for logs
- [ ] Each check has a distinct error message so the failing component is unambiguous
- [ ] No hardcoded service names

**Reference:** Design doc §8.4 + §9.3 W8.

**Out of scope:** Using the action (lives in W5 wiring or a future scheduled workflow).

---

### W10: Update branch-protection ruleset for new required checks

**Slot:** `W10` &nbsp;|&nbsp; **Label:** `enhancement` &nbsp;|&nbsp; **Blocked by:** None

**Context:**
Per G2, integration-test failure must block PRs to main. Required checks are defined in `.github/rulesets/default-branch.json` and propagated to forks by the init workflow.

**Task:**
Update `.github/rulesets/default-branch.json` to add the three new required check contexts: `🐳 Docker Build`, `🚀 Deploy to spi-stack`, `🧪 Integration Tests`.

Verify the init workflow + `setup-rulesets.sh` (in `.github/local-actions/init-helpers/`) propagate the change. If the check names are hardcoded anywhere, update them in lockstep.

**Files:**
- `.github/rulesets/default-branch.json`
- (possibly) `.github/local-actions/init-helpers/setup-rulesets.sh`

**Acceptance criteria:**
- [ ] Three new required-check contexts present in `default-branch.json`
- [ ] Re-running init / setup-rulesets on a test fork applies the new rules
- [ ] PRs that fail integration-test cannot merge to main (verifiable once W5 lands and partition runs CI)

**Reference:** Design doc §9.3 W10 + §6.1.

**Out of scope:** Cascade or release-related rules.

---

### W11: GHCR retention scheduled workflow

**Slot:** `W11` &nbsp;|&nbsp; **Label:** `enhancement` &nbsp;|&nbsp; **Blocked by:** `W2` (soft)

**Context:**
Without retention, GHCR fills up with `:sha-*` tags forever. Per §8.5 policy:
- `:sha-*` — keep 30 days
- `:<branch>-snapshot` — keep last 5 per branch
- `:<version>` (semver) — keep forever
- `:pr-*` — keep last 2; delete on PR close (optional, only if PR tagging is added)

**Task:**
Create `.github/template-workflows/ghcr-retention.yml` that runs weekly (cron) and applies the retention policy via `actions/delete-package-versions@v5` (or equivalent gh api calls).

**Files:**
- `.github/template-workflows/ghcr-retention.yml` (new)

**Acceptance criteria:**
- [ ] Workflow scheduled weekly
- [ ] Applies retention rules per §8.5
- [ ] Dry-run mode toggleable via `workflow_dispatch` input
- [ ] **Never deletes `:<version>` semver tags** (regex test)
- [ ] Logs deletions with package name and tag for audit

**Reference:** Design doc §8.5 + §9.3 W11.

**Out of scope:** Per-PR tag deletion on close (would need a separate workflow on `pull_request: closed`).

---

### Create POC notes skeleton (cicd-poc-notes.md)

**Slot:** `POC` &nbsp;|&nbsp; **Label:** `documentation` &nbsp;|&nbsp; **Blocked by:** None

**Context:**
Phase 0 produces a captured-knowledge document. Phase 2 work depends on values that Phase 0 surfaces (gateway URL, KV secret names, AKS auth mode, etc.). A skeleton lets Phase 0 fill in the blanks without inventing structure.

**Task:**
Create `doc/product/cicd-poc-notes.md` with section headings + placeholders for each Phase 0 gate (0a-0f) and each step. Include an explicit "DO NOT commit secret values" warning at the top.

**Files:**
- `doc/product/cicd-poc-notes.md` (new)

**Acceptance criteria:**
- [ ] Top-of-file warning: never commit secret values; names, KV references, resource IDs only
- [ ] Section per gate (0a-0f) with a Question / Finding / Resolution structure
- [ ] Section per Phase 0 step
- [ ] Markdown headings consistent with the rest of `doc/product/`
- [ ] Linked back to the parent design doc

**Reference:** Design doc §9.1.

**Out of scope:** Filling in the actual answers (Phase 0 manual work, run by an operator with cluster access).

---

### Phase 3: Extend spi CLI with 'onboard' subcommand (cross-repo)

**Slot:** `ONBOARD` &nbsp;|&nbsp; **Label:** `enhancement` &nbsp;|&nbsp; **Blocked by:** None &nbsp;|&nbsp; **Target repo:** `danielscholl-osdu/osdu-spi-stack`

**Context:**
Per §9.4 of the design doc, onboarding a new service fork should be a single command operation. Extending the existing `spi` Python CLI is preferable to a standalone bash script (idempotency, retry logic, JSON handling already exist).

**Task:**
Implement `spi onboard --service <name> --org <org> --aks-cluster <cluster> --aks-rg <rg> --identities-rg <rg>` per §9.4.

**Acceptance criteria:**
- [ ] Operator precondition checks (az/kubectl/gh authentication + RBAC) — fail fast with remediation messages
- [ ] Verifies `Deployment/<name>` exists in `osdu`; captures `K8S_DEPLOYMENT_NAME` and `K8S_CONTAINER_NAME`
- [ ] Creates managed identity (idempotent)
- [ ] Adds federated credentials for branches (wildcard if supported, else explicit), PR, tags
- [ ] AKS Cluster User + namespace `edit` RoleBinding (form per AKS auth mode)
- [ ] Key Vault Secrets User assignment
- [ ] Flips GHCR package to public + sets retention policy
- [ ] Writes GitHub repo secrets and per-service variables (per §7.3 table)
- [ ] Updates branch-protection ruleset on the target repo
- [ ] `--dry-run` mode prints the plan without making changes
- [ ] Outputs a JSON summary on completion

**Reference:** Design doc §6.1 + §7.3 + §9.4.

**Out of scope:** Populating per-service KV secret values (separate manual step, out of band).

---

### ADR-032: Author 'CI/CD Deploy Loop via Suspended Flux'

**Slot:** `ADR-032` &nbsp;|&nbsp; **Label:** `documentation` &nbsp;|&nbsp; **Blocked by:** None

**Context:**
The design pins Flux as permanently suspended on the shared CI cluster so per-PR workflows can `kubectl set image` freely. This is a foundational deployment-model decision and deserves an ADR.

**Task:**
Author `doc/src/adr/032-cicd-deploy-loop-via-suspended-flux.md` per the existing ADR template (see `doc/src/adr/0*.md`). Content per Appendix B ADR-032 of the design doc, expanded to ADR-standard length: Context, Decision, Consequences, Alternatives Considered (Flux per-service annotations, Argo CD, Helm CI release-per-PR).

**Files:**
- `doc/src/adr/032-cicd-deploy-loop-via-suspended-flux.md` (new)

**Acceptance criteria:**
- [ ] Follows the structure of existing ADRs
- [ ] Status: Proposed
- [ ] References ADR-001 (three-branch) and ADR-015 (template-workflows) for prior context
- [ ] Renumber if 032 is already taken upstream (`Azure/osdu-spi/doc/src/adr/`)

**Reference:** Design doc Appendix B (ADR-032 draft).

**Out of scope:** Implementation work (covered by W2-W12).

---

### ADR-033: Author 'GHCR as Service Image Registry'

**Slot:** `ADR-033` &nbsp;|&nbsp; **Label:** `documentation` &nbsp;|&nbsp; **Blocked by:** None

**Context:**
Decision to use GHCR with public visibility for service images, vs. ACR or private GHCR alternatives.

**Task:**
Author `doc/src/adr/033-ghcr-as-service-image-registry.md`. Content per Appendix B ADR-033 of design doc; include the §7.4 fallback discussion (ACR + AcrPull, or private GHCR + image-pull-secret) as Alternatives Considered.

**Files:**
- `doc/src/adr/033-ghcr-as-service-image-registry.md` (new)

**Acceptance criteria:**
- [ ] Standard ADR structure
- [ ] Calls out the compliance question explicitly (public packages allowed under publishing-org policy — Phase 0 gate 0c)
- [ ] Renumber if needed

**Reference:** Design doc Appendix B + §7.4.

**Out of scope:** Implementation work.

---

### ADR-034: Author 'Federated Identity for Actions to Azure'

**Slot:** `ADR-034` &nbsp;|&nbsp; **Label:** `documentation` &nbsp;|&nbsp; **Blocked by:** None

**Context:**
Per-fork managed identity with federated credentials, replacing static `AZURE_CREDENTIALS` JSON secrets. Provides per-service blast-radius isolation.

**Task:**
Author `doc/src/adr/034-federated-identity-actions-to-azure.md`. Content per Appendix B ADR-034. Include §6.1 federated-credential subject coverage (wildcards including refs/heads + refs/tags + pull_request) in the Decision section.

**Files:**
- `doc/src/adr/034-federated-identity-actions-to-azure.md` (new)

**Acceptance criteria:**
- [ ] Standard ADR structure
- [ ] Lists subjects required (branches wildcard, PR, tags wildcard)
- [ ] Documents the ~20-step setup cost and the automation response (`spi onboard`)
- [ ] Renumber if needed

**Reference:** Design doc Appendix B + §6.

**Out of scope:** Onboarding-script implementation (separate sub-issue).

---

### ADR-035: Author 'Azure-Only Maven Profile Restriction'

**Slot:** `ADR-035` &nbsp;|&nbsp; **Label:** `documentation` &nbsp;|&nbsp; **Blocked by:** None

**Context:**
Build only `-P <service>-azure` profile in CI, skipping AWS/IBM/GC profiles.

**Task:**
Author `doc/src/adr/035-azure-only-maven-profile.md`. Content per Appendix B ADR-035.

**Files:**
- `doc/src/adr/035-azure-only-maven-profile.md` (new)

**Acceptance criteria:**
- [ ] Standard ADR structure
- [ ] Documents the trade-off: lose signal on non-Azure provider breakage
- [ ] Per-service `MAVEN_PROFILE` repo variable is the configuration knob
- [ ] Renumber if needed

**Reference:** Design doc Appendix B + §2.2 C3.

**Out of scope:** Implementation (covered by W1).

---

### ADR-036: Author 'Workflow Trust Boundaries for CI/CD'

**Slot:** `ADR-036` &nbsp;|&nbsp; **Label:** `documentation` &nbsp;|&nbsp; **Blocked by:** None

**Context:**
The new federated-identity-bearing jobs must not run on attacker-controlled code (`pull_request_target`, external-fork PRs, `dependabot[bot]`). This trust model is a load-bearing security decision and deserves an ADR.

**Task:**
Author `doc/src/adr/036-workflow-trust-boundaries.md`. Content per Appendix B ADR-036 of the design doc.

**Files:**
- `doc/src/adr/036-workflow-trust-boundaries.md` (new)

**Acceptance criteria:**
- [ ] Standard ADR structure
- [ ] Includes the full event-trust table from §5.5
- [ ] Documents external-fork PR limitation as accepted consequence
- [ ] Includes the `if:` clause that workflows must use
- [ ] Renumber if needed

**Reference:** Design doc Appendix B + §5.5.

**Out of scope:** Workflow `if:` clause implementation (W5).

---

### Create docker-build / deploy / integration-test workflow specs

**Slot:** `SPECS` &nbsp;|&nbsp; **Label:** `documentation` &nbsp;|&nbsp; **Blocked by:** None

**Context:**
The `doc/product/` directory has spec docs for each workflow (build, release, validate, cascade, etc.). The three new pipeline stages need matching specs for the Phase 4 PR back to `Azure/osdu-spi`.

**Task:**
Create three new spec docs in `doc/product/` mirroring the structure of existing `build-workflow-spec.md`:
- `docker-build-workflow-spec.md`
- `deploy-workflow-spec.md`
- `integration-test-workflow-spec.md`

Each spec documents: purpose, triggers, inputs, outputs, failure modes, dependencies on other workflows/actions, trust-boundary handling.

**Files:**
- `doc/product/docker-build-workflow-spec.md` (new)
- `doc/product/deploy-workflow-spec.md` (new)
- `doc/product/integration-test-workflow-spec.md` (new)

**Acceptance criteria:**
- [ ] Same structure and heading conventions as existing spec docs (read `build-workflow-spec.md` for the template)
- [ ] References the parent design doc for deeper detail
- [ ] Each spec includes trust-boundary information (cross-link to ADR-036)
- [ ] `architecture.md` and `workflow-strategy.md` are NOT modified

**Reference:** Design doc §5 + existing `doc/product/*-workflow-spec.md` files.

**Out of scope:** Updates to `architecture.md` or `workflow-strategy.md`.

---

## Regeneration

On a fresh fork (or to recreate the issues after deletion / transfer / mass close):

```bash
# Authenticate to the target repo's org
gh auth status

# Run the regeneration script (reads slot bodies from this doc's structure)
.github/scripts/regenerate-cicd-sub-issues.sh
```

The script:

1. Reads each `### …` section in the [Sub-issue specifications](#sub-issue-specifications) section
2. Creates a GitHub issue for each, with the correct label
3. Captures the new issue numbers
4. Outputs a fresh **Live mapping** table you can paste back into this doc + the epic body

The script does **not** modify the parent epic — that's a manual step after you confirm the new numbers (the epic body has rich content beyond the checklist).

---

## Phase 0 — out of agent scope

The Phase 0 prerequisite gates and manual proof-of-concept are not in the sub-issue list because they require human operation against the live cluster + Azure org-policy conversations. See the design doc §9.1 for the gate definitions. Phase 0 findings are recorded in `cicd-poc-notes.md` (skeleton created by the `POC` sub-issue).

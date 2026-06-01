# ADR-036: Workflow Trust Boundaries for CI/CD

## Context

- New CI/CD jobs (`docker-push`, `deploy`, `integration-test`) hold credentials with real blast radius:
  - `docker-push` uses `packages: write` on GHCR.
  - `deploy` / `integration-test` use Azure federated identity + AKS / Key Vault access.
- GitHub event contexts are not equally trusted. Some can execute attacker-controlled PR code.
- Running credential-bearing jobs in untrusted contexts risks credential exfiltration and cluster compromise.
- The validate-only `docker-build` job is out of scope for this trust boundary because it runs with `permissions: contents: read` only (no GHCR write, no Azure login).

## Decision

- Enforce a single trust-boundary model for credential-bearing jobs.
- Use the following event-trust matrix as authoritative:

| Event | Code source | Secret access | Deploy stages run? |
|---|---|---|---|
| `push` to `main` / `fork_integration` / `fork_upstream` | Repo HEAD (post-merge) | Yes | **Yes** |
| `pull_request` from internal branch (head repo == base repo) | PR HEAD | Yes | **Yes** |
| `pull_request` from external fork | PR HEAD | No (GH default) | No — would fail at `azure/login` anyway, but explicitly skipped to avoid noise |
| `pull_request_target` (base-repo context) | PR HEAD (checked out via explicit ref) | Yes | **No** — too dangerous; would let a PR exfiltrate the federated identity by running arbitrary code in a workflow that has secret access |
| `dependabot[bot]` PR | PR HEAD | Limited (`secrets.DEPENDABOT_SECRETS`) | No — dependabot-validation.yml is the dependency-update path |
| `workflow_dispatch` | Repo HEAD at chosen ref | Yes | Yes (manual gate is the operator) |
| Tag push (release-please) | Tagged commit (already in `main`) | Yes | **No** — tag pushes go through `release.yml`, NOT `validate.yml`. `release.yml` only re-tags the existing image with the semver; it does not re-deploy, since deploy already ran on the merge-to-main that produced the tagged commit. The federated credential still needs `refs/tags/v*` because `release.yml` authenticates to GHCR for the re-tag. |
| Cascade workflow push to `fork_integration` | Cascade-resolved tree | Yes | Yes |

- Credential-bearing jobs must use this gating clause:

```yaml
if: |
  (
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

## Consequences

### Positive

- Cluster credentials are never exposed to attacker-controlled PR execution contexts.
- Trust assumptions are explicit and consistent across service forks.
- Cascade pushes keep deploy/test signal for upstream integration risk.

### Negative

- External-fork PRs do not receive deploy/integration-test signal.
- Maintainers must run trusted validation before merging external contributions.
- The `if:` clause is easy to weaken accidentally if copied incorrectly.

### Neutral

- `docker-build` continues to run broadly because it does not carry sensitive credentials.
- Dependabot keeps its dedicated validation path outside cluster-credential workflows.

## Alternatives Considered

- Allow `pull_request_target` for deploy/test: rejected due to credential-exfiltration risk.
- Allow external-fork PR deploy/test: rejected due to untrusted code boundary.
- Move trust checks to reviewer convention only: rejected; policy must be enforced in workflow `if:` guards.

---

[← ADR-031](031-template-sync-duplicate-prevention.md) | :material-arrow-up: [Catalog](index.md)

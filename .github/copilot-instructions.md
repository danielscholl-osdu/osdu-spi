# GitHub Copilot Instructions

## Project Overview

You are working with the Fork Management Template, an automated solution for managing long-lived forks of upstream repositories. This template uses GitHub Actions to automate synchronization, conflict resolution, and release management for OSDU (Open Subsurface Data Universe) projects.

## Key Architecture

### Branch Strategy
- `main` - Production branch with strict protection rules
- `fork_upstream` - Automatically tracks upstream repository changes
- `fork_integration` - Staging branch for conflict resolution before merging to main

### Workflow layout
- `.github/workflows/` contains template-development workflows that run in this template repository, such as initialization, template CI, docs, and development release automation.
- `.github/template-workflows/` contains fork-production workflows that are copied into generated service forks during initialization/template sync. Production fork changes to `sync.yml`, `build.yml`, `validate.yml`, `release.yml`, `cascade.yml`, or similar workflows belong here.
- `.github/actions/` contains reusable composite actions consumed by template workflows.

### Core fork-production workflows
1. **sync.yml** - Automated upstream synchronization with AI-enhanced PR descriptions
2. **build.yml** - Build and test automation for Java/Maven projects
3. **validate.yml** - PR validation, commit message checks, and conflict detection
4. **release.yml** - Automated semantic versioning with Release Please

## Development Guidelines

### Commit Messages
Always use conventional commits format:
```
feat: add new feature
fix: correct bug in sync workflow
chore: update dependencies
docs: improve README documentation
feat!: breaking change to API
```

### Branch Naming
Use the pattern: `agent/<issue-number>-<description>`
Example: `agent/123-fix-sync-conflict`

### Pull Requests
- Create PRs using GitHub CLI: `gh pr create`
- Include clear descriptions of changes
- Reference related issues
- Ensure all CI checks pass before merging

### Testing
- Write behavior-driven tests, not implementation tests
- For Java projects: use JUnit 5 and Mockito
- Aim for 80%+ test coverage
- Run tests locally before pushing: `mvn test`

## Common Tasks

### Adding New Workflow Features
1. For fork-production behavior, edit or add files under `.github/template-workflows/`, not `.github/workflows/`.
2. For template-repository-only automation, use `.github/workflows/`.
3. Put reusable workflow logic in composite actions under `.github/actions/` when it is shared or complex.
4. Follow existing patterns for permissions, pinned actions, shell style, and error handling.
5. Update documentation in `doc/` and add an ADR if making architectural changes.

### Modifying Sync Behavior
1. Edit `.github/template-workflows/sync.yml`
2. Test with `workflow_dispatch` before relying on schedule
3. Consider impact on fork_integration branch
4. Update conflict resolution logic if needed

### Epic #1 CI/CD changes
The CI/CD epic extends fork production validation from:

```text
Unit Test -> Docker Build -> Deploy -> Integration Test
```

Apply these rules when working on Epic #1 sub-issues:

1. Implement only the assigned GitHub issue/slot. Read that slot in `doc/product/cicd-implementation-plan.md` plus the referenced sections in `doc/product/cicd-build-deploy-test-design.md`; do not implement adjacent slots.
2. New Docker Build, Deploy, and Integration Test jobs live in `.github/template-workflows/validate.yml` only. Do not add deploy or integration-test behavior to `.github/template-workflows/build.yml`.
3. Preserve the credential boundary: build-lane work runs with `GITHUB_TOKEN`; deploy-lane work is the only lane that may acquire Azure federated identity.
4. Never run cluster-credential-bearing jobs for external-fork PRs, `pull_request_target`, or `dependabot[bot]`. Use the trust-boundary design in ADR-036/design section 5.5 when implementing deploy-lane workflow gates.
5. Treat `.github/template-workflows/validate.yml`, branch-protection rulesets, ADR indexes/lists, and instruction files as hot files. Avoid unrelated edits and expect orchestration to serialize work touching them.
6. Third-party actions must be pinned to a full commit SHA with a version comment, matching existing workflow convention.
7. Do not log secret values. Mask any value sourced from `secrets.*` or Key Vault; logging variable names, resource IDs, and secret names is acceptable.
8. Required inputs should fail loudly when missing. Do not guess service names, deployment names, Maven profiles, or Azure resource identifiers.
9. **You cannot exercise this pipeline in this repository.** This is the engineering-system *template* repo: it has no service code (`pom.xml`, `Dockerfile`, provider modules), and `validate.yml` path-ignores `.github/template-workflows/**` and `.github/actions/**`, so editing those files triggers **no** functional CI here (CodeQL is the only required check). A green PR here means *the YAML parses and the logic reads correctly* — it does **not** mean the pipeline ran. These workflows execute only after template-sync propagates them to a service fork (e.g. `danielscholl-osdu/partition`). Every PR that touches `.github/template-workflows/**` or `.github/actions/**` must include a `## Validation — what must be checked on partition` section listing the runtime behavior the orchestrator must confirm on the fork; deploy-lane PRs must also enumerate every cluster/auth assumption (RoleBinding subject form, `K8S_DEPLOYMENT_NAME`/`K8S_CONTAINER_NAME`, gateway URL, federated-identity subject claim).

### Where CI behavior is validated (build here, validate on the fork)

The CI/CD workflows you edit under `.github/template-workflows/` and the composite actions under `.github/actions/` **do not run in this repo** — `validate.yml` path-ignores those directories on every trigger, and there is no Maven/Docker project here to build. They run only after `sync.yml` propagates them to an initialized service fork. Treat "PR is green in `osdu-spi`" as "syntactically valid," never as "verified." For any author-only slot, the runtime contract (docker build/push, `kubectl set image`, integration tests against the gateway) is confirmed by an orchestrator-triggered run on `partition` — use W13's `force_full_pipeline` `workflow_dispatch` once it exists, since template-sync changes are path-ignored. Record that run's URL in the PR's validation section before requesting merge.

### Java/Maven Development
```bash
# Build project
mvn clean install

# Run tests with coverage
mvn clean test org.jacoco:jacoco-maven-plugin:0.8.11:report

# Run specific test
mvn test -Dtest=TestClassName#testMethodName
```

### Working with Issues
When creating issues, use appropriate labels:
- **Type**: `bug`, `enhancement`, `documentation`
- **Priority**: `high-priority`, `medium-priority`, `low-priority`
- **Component**: `configuration`, `dependencies`, `workflow`
- **AI**: Add `copilot` label for AI-suitable tasks

## Workflow Patterns

### Standard Workflow Structure
```yaml
name: Workflow Name
on:
  schedule:
    - cron: '0 0 * * 0'  # Weekly
  workflow_dispatch:      # Manual trigger

jobs:
  job-name:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
      
    steps:
      - uses: actions/checkout@v5
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          
      - name: Your Logic Here
        run: |
          # Implementation
```

### Error Handling
- Always include error handling in workflows
- Use `if: failure()` for cleanup steps
- Report status to PRs when applicable
- Create issues for persistent failures

## Security Considerations

- Never commit sensitive data or credentials
- Use GitHub Secrets for tokens and API keys
- Trivy scanner removes sensitive patterns automatically
- Follow branch protection rules strictly

## AI Development Tips

### For GitHub Copilot
- This project is AI-optimized with clear patterns
- Look for `copilot` labeled issues for AI-suitable tasks
- Follow existing code patterns for consistency
- Reference ADRs for architectural decisions

### Documentation Standards
- Document new features in appropriate `doc/` files
- Create ADRs for significant architecture changes
- Use clear, descriptive variable and function names

## Quick Reference

### Key Files
- `doc/src/adr/` - Architecture decisions
- `.github/template-workflows/` - Fork-production workflows copied into service forks
- `.github/workflows/` - Template-development workflows for this repository
- `.github/actions/` - Reusable composite actions
- `doc/product/prd.md` - Product requirements
- `doc/product/cicd-implementation-plan.md` - CI/CD epic work breakdown and agent slot catalog
- `doc/product/cicd-build-deploy-test-design.md` - CI/CD epic design

### Environment Variables
- `UPSTREAM_OWNER` - Upstream repository owner
- `UPSTREAM_REPO` - Upstream repository name
- `GITHUB_TOKEN` - Authentication token
- `OPENAI_API_KEY` - Optional for AI PR descriptions

### Useful Commands
```bash
# View workflow runs
gh workflow view

# Create PR
gh pr create --title "feat: add feature" --body "Description"

# Check PR status
gh pr status

# View issues
gh issue list --label copilot
```

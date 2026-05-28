<!-- Epic #1 CI/CD work: keep these sections. For unrelated PRs, the headings are still a reasonable default. -->

## What

<!-- The functional change in 1-3 sentences. Name the slot and the upstream lane. -->

- **Slot / issue:** <!-- e.g. W2 / #3 -->
- **Upstream lane:** <!-- Build PR | Deploy PR | n/a -->

## Validation — what must be checked on partition

<!-- REQUIRED for any change under .github/template-workflows/** or .github/actions/**.
     A green check in THIS repo only means the YAML parses; it does NOT run the pipeline
     (validate.yml path-ignores those dirs; there is no Maven/Docker project here).
     The runtime contract is confirmed by an orchestrator-triggered run on the partition fork
     (use W13's force_full_pipeline workflow_dispatch once it exists).
     Deploy-lane: enumerate every cluster/auth assumption — RoleBinding subject form,
     K8S_DEPLOYMENT_NAME / K8S_CONTAINER_NAME, gateway URL, federated-identity subject claim. -->

- **Partition validation run:** <!-- URL, or "N/A — docs/ADR/spec only" -->

## Do not merge until

<!-- e.g. "W5a green on partition" / "Phase 0 gate 0e closed + PoC recorded in cicd-poc-notes.md"
     / "OIDC step 4a green for branch+tag subjects". Delete this section if there is no hold. -->

## Hot files touched

<!-- Tick any that apply — orchestration serializes work on these. -->

- [ ] `.github/template-workflows/validate.yml`
- [ ] branch-protection rulesets (`.github/rulesets/**`)
- [ ] ADR index/list (`doc/src/adr/index.md`, `doc/src/adr/list.md`)
- [ ] instruction files (`.github/copilot-instructions.md`)
- [ ] none of the above

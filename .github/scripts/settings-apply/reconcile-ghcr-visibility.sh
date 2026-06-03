#!/usr/bin/env bash
#
# Reconcile a GHCR container package to public (ADR-033) so the shared spi-stack
# AKS cluster can pull it without an imagePullSecret. Same logic the docker-build
# action runs post-push (.github/actions/docker-build/set-package-visibility.sh),
# invoked here on the settings-apply cadence for existing forks.
#
# Idempotent and SOFT-FAIL: already-public, missing package, or a 4xx all log and
# exit 0 — reconciliation never hard-blocks.
#
# Arguments:
#   $1            org/owner (e.g. danielscholl-osdu)
#   $2            package name == image name (e.g. partition)
#   --dry-run     Report the intended action without mutating
#
# Environment:
#   GH_TOKEN | GITHUB_TOKEN - token with package admin scope

set -uo pipefail

DRY_RUN=false
ARGS=()
for a in "$@"; do
  if [[ "$a" == "--dry-run" ]]; then DRY_RUN=true; else ARGS+=("$a"); fi
done
if [[ ${#ARGS[@]} -ne 2 ]]; then
  echo "Usage: $0 <org> <package_name> [--dry-run]"; exit 1
fi

ORG="$(printf '%s' "${ARGS[0]}" | tr '[:upper:]' '[:lower:]')"
PACKAGE_NAME="$(printf '%s' "${ARGS[1]}" | tr '[:upper:]' '[:lower:]')"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "⚠️  No token set; skipping visibility reconcile."; exit 0
fi

# Org packages live under /orgs/<org>/...; a user's own packages under /user/... (read-write).
OWNER_TYPE="$(gh api "/users/${ORG}" --jq '.type' 2>/dev/null || echo "")"
if [[ "$OWNER_TYPE" == "Organization" ]]; then BASE="orgs/${ORG}"; else BASE="user"; fi

CURRENT="$(gh api "${BASE}/packages/container/${PACKAGE_NAME}" --jq '.visibility' 2>/dev/null || echo "")"
if [[ -z "$CURRENT" ]]; then
  echo "ℹ Package ${ORG}/${PACKAGE_NAME} not found or not readable; nothing to reconcile."; exit 0
fi
if [[ "$CURRENT" == "public" ]]; then
  echo "✓ Package ${ORG}/${PACKAGE_NAME} already public."; exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY-RUN would set ${ORG}/${PACKAGE_NAME} visibility ${CURRENT} -> public"; exit 0
fi

if gh api -X PATCH "${BASE}/packages/container/${PACKAGE_NAME}/visibility" -f visibility=public >/dev/null 2>&1; then
  echo "✓ Package ${ORG}/${PACKAGE_NAME} visibility set to public."
else
  echo "⚠️  Could not set ${ORG}/${PACKAGE_NAME} to public; cluster pulls may fail with ErrImagePull until fixed."
fi
exit 0

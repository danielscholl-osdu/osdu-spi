#!/usr/bin/env bash
#
# Set Package Visibility Script
#
# Flips a freshly-pushed GHCR container package to public so the shared
# spi-stack AKS cluster can pull it without an imagePullSecret (ADR-033).
#
# Idempotent and SOFT-FAIL by design: an already-public package, a missing
# package, or a permission error (4xx) logs and exits 0 — it never fails the
# build. init.yml (fresh forks) and settings-apply.yml (existing forks)
# reconcile visibility on their own cadence.
#
# Arguments:
#   $1 - org/owner (e.g. danielscholl-osdu)
#   $2 - package name == image name (e.g. partition)
#
# Environment:
#   GITHUB_TOKEN - token with package admin scope (passed by the action's push path)
#
# Local usage:
#   GITHUB_TOKEN=*** ./set-package-visibility.sh danielscholl-osdu partition

set -uo pipefail

if [[ $# -ne 2 ]]; then
  echo "Error: Missing required arguments"
  echo "Usage: $0 <org> <package_name>"
  exit 1
fi

# GHCR owner/package names are lowercase; normalize before hitting the API
ORG="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
PACKAGE_NAME="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "⚠️  GITHUB_TOKEN not set; skipping visibility flip. Run 'gh workflow run settings-apply.yml' to reconcile."
  exit 0
fi

# Discriminate org-owned vs user-owned to choose the correct packages namespace.
# Org packages live under /orgs/<org>/...; a user's own packages are written via the
# authenticated-user namespace /user/... (NOT /users/<user>/..., which is read-only).
OWNER_TYPE="$(gh api "/users/${ORG}" --jq '.type' 2>/dev/null || echo "")"
if [[ "$OWNER_TYPE" == "Organization" ]]; then
  BASE="orgs/${ORG}"
else
  BASE="user"
fi

# Read current visibility; an empty result means the package is missing or unreadable (skip silently)
CURRENT="$(gh api "${BASE}/packages/container/${PACKAGE_NAME}" --jq '.visibility' 2>/dev/null || echo "")"
if [[ -z "$CURRENT" ]]; then
  echo "ℹ Package ${ORG}/${PACKAGE_NAME} not found or not readable; skipping visibility flip."
  exit 0
fi

if [[ "$CURRENT" == "public" ]]; then
  echo "✓ Package ${ORG}/${PACKAGE_NAME} already public, no change."
  exit 0
fi

# Attempt the flip; soft-fail on any error so the build is never blocked
RESPONSE="$(gh api -X PATCH "${BASE}/packages/container/${PACKAGE_NAME}/visibility" -f visibility=public 2>&1)"
RC=$?
if [[ $RC -eq 0 ]]; then
  echo "✓ Package ${ORG}/${PACKAGE_NAME} visibility set to public."
else
  echo "⚠️  Could not set ${ORG}/${PACKAGE_NAME} to public (exit ${RC})."
  echo "    Response: ${RESPONSE}"
  echo "    Cluster pulls will fail with ErrImagePull until visibility is fixed."
  echo "    Remediate with: gh workflow run settings-apply.yml"
fi

exit 0

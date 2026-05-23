#!/usr/bin/env bash
# Regenerate the 17 CI/CD sub-issues from doc/product/cicd-implementation-plan.md
#
# Usage:
#   .github/scripts/regenerate-cicd-sub-issues.sh \
#       [--repo OWNER/REPO] \
#       [--parent EPIC_ISSUE_NUMBER] \
#       [--no-link] \
#       [--dry-run]
#
# Defaults to the current repo (per `gh repo view`). On a fresh fork, override
# with --repo. Existing issues with matching titles are NOT detected; running
# this twice will create duplicates. Intended for one-shot bootstrap.
#
# If --parent is given (default: 1), each created issue is also linked to that
# parent issue via GitHub's native sub-issues feature (so the parent's sidebar
# shows the progress bar + auto-checks completion). Pass --no-link to skip.
#
# Source of truth for issue bodies: doc/product/cicd-implementation-plan.md
# This script extracts each `### <Title>` section from "## Sub-issue
# specifications" and creates one issue per section.

set -euo pipefail

# ---------- argument parsing -----------------------------------------------

REPO=""
PARENT=1
LINK_AS_SUBISSUES=true
DRY_RUN=false
PLAN_DOC="doc/product/cicd-implementation-plan.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --parent)  PARENT="$2"; shift 2 ;;
    --no-link) LINK_AS_SUBISSUES=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --plan)    PLAN_DOC="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || {
    echo "Error: could not determine repo. Pass --repo OWNER/REPO." >&2
    exit 2
  }
fi

if [[ ! -f "$PLAN_DOC" ]]; then
  echo "Error: plan doc not found at '$PLAN_DOC'." >&2
  echo "Run this script from the repo root, or pass --plan PATH." >&2
  exit 2
fi

echo "Repo:    $REPO"
echo "Plan:    $PLAN_DOC"
echo "Parent:  #$PARENT (link as sub-issues: $LINK_AS_SUBISSUES)"
echo "Dry-run: $DRY_RUN"
echo

# Resolve parent GraphQL node ID once if we'll be linking
PARENT_NODE_ID=""
if [[ "$LINK_AS_SUBISSUES" == "true" && "$DRY_RUN" != "true" ]]; then
  IFS='/' read -r OWNER NAME <<< "$REPO"
  PARENT_NODE_ID=$(gh api graphql -f query="
    query {
      repository(owner: \"$OWNER\", name: \"$NAME\") {
        issue(number: $PARENT) { id }
      }
    }" --jq '.data.repository.issue.id' 2>/dev/null) || true
  if [[ -z "$PARENT_NODE_ID" || "$PARENT_NODE_ID" == "null" ]]; then
    echo "Warning: could not resolve parent issue #$PARENT in $REPO. Sub-issue linking will be skipped." >&2
    LINK_AS_SUBISSUES=false
  fi
fi

# ---------- parser ---------------------------------------------------------
# Each sub-issue section in the plan doc looks like:
#
#   ### <Title>
#
#   **Slot:** `XXX` &nbsp;|&nbsp; **Label:** `LABEL` &nbsp;|&nbsp; …
#
#   <body…>
#
#   ---
#
# We extract:
#   - title: the H3 line
#   - label: from the **Label:** field
#   - body:  everything from the H3 to the next `---` separator (exclusive),
#            with the H3 line stripped (since it becomes the issue title)

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Extract the range from "## Sub-issue specifications" to "## Regeneration"
awk '
  /^## Sub-issue specifications/ { in_section = 1; next }
  /^## Regeneration/             { in_section = 0 }
  in_section                     { print }
' "$PLAN_DOC" > "$WORKDIR/sections.md"

# Split on the `---` separator into per-issue files
awk -v dir="$WORKDIR" '
  BEGIN { n = 0; out = dir "/issue-" n ".md" }
  /^---[[:space:]]*$/ {
    close(out)
    n++
    out = dir "/issue-" n ".md"
    next
  }
  { print > out }
' "$WORKDIR/sections.md"

# ---------- issue creator --------------------------------------------------

declare -a MAPPING=()

create_one() {
  local file="$1"
  local title label body_file slot

  # Title is the first non-blank line, stripped of "### "
  title=$(awk '/^### / { sub(/^### /, ""); print; exit }' "$file")
  [[ -z "$title" ]] && return  # skip files without a title (e.g. the lead-in)

  # Slot and label live on the same metadata line; extract content between backticks
  # after the marker. grep -o gives us the whole `**Marker:** \`value\``;
  # sed peels off everything but the value.
  slot=$(grep -o '\*\*Slot:\*\* `[^`]*`' "$file" | head -1 | sed -E 's/.*`([^`]*)`/\1/')
  label=$(grep -o '\*\*Label:\*\* `[^`]*`' "$file" | head -1 | sed -E 's/.*`([^`]*)`/\1/')
  [[ -z "$label" ]] && label="enhancement"
  [[ -z "$slot" ]]  && slot="??"

  # Body: everything after the H3 line, with leading blank line trimmed
  body_file="$WORKDIR/body-$(basename "$file")"
  awk '
    /^### / && !seen { seen = 1; next }
    seen { print }
  ' "$file" | awk 'NR>1 || NF>0' > "$body_file"

  echo "Creating: [$slot] $title (label=$label)"

  if [[ "$DRY_RUN" == "true" ]]; then
    MAPPING+=("$slot|DRY|$title")
    return
  fi

  local url num
  url=$(gh issue create --repo "$REPO" --title "$title" --label "$label" --body-file "$body_file")
  num=$(basename "$url")
  MAPPING+=("$slot|$num|$title")
  echo "  -> $url"

  # Link as a native sub-issue of the parent epic
  if [[ "$LINK_AS_SUBISSUES" == "true" ]]; then
    local child_node_id
    child_node_id=$(gh api graphql -f query="
      query {
        repository(owner: \"$OWNER\", name: \"$NAME\") {
          issue(number: $num) { id }
        }
      }" --jq '.data.repository.issue.id' 2>/dev/null) || true
    if [[ -n "$child_node_id" && "$child_node_id" != "null" ]]; then
      gh api graphql -f query="
        mutation {
          addSubIssue(input: {
            issueId: \"$PARENT_NODE_ID\"
            subIssueId: \"$child_node_id\"
          }) { subIssue { number } }
        }" --jq '.data.addSubIssue.subIssue.number' > /dev/null 2>&1 \
        && echo "     linked as sub-issue of #$PARENT" \
        || echo "     warn: sub-issue linking failed for #$num"
    fi
  fi
}

# ---------- main loop ------------------------------------------------------

shopt -s nullglob
for f in "$WORKDIR"/issue-*.md; do
  create_one "$f"
done

# ---------- output mapping --------------------------------------------------

echo
echo "==== Live mapping ===="
echo "| Slot | Issue | Title |"
echo "|------|-------|-------|"
for row in "${MAPPING[@]}"; do
  IFS='|' read -r slot num title <<< "$row"
  if [[ "$num" == "DRY" ]]; then
    echo "| \`$slot\` | (dry-run) | $title |"
  else
    echo "| \`$slot\` | [#$num](https://github.com/$REPO/issues/$num) | $title |"
  fi
done

echo
echo "Done. ${#MAPPING[@]} issues processed."
echo "Next steps:"
echo "  1. Paste the Live mapping table into $PLAN_DOC under '## Live mapping'"
echo "  2. Update the parent epic body's sub-issue checklist with the new numbers"

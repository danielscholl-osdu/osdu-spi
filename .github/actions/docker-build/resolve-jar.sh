#!/usr/bin/env bash
#
# Resolve the service Spring Boot JAR to COPY into the image (ADR-037).
#
# The caller passes REQUESTED_JAR — the conventional path
# provider/<service>-azure/target/*-spring-boot.jar (or a SERVICE_TARGET_JAR override).
# Most forks match it directly. A fork whose Azure module name deviates from the repo
# name (e.g. entitlements -> entitlements-v2-azure) matches nothing; rather than fail the
# build — and, post-W10, the required check — we discover the Azure Spring Boot JAR so a
# fresh fork builds with no manual variable and no first failure. SERVICE_TARGET_JAR is
# needed only to disambiguate a service that builds more than one Azure Spring Boot JAR.
#
# Environment:
#   REQUESTED_JAR  conventional path or override glob, relative to the build context
#   IMAGE_NAME     service slug, used to disambiguate when multiple modules match
#   GITHUB_OUTPUT  receives jar_file=<resolved path>

set -euo pipefail
shopt -s nullglob

REQUESTED_JAR="${REQUESTED_JAR:-}"
IMAGE_NAME="${IMAGE_NAME:-}"

resolved=""

# 1. Honour the requested path when it resolves (common <name>-azure case + explicit override).
# shellcheck disable=SC2206  # deliberate: glob-expand the path/override into matches
requested_matches=( $REQUESTED_JAR )
if [[ ${#requested_matches[@]} -ge 1 ]]; then
  resolved="${requested_matches[0]}"
  if [[ ${#requested_matches[@]} -gt 1 ]]; then
    echo "::warning::'$REQUESTED_JAR' matched ${#requested_matches[@]} files; using $resolved"
  fi
else
  # 2. Deviant module path: discover the Azure Spring Boot JAR the build produced.
  discovered=( provider/*-azure/target/*-spring-boot.jar )
  if [[ ${#discovered[@]} -eq 1 ]]; then
    resolved="${discovered[0]}"
    echo "'$REQUESTED_JAR' matched no file; discovered Azure JAR: $resolved"
  elif [[ ${#discovered[@]} -gt 1 ]]; then
    # 3. Tiebreak on the service slug; otherwise fail loud (never a cryptic COPY error).
    preferred=()
    for d in "${discovered[@]}"; do
      [[ "$d" == provider/*"${IMAGE_NAME}"*-azure/* ]] && preferred+=("$d")
    done
    if [[ ${#preferred[@]} -eq 1 ]]; then
      resolved="${preferred[0]}"
      echo "Disambiguated ${#discovered[@]} Azure JARs by service name '${IMAGE_NAME}': $resolved"
    else
      echo "::error::Found ${#discovered[@]} Azure Spring Boot JARs and could not disambiguate (${discovered[*]}). Set the SERVICE_TARGET_JAR repository variable to the correct path."
      exit 1
    fi
  else
    echo "::error::No Spring Boot JAR matched '$REQUESTED_JAR' or provider/*-azure/target/*-spring-boot.jar. Confirm the java-build artifact downloaded, or set SERVICE_TARGET_JAR."
    exit 1
  fi
fi

echo "jar_file=$resolved" >> "$GITHUB_OUTPUT"
echo "Using JAR: $resolved"

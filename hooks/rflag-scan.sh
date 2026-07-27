#!/bin/bash
# AgentGuard: R-flag (risk-flag) scan — pattern-matches the staged diff.
# Invocation: rflag-scan.sh
# Output: on a match, lists the reasons to stdout and exits 1. No match -> exit 0.
# This file is copied self-contained into each repo's .githooks/ by install.sh
# (not a reference back to a central kit — it still works if the repo is cloned
# somewhere the original AgentGuard checkout no longer exists).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

default_rules="$hook_dir/rflag-rules-default.txt"
custom_rules="$repo_root/.forge/rflag-rules.txt"

rule_files=()
[ -f "$default_rules" ] && rule_files+=("$default_rules")
[ -f "$custom_rules" ] && rule_files+=("$custom_rules")

staged_files=$(git diff --cached --name-only || true)
[ -z "$staged_files" ] && exit 0

staged_added_lines=$(git diff --cached -- . 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+' || true)

matched=()

for rf in "${rule_files[@]}"; do
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
      PATH:*)
        pattern="${line#PATH:}"
        hit=$(echo "$staged_files" | grep -iE "$pattern" || true)
        [ -n "$hit" ] && matched+=("PATH[$pattern] -> $(echo "$hit" | tr '\n' ' ')")
        ;;
      CONTENT:*)
        pattern="${line#CONTENT:}"
        hit=$(echo "$staged_added_lines" | grep -iE "$pattern" || true)
        [ -n "$hit" ] && matched+=("CONTENT[$pattern]")
        ;;
    esac
  done < "$rf"
done

if [ "${#matched[@]}" -gt 0 ]; then
  echo "R-flag detected:"
  printf '  - %s\n' "${matched[@]}"
  exit 1
fi

exit 0

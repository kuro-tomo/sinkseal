#!/bin/bash
# SinkSeal version: 0.1.0
# SinkSeal: R-flag (risk-flag) scan — pattern-matches the staged diff.
# Invocation: rflag-scan.sh
# Output: on a match, lists the reasons to stdout and exits 1. No match -> exit 0.
# This file is copied self-contained into each repo's .githooks/ by install.sh
# (not a reference back to a central kit — it still works if the repo is cloned
# somewhere the original SinkSeal checkout no longer exists).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

default_rules="$hook_dir/rflag-rules-default.txt"
custom_rules="$repo_root/.forge/rflag-rules.txt"

rule_files=()
[ -f "$default_rules" ] && rule_files+=("$default_rules")
[ -f "$custom_rules" ] && rule_files+=("$custom_rules")

# .githooks/ is where install.sh copies this very toolkit's own hooks and
# pattern tables into the adopting repo. Without excluding it, a rule like
# "CONTENT:set-cookie" matches its own definition line the moment .githooks/
# is first committed -- every single adopter hits an R-flag on their very
# first commit, on pattern-table text that isn't actually risky code.
# .forge/ (the adopter's own rule/sink additions) is deliberately NOT
# excluded here -- a change there is exactly the kind of thing worth
# flagging for acknowledgment.
#
# The file list is read with -z (NUL-delimited) so names arrive raw. Without -z,
# git C-quotes any non-ASCII name into octal escapes ("auth/\346\227..." -- a
# leading double quote plus backslash-digits), so an anchored path rule such as
# (^|/)auth never matches and the file silently slips through with no flag.
# If git itself fails, stop with exit 2 ("could not inspect") rather than
# treating the empty list as "nothing flagged" -- being unable to inspect is not
# a pass.
gr=0
staged_files=$(git diff --cached --name-only -z -- . ':(exclude).githooks/**' | tr '\0' '\n'; exit "${PIPESTATUS[0]}") || gr=$?
if [ "$gr" -ne 0 ]; then
  echo "R-flag scan: could not read the staged file list from git (exit=${gr}). Unable to inspect is not a pass." >&2
  exit 2
fi
[ -z "$staged_files" ] && exit 0

staged_added_lines=$(git diff --cached -- . ':(exclude).githooks/**' 2>/dev/null | grep -E '^\+' | grep -vE '^\+\+\+' || true)

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

#!/bin/bash
# SinkSeal version: 0.1.1
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
# File names are read NUL-delimited (-z), as raw bytes. Without -z, git's default
# (core.quotepath=true) wraps a non-ASCII name in double quotes with octal
# escapes ("auth/\344\273\225.py", with a leading '"'), so an anchored PATH rule
# such as (^|/)auth silently stopped matching it. If git itself fails, that is
# exit 2 (the scan could not run), never "no flag".
gr=0
staged_files=$(git diff --cached --name-only -z -- . ':(exclude).githooks/**' | tr '\0' '\n'; exit "${PIPESTATUS[0]}") || gr=$?
if [ "$gr" -ne 0 ]; then
  echo "R-flag scan: could not list the staged files from git (exit=${gr}). A scan that cannot run is not a pass." >&2
  exit 2
fi
[ -z "$staged_files" ] && exit 0

# A failure to fetch the diff is "could not run", not "no added lines".
if ! staged_diff=$(git diff --cached -- . ':(exclude).githooks/**'); then
  echo "R-flag scan: could not fetch the staged diff from git. A scan that cannot run is not a pass." >&2
  exit 2
fi
staged_added_lines=$(printf '%s\n' "$staged_diff" | grep -E '^\+' | grep -vE '^\+\+\+' || true)

matched=()

for rf in "${rule_files[@]}"; do
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
      PATH:*)
        pattern="${line#PATH:}"
        # grep: 0 = match, 1 = no match, 2 or more = error (e.g. an invalid regex in the rule).
        # The old `|| true` hid errors, so a broken rule never fired and the scan still passed.
        gr=0; hit=$(echo "$staged_files" | grep -iE "$pattern") || gr=$?
        if [ "$gr" -ge 2 ]; then
          echo "R-flag scan: PATH rule is invalid and cannot be scanned: '${line}' in ${rf}. A scan that cannot run is not a pass." >&2
          exit 2
        fi
        [ -n "$hit" ] && matched+=("PATH[$pattern] -> $(echo "$hit" | tr '\n' ' ')")
        ;;
      CONTENT:*)
        pattern="${line#CONTENT:}"
        gr=0; hit=$(echo "$staged_added_lines" | grep -iE "$pattern") || gr=$?
        if [ "$gr" -ge 2 ]; then
          echo "R-flag scan: CONTENT rule is invalid and cannot be scanned: '${line}' in ${rf}. A scan that cannot run is not a pass." >&2
          exit 2
        fi
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

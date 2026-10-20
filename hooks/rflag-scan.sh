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

# Installed repos keep the default table directly under .githooks/; the SinkSeal checkout
# keeps it under ../lib/ (same lookup as sink-scan.sh).
default_rules="$hook_dir/rflag-rules-default.txt"
[ -f "$default_rules" ] || default_rules="$hook_dir/../lib/rflag-rules-default.txt"
custom_rules="$repo_root/.forge/rflag-rules.txt"

# A scan with no rules table reads every change as "nothing flagged". On bash 3.2 (macOS) the
# empty rule list even aborts under `set -u` with exit 1, which pre-commit would read as a
# trailer-clearable R-flag. Unable to inspect is not a pass: stop with exit 2.
if [ ! -f "$default_rules" ]; then
  echo "R-flag scan: **cannot run** -- the default rules table (rflag-rules-default.txt) was not found." >&2
  echo "  Looked in: $hook_dir/ and $hook_dir/../lib/. Re-run install.sh to redistribute the SinkSeal hooks." >&2
  exit 2
fi
rule_files=("$default_rules")
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

# The diff body is read in its own step so a git failure here cannot be mistaken for "no added
# lines" (which would make every CONTENT rule silently match nothing).
if ! staged_diff=$(git diff --cached -- . ':(exclude).githooks/**'); then
  echo "R-flag scan: could not read the staged diff from git. Unable to inspect is not a pass." >&2
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
        # grep exit 1 = no match (fine); exit 2 = the rule itself is not a valid regex. A broken
        # rule must stop the scan, not silently drop out as "no match".
        grc=0
        hit=$(printf '%s\n' "$staged_files" | grep -iE -e "$pattern") || grc=$?
        if [ "$grc" -ge 2 ]; then
          echo "R-flag scan: rule is not a valid regular expression (grep exit=${grc}): $line" >&2
          exit 2
        fi
        [ -n "$hit" ] && matched+=("PATH[$pattern] -> $(echo "$hit" | tr '\n' ' ')")
        ;;
      CONTENT:*)
        pattern="${line#CONTENT:}"
        grc=0
        hit=$(printf '%s\n' "$staged_added_lines" | grep -iE -e "$pattern") || grc=$?
        if [ "$grc" -ge 2 ]; then
          echo "R-flag scan: rule is not a valid regular expression (grep exit=${grc}): $line" >&2
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

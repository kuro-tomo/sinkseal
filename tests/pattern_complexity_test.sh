#!/bin/bash
# SinkSeal: pattern-complexity guard for lib/*.txt
#
# rflag-scan.sh, sink-scan.sh, and no-live-fire-check.sh all feed pattern-table
# lines straight into grep -E with no size cap and no validation beyond regex
# *syntax* — a syntactically valid but pathological pattern (classic shape:
# a repetition quantifier applied to a group that itself contains a repetition
# quantifier, e.g. `(a+)+`) can trigger catastrophic backtracking on some regex
# engines when it meets matching input, degrading every future commit/CI run
# for the life of the repo (dcr-scan TRIAGE.md finding f001, 2026-07-27).
#
# This is a static check, not a timing test — deliberately, so it's
# deterministic and has no dependency on a `timeout` binary (not guaranteed
# present on stock macOS). It flags the textbook nested-quantifier shape
# directly rather than trying to time an actual match.
#
# Run this in CI against lib/*.txt before shipping any pattern-table change.
# Downstream adopters extending .forge/rflag-rules.txt or .forge/sinks.txt
# with their own patterns should run the same check against those files.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A repetition quantifier (+ or *) applied to a group that itself contains a
# repetition quantifier at its top level: (...+...)+ / (...+...)* /
# (...*...)+ / (...*...)*. This is a heuristic, not a full backtracking
# analysis -- it catches the classic textbook shape, not every possible
# pathological construct.
nested_quantifier_re='\([^()]*[+*][^()]*\)[+*]'

violations=0
for f in "$KIT_DIR"/lib/*.txt; do
  [ -f "$f" ] || continue
  fname=$(basename "$f")
  # shellcheck disable=SC2094 # basename only reads $f's path string, no write conflict with the `< "$f"` read below
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    if echo "$line" | grep -qE "$nested_quantifier_re"; then
      echo "SUSPECT (nested quantifier -- possible ReDoS): $fname: $line"
      violations=$((violations + 1))
    fi
  done < "$f"
done

if [ "$violations" -gt 0 ]; then
  echo ""
  echo "=== $violations suspect pattern(s) found. Rewrite to avoid a quantifier"
  echo "    directly wrapping a group that already contains one. ==="
  exit 1
fi

echo "Pattern complexity check: no nested-quantifier patterns found in lib/*.txt (pass)."
exit 0

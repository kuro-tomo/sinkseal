#!/bin/bash
# SinkSeal version: 0.1.0
# SinkSeal: live-fire sink scan (pre-commit stage)
# Pattern-matches the "added" lines of the staged diff against the sink table.
# Comment-only lines are excluded so that leaving a note about a prior fix never
# produces a false positive.
#
# Verdict:
#   - Test/spec paths (test, spec, e2e, etc.): a safety net, not a danger source —
#     excluded from scanning.
#   - Demo/mock paths (demo, mock, sandbox, etc.) adding a raw sink -> hard block
#     (exit 2). Demo code paths must go through a guarded relay (e.g.
#     notifier.notify() with an unconditional no-op for synthetic/test tenant
#     IDs) instead of calling the raw sink directly — that's the "sink sealing"
#     principle this scanner exists to enforce.
#   - Any other path adding a raw sink -> soft R-flag (exit 1). Touching the sink
#     itself (notifier, sns_service, stripe_handler, etc.) is risk-adjacent
#     enough to require an explicit acknowledgment via a commit trailer.
#   - No raw sink added -> exit 0.
#
# This file is copied self-contained into each repo's .githooks/ by install.sh.
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Installed repos keep these directly under .githooks/ (install.sh copies both
# files there); running from the SinkSeal checkout itself keeps them under
# ../lib/ instead — check both, matching no-live-fire-check.sh and
# sink-inventory-drift.sh, so this doesn't silently fail open just because it's
# being run from the source layout rather than an installed one.
default_sinks="$hook_dir/sinks-default.txt"
[ -f "$default_sinks" ] || default_sinks="$hook_dir/../lib/sinks-default.txt"
sink_hosts="$hook_dir/sink-hosts.txt"
[ -f "$sink_hosts" ] || sink_hosts="$hook_dir/../lib/sink-hosts.txt"
custom_sinks="$repo_root/.forge/sinks.txt"

# sink-hosts.txt exists specifically to catch a raw-HTTP bypass of a vendor SDK
# (e.g. `fetch("https://api.twilio.com/...")` instead of the Twilio SDK). Loading
# only sinks-default.txt here would leave that bypass path completely unscanned
# at the flow (pre-commit) stage even though the CI stock sweep (no-live-fire-check.sh)
# does check it — the two are supposed to be flow/stock variants of the same policy.
patterns=()
for f in "$default_sinks" "$sink_hosts" "$custom_sinks"; do
  [ -f "$f" ] || continue
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    patterns+=("$line")
  done < "$f"
done
if [ "${#patterns[@]}" -eq 0 ]; then
  # A safety net must not report green when it's out of fuel. Silently exiting 0
  # here would make a missing/misplaced pattern table indistinguishable from
  # "nothing to flag" (Codex verification, 2026-07-27, flagged this exact gap).
  echo "Live-fire sink scan: **cannot run** — no sink pattern table found (sinks-default.txt missing)." >&2
  echo "  Looked in: $hook_dir/ and $hook_dir/../lib/" >&2
  echo "  Re-run install.sh to redistribute the SinkSeal hooks." >&2
  exit 1
fi
combined=$(IFS='|'; echo "${patterns[*]}")

# Drop comment-only lines (line-comment markers for common languages). A leading
# `*/` (closing a block comment) is stripped first so that real code sharing a
# line with a comment terminator — e.g. `*/sns_service.send_notification(x)` —
# isn't misclassified as comment-only and dropped from scanning.
comment_re='^[[:space:]]*(#|//|\*|/\*|<!--|--)'
strip_leading_close_comment_re='s#^([[:space:]]*)\*/#\1#'
# Anchored on non-letter boundaries (path already lowercased) so a substring
# match inside an unrelated name doesn't misfire — "attestation.py" must not
# match "test", and "seeding_data.py" must not match "seed".
demo_re='(^|[^a-z])(demo|mock|sandbox|fixture|sample|seed)s?([^a-z]|$)'
test_re='(^|[^a-z])(test|spec|e2e)s?([^a-z]|$)|__tests__|\.stories\.'
# Prose, data, and control-plane directories can't execute a sink, so they're
# excluded from scanning.
skip_re='(^|/)(\.githooks|\.forge|node_modules|dist|build|coverage)/|\.(md|rst|txt|json|lock|map|svg|png|jpe?g|gif|ico|woff2?|ttf|csv|snap|ipynb)$'

# --diff-filter=ACMR: include renames (R) too, not just added/copied/modified —
# a rename that also edits in a raw sink call must not be invisible to this scan.
staged=$(git diff --cached --name-only --diff-filter=ACMR || true)
[ -z "$staged" ] && exit 0

hard=()
soft=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  echo "$f" | grep -qE "$skip_re" && continue
  added=$(git diff --cached -- "$f" 2>/dev/null \
    | grep -E '^\+' | grep -vE '^\+\+\+' | sed 's/^+//' \
    | sed -E "$strip_leading_close_comment_re" \
    | grep -vE "$comment_re" || true)
  [ -z "$added" ] && continue
  echo "$added" | grep -qE "$combined" || continue

  low=$(echo "$f" | tr '[:upper:]' '[:lower:]')
  if echo "$low" | grep -qE "$test_re"; then
    continue
  elif echo "$low" | grep -qE "$demo_re"; then
    hard+=("$f")
  else
    soft+=("$f")
  fi
done <<< "$staged"

if [ "${#hard[@]}" -gt 0 ]; then
  echo "Live-fire hard block: demo/mock code is calling a raw external-facing sink directly."
  printf '%s\n' "${hard[@]}" | sort -u | sed 's/^/  - /'
  echo "  Demo paths must go through a guarded relay (notifier.notify() etc. with an"
  echo "  unconditional no-op for a synthetic/test tenant ID). A direct raw-sink call from"
  echo "  a demo path violates sink sealing and is how real accidental charges happen."
  exit 2
fi

if [ "${#soft[@]}" -gt 0 ]; then
  echo "Change touches a live-fire sink (raw outbound call site):"
  printf '%s\n' "${soft[@]}" | sort -u | sed 's/^/  - /'
  exit 1
fi

exit 0

#!/bin/bash
# SinkSeal version: 0.1.1
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
  # Exit 3 ("could not run"), not 1: 1 means "soft R-flag", which pre-commit lets through with
  # an R-Flag trailer -- so a broken install could be waved past. pre-commit refuses 3.
  exit 3
fi
combined=$(IFS='|'; echo "${patterns[*]}")

# One invalid regex line in a pattern table makes the combined pattern invalid, and
# every later grep then exits 2 -- which the `|| continue` below reads as "no match",
# so the whole scan would pass silently. Validate once, up front (no-live-fire-check.sh
# already does this). grep exit 0/1 = pattern compiled; 2 or more = it did not.
gr=0
printf 'x' | grep -IqE "$combined" 2>/dev/null || gr=$?
if [ "$gr" -ge 2 ]; then
  echo "Live-fire sink scan: the sink pattern table contains an invalid regex, so the scan cannot run (exit=${gr})." >&2
  echo "  Check sinks-default.txt / sink-hosts.txt / .forge/sinks.txt for unbalanced parentheses or brackets." >&2
  exit 3
fi

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
#
# File names are read NUL-delimited (-z), as raw bytes. Without -z, git's default
# (core.quotepath=true) wraps a non-ASCII name in double quotes with octal
# escapes ("svc_\344\273\225.py"), and the per-file `git diff -- "$f"` below then
# matched no path at all and silently skipped that file's sinks. Failure to
# list the files or to fetch a diff is exit 3 ("could not run"), never "no
# sink". (Exit 0/1/2 are the verdicts above; pre-commit refuses anything else.)
staged_list="$(mktemp "${TMPDIR:-/tmp}/sink-scan.XXXXXX")" || exit 3
trap 'rm -f "$staged_list"' EXIT
if ! git diff --cached --name-only -z --diff-filter=ACMR > "$staged_list"; then
  echo "Live-fire sink scan: could not list the staged files from git. A scan that cannot run is not a pass." >&2
  exit 3
fi
[ -s "$staged_list" ] || exit 0

hard=()
soft=()
while IFS= read -r -d '' f; do
  [ -z "$f" ] && continue
  printf '%s\n' "$f" | grep -qE "$skip_re" && continue
  # :(literal) so the name is a literal path, not a pathspec pattern.
  if ! diff_out=$(git diff --cached -- ":(literal)$f"); then
    echo "Live-fire sink scan: could not fetch the diff of ${f} from git. A scan that cannot run is not a pass." >&2
    exit 3
  fi
  # Byte-wise (LC_ALL=C): under a UTF-8 locale BSD sed/grep abort with "illegal byte sequence" on
  # a file holding non-UTF-8 bytes (e.g. Shift-JIS), and the `|| true` turned that into "no added
  # lines" -- the file's sinks were silently passed. The patterns are ASCII, so bytes are enough.
  added=$(export LC_ALL=C; printf '%s\n' "$diff_out" \
    | grep -E '^\+' | grep -vE '^\+\+\+' | sed 's/^+//' \
    | sed -E "$strip_leading_close_comment_re" \
    | grep -vE "$comment_re" || true)
  [ -z "$added" ] && continue
  # Capture grep's output rather than using `grep -q` or `>/dev/null`: -q stops reading at the
  # first match, and GNU grep does the same when its stdout is /dev/null; the writer then dies
  # of SIGPIPE, which under pipefail reads as "no match" (a big file with a sink on its first
  # line was silently passed: ~300KB, exit 0). Capturing makes grep read all its input.
  # grep exit: 0 = match, 1 = no match, 2 or more = it could not run.
  gr=0; hit=$(printf '%s\n' "$added" | grep -E "$combined") || gr=$?
  if [ "$gr" -ge 2 ]; then
    echo "Live-fire sink scan: matching the sink patterns against ${f} failed (grep exit=${gr}). A scan that cannot run is not a pass." >&2
    exit 3
  fi
  [ -n "$hit" ] || continue

  low=$(echo "$f" | tr '[:upper:]' '[:lower:]')
  if echo "$low" | grep -qE "$test_re"; then
    continue
  elif echo "$low" | grep -qE "$demo_re"; then
    hard+=("$f")
  else
    soft+=("$f")
  fi
done < "$staged_list"

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

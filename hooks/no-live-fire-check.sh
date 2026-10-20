#!/bin/bash
# SinkSeal version: 0.1.0
# SinkSeal: live-fire CI sweep (no-live-fire-check)
# Scans every tracked file in the repo against the sink patterns and fails if any
# file not listed in the allowlist (.forge/sinks-allow.txt) contains a raw sink.
# This exists because a diff review (flow) can never catch a live-fire call site
# that was already sitting on the main branch before this control was installed
# (stock) — only a full-tree sweep can.
#
# On a repo with zero live-fire sinks, this acts as an "armed empty trap": the
# moment someone later adds a real vendor (Twilio, Stripe, etc.), the machine
# notices.
#
# Comment lines are excluded (so a note about a prior fix never false-positives).
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Installed repos keep these directly under .githooks/; running from the SinkSeal
# checkout itself keeps them under ../lib/ — check both so this never silently
# fails open just because it's being run from the wrong location.
default_sinks="$hook_dir/sinks-default.txt"
[ -f "$default_sinks" ] || default_sinks="$hook_dir/../lib/sinks-default.txt"
sink_hosts="$hook_dir/sink-hosts.txt"
[ -f "$sink_hosts" ] || sink_hosts="$hook_dir/../lib/sink-hosts.txt"
custom_sinks="$repo_root/.forge/sinks.txt"
allow="$repo_root/.forge/sinks-allow.txt"

# Strip a trailing `  # comment` and trailing whitespace. Skipping this turns an
# allowlist line like "path/to/file.py  # reason" into a regex that includes the
# comment text, so an entry someone thought they'd registered silently fails to
# match. That fails safely toward "still flagged," but it's confusing enough to
# the person who wrote it that it's worth fixing properly.
strip_comment() { printf '%s' "$1" | sed 's/[[:space:]]\{1,\}#.*$//; s/[[:space:]]*$//'; }

patterns=()
for f in "$default_sinks" "$sink_hosts" "$custom_sinks"; do
  [ -f "$f" ] || continue
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    line=$(strip_comment "$line")
    [ -z "$line" ] && continue
    patterns+=("$line")
  done < "$f"
done
if [ "${#patterns[@]}" -eq 0 ]; then
  # A safety net that runs out of fuel must not report green. Silently skipping
  # here (as an earlier version of this check did) would make a missing or
  # misplaced pattern table look identical to "everything passed."
  echo "Live-fire CI sweep: **cannot run** — sink pattern table not found (sinks-default.txt missing)." >&2
  echo "  Looked in: $hook_dir/sinks-default.txt and $hook_dir/../lib/sinks-default.txt" >&2
  echo "  Re-run install.sh to redistribute the SinkSeal hooks." >&2
  exit 1
fi
combined=$(IFS='|'; echo "${patterns[*]}")

# If a single line in the pattern table is an invalid regex (unbalanced
# parens, etc.), the combined pattern becomes malformed and every subsequent
# grep call returns a syntax error instead of "no match." An earlier version
# didn't distinguish that from "no match" and let the whole repo scan pass
# silently — a fail-open bug that hid even obvious raw sinks. Validate once,
# up front, before scanning any files.
printf 'x' | grep -IqE "$combined" 2>/dev/null
pattern_rc=$?
if [ "$pattern_rc" -ge 2 ]; then
  echo "Live-fire CI sweep: **cannot run** — the sink pattern table contains an invalid regex." >&2
  echo "  Check sinks-default.txt / sink-hosts.txt / .forge/sinks.txt for unbalanced" \
       "parentheses or brackets." >&2
  exit 1
fi

comment_re='^[[:space:]]*(#|//|\*|/\*|<!--|--)'
# A leading `*/` (closing a block comment) is stripped before this test, so real
# code sharing a line with a comment terminator isn't misclassified as
# comment-only (see the `real=` line below).
strip_leading_close_comment_re='s#^([[:space:]]*)\*/#\1#'
# Prose, data, and control-plane directories can't "execute" a sink, so they're
# excluded (avoids false positives from a sink name mentioned in a .md file, a
# dependency name in a lockfile, or the pattern table itself).
skip_re='(^|/)(\.githooks|\.forge|node_modules|dist|build|coverage)/|\.(md|rst|txt|json|lock|map|svg|png|jpe?g|gif|ico|woff2?|ttf|csv|snap|ipynb)$'

allow_pats=()
if [ -f "$allow" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    line=$(strip_comment "$line")
    [ -z "$line" ] && continue
    allow_pats+=("$line")
  done < "$allow"
fi

# The tracked-file list is read with -z (NUL-delimited) so names arrive raw.
# Without -z, git C-quotes non-ASCII names into octal escapes ("svc_\346\227..."),
# the `$repo_root/$f` below then points at a path that does not exist, and a raw
# sink in a file with a non-ASCII name is silently waved through. If git fails to
# list the files, fail (exit 2) rather than sweep an empty list and report a pass.
tracked_list="$(mktemp "${TMPDIR:-/tmp}/sinkseal-no-live-fire.XXXXXX")" || {
  echo "Live-fire CI sweep: **cannot run** -- could not create a temporary file (is TMPDIR writable?)." >&2
  exit 2
}
trap 'rm -f "$tracked_list"' EXIT
if ! git ls-files -z > "$tracked_list"; then
  echo "Live-fire CI sweep: **cannot run** -- could not list the tracked files from git." >&2
  exit 2
fi

violations=()
while IFS= read -r -d '' f; do
  [ -z "$f" ] && continue
  printf '%s\n' "$f" | grep -qE "$skip_re" && continue
  # -I treats binaries as non-matching. Check the raw match first, then confirm a
  # real (non-comment) match.
  grep -IqE "$combined" -- "$repo_root/$f" 2>/dev/null || continue
  real=$(grep -IE "$combined" -- "$repo_root/$f" 2>/dev/null \
    | sed -E "$strip_leading_close_comment_re" | grep -vE "$comment_re" || true)
  [ -z "$real" ] && continue   # only appears in a comment -> not a live sink

  allowed=0
  for ap in "${allow_pats[@]:-}"; do
    [ -z "$ap" ] && continue
    # An unanchored substring match would let an allowed path implicitly cover an
    # unrelated file that merely contains it as a substring (e.g. an allowlisted
    # "legit/backend/services/mail_service.py" would also match
    # "backend/services/mail_service.py.evil"). Always anchor the start. A
    # trailing "/" means "everything under this prefix is allowed," so the end
    # is left open; anything else names one specific file, so the end is
    # anchored too.
    case "$ap" in
      */) end='' ;;
      *) end='$' ;;
    esac
    if echo "$f" | grep -qE "^($ap)$end"; then allowed=1; break; fi
  done
  [ "$allowed" -eq 1 ] && continue
  violations+=("$f")
done < "$tracked_list"

if [ "${#violations[@]}" -gt 0 ]; then
  echo "Live-fire CI sweep: files not in the allowlist (.forge/sinks-allow.txt) contain a raw external-facing sink:"
  printf '%s\n' "${violations[@]}" | sed 's/^/  - /'
  echo ""
  echo "Options:"
  echo "  (a) Legitimate sink holder (notifier, a specific service, etc.) -> add it to .forge/sinks-allow.txt"
  echo "  (b) Reachable from a demo/test path -> seal the sink (guarded relay + synthetic-tenant no-op)"
  echo "  (c) Dead code (unused) -> delete it"
  echo "  (d) Intentional live-fire demo -> register it in LIVE_FIRE.md and add it to the allowlist too"
  exit 1
fi

echo "Live-fire CI sweep: no un-allowlisted raw sinks found (pass)."
exit 0

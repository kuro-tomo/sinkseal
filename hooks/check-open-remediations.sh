#!/bin/bash
# SinkSeal version: 0.1.0
# SinkSeal: open-remediation cross-check (Claude Code memory integration)
# Invocation: check-open-remediations.sh
# Output: if a staged change's keywords overlap with an open item ("- [ ] ") in
#         Claude Code's per-project memory notes, lists the hits to stdout and
#         exits 1. No overlap -> exit 0.
#
# This is opt-in by construction: it only does anything if the repo is being
# worked on through Claude Code, which keeps a per-project memory directory
# under ~/.claude/projects/<sanitized-repo-path>/memory/. Any other workflow
# simply has no such directory, and this check no-ops (exit 0) immediately.
#
# Motivation: a past incident review can write "the correct fix has 5 parts" into
# a memory file, and a later change can address only 4 of them because whoever
# implemented it read a one-line summary elsewhere ("see incident notes for
# details") without following the reference to the full list, including the
# item still outstanding. "Be more careful next time" doesn't reliably prevent
# that class of miss, so this promotes it to a mechanical cross-check instead.
#
# Convention: open items in memory/*.md must start with "- [ ] " (mark resolved
# ones "- [x] ", or delete the line). Existing memory entries that don't follow
# this convention are simply invisible to this check — it's designed to accept
# missed detections over false positives.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Resolve the main repo root via git-common-dir so this also works correctly
# from inside a worktree (a worktree doesn't have its own memory directory —
# it shares the main repo's).
common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
case "$common_dir" in
  /*) : ;;
  *) common_dir="$repo_root/$common_dir" ;;
esac
main_repo_root=$(cd "$(dirname "$common_dir")" && pwd)

# Claude Code replaces every non-alphanumeric character with "-", not just "/"
# (e.g. a worktree path containing "/.claude-worktrees/" becomes
# "--claude-worktrees-", with the dot also turned into a dash). Replacing only
# "/" would compute a directory name Claude Code never actually creates for any
# repo path containing a dot, underscore, or space, and this check would then
# silently no-op for that entire project.
# shellcheck disable=SC2001 # ${var//pattern/repl} doesn't support this POSIX class portably across bash versions
sanitized=$(echo "$main_repo_root" | sed 's/[^A-Za-z0-9]/-/g')
memory_dir="$HOME/.claude/projects/${sanitized}/memory"

[ -d "$memory_dir" ] || exit 0

# The file list is read with -z (NUL-delimited) so names arrive raw. Without -z,
# git C-quotes non-ASCII names into octal escapes ("docs/manual_\346\223..."),
# and the grep below then read those "\346" as a back-reference, exited with
# "invalid backreference number", and the `|| true` swallowed it -- the whole
# check silently did nothing for any file with a non-ASCII name.
gr=0
staged_files=$(git diff --cached --name-only -z | tr '\0' '\n'; exit "${PIPESTATUS[0]}") || gr=$?
if [ "$gr" -ne 0 ]; then
  echo "Open-remediation check: could not read the staged file list from git (exit=${gr}). Unable to inspect is not a pass." >&2
  exit 2
fi
[ -z "$staged_files" ] && exit 0

# Basenames of staged files (extension stripped, lowercased, deduped, entries
# under 4 chars dropped to cut down on noise). Plain shell string operations
# are used instead of xargs/basename, which mangle names that start with "-"
# or contain quote characters.
keywords=$(printf '%s\n' "$staged_files" \
  | while IFS= read -r p; do b="${p##*/}"; printf '%s\n' "${b%.*}"; done \
  | tr '[:upper:]' '[:lower:]' \
  | awk 'length($0) >= 4' \
  | sort -u)

[ -z "$keywords" ] && exit 0

open_items=$(grep -inE "^- \[ \]" "$memory_dir"/*.md 2>/dev/null || true)

matched=()
while IFS= read -r kw; do
  [ -z "$kw" ] && continue
  # The name is matched as a fixed string (-F): read as a regex, a "\1" or "[" in
  # a file name would be misparsed. grep exits 0 = match, 1 = no match, 2+ = error;
  # an error must not be swallowed as "no related item".
  gr=0; hits=$(printf '%s\n' "$open_items" | grep -iF -- "$kw") || gr=$?
  if [ "$gr" -ge 2 ]; then
    echo "Open-remediation check: matching failed (keyword='${kw}', grep exit=${gr}). Unable to inspect is not a pass." >&2
    exit 2
  fi
  [ -n "$hits" ] && matched+=("$hits")
done <<< "$keywords"

if [ "${#matched[@]}" -gt 0 ]; then
  echo "This change may be related to an open item in memory (\"- [ ] \" entries):"
  printf '%s\n' "${matched[@]}" | sort -u | sed 's/^/  - /'
  echo ""
  echo "Confirm whether this change covers these open items, or is deliberately unrelated."
  exit 1
fi

exit 0

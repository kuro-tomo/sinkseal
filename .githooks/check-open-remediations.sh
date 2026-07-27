#!/bin/bash
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

staged_files=$(git diff --cached --name-only || true)
[ -z "$staged_files" ] && exit 0

# Basenames of staged files (extension stripped, lowercased, deduped, entries
# under 4 chars dropped to cut down on noise).
keywords=$(echo "$staged_files" \
  | xargs -I{} basename {} \
  | sed -E 's/\.[^.]+$//' \
  | tr '[:upper:]' '[:lower:]' \
  | awk 'length($0) >= 4' \
  | sort -u)

[ -z "$keywords" ] && exit 0

matched=()
while IFS= read -r kw; do
  [ -z "$kw" ] && continue
  hits=$(grep -inE "^- \[ \]" "$memory_dir"/*.md 2>/dev/null | grep -i -- "$kw" || true)
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

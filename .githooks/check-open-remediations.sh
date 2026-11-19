#!/bin/bash
# SinkSeal version: 0.1.1
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

# Read the staged file names NUL-delimited (-z), as raw bytes. Without -z, git's
# default (core.quotepath=true) wraps any non-ASCII name in double quotes with
# octal escapes ("docs/\344\273\225..._v051.md"); that quoted form then became a
# search keyword, and the "\344" in it was read by grep as a regex back-reference,
# so grep died with "invalid backreference number". The old `|| true` swallowed
# that failure and the check silently passed without looking at anything --
# i.e. a check that could not run was treated as a pass. A failure to list the
# staged files is now exit 2 (refuse), not "nothing to check".
gr=0
staged_files=$(git diff --cached --name-only -z | tr '\0' '\n'; exit "${PIPESTATUS[0]}") || gr=$?
if [ "$gr" -ne 0 ]; then
  echo "open-remediation check: could not list the staged files from git (exit=${gr}). A check that cannot run is not a pass." >&2
  exit 2
fi
[ -z "$staged_files" ] && exit 0

# Basenames of staged files (extension stripped, lowercased, deduped, entries
# under 4 chars dropped to cut down on noise). Taken with shell string
# operations rather than xargs/basename, which break on names containing quotes
# or starting with "-".
keywords=$(printf '%s\n' "$staged_files" \
  | while IFS= read -r p; do b="${p##*/}"; printf '%s\n' "${b%.*}"; done \
  | tr '[:upper:]' '[:lower:]' \
  | awk 'length($0) >= 4' \
  | sort -u)

[ -z "$keywords" ] && exit 0

# The open items, collected once. grep exit 0 = matched, 1 = no match, 2 or more =
# error, which must not be read as "no open items".
memory_candidates=("$memory_dir"/*.md)
# With no *.md at all the glob stays literal ("*.md"), which is not a regular file and is
# dropped here, so an empty memory directory is still the quiet "nothing to check" path.
# Only regular, readable notes are searched. A dangling symlink, a directory named x.md or a
# note without read permission is not a note this check can use; letting grep trip on it
# (exit 2) would block every commit until someone repaired the memory directory. This check is
# opt-in and designed to accept a missed detection over a false block; a genuine grep failure
# on a readable note is still refused below.
memory_files=()
for mf in "${memory_candidates[@]}"; do
  [ -f "$mf" ] && [ -r "$mf" ] && memory_files+=("$mf")
done
[ "${#memory_files[@]}" -eq 0 ] && exit 0
gr=0
open_items=$(grep -inE "^- \[ \]" "${memory_files[@]}") || gr=$?
if [ "$gr" -ge 2 ]; then
  echo "open-remediation check: could not read the memory notes (grep exit=${gr}). A check that cannot run is not a pass." >&2
  exit 2
fi

matched=()
while IFS= read -r kw; do
  [ -z "$kw" ] && continue
  # The keyword is matched as a literal string (-F), never as a regex: a file
  # name containing \1, [ or * must not be reinterpreted. Only grep exit 1
  # ("no match") means "not related"; exit 2 or more means the lookup itself
  # failed, which is refused rather than swallowed.
  gr=0; hits=$(printf '%s\n' "$open_items" | grep -iF -- "$kw") || gr=$?
  if [ "$gr" -ge 2 ]; then
    echo "open-remediation check: the keyword lookup failed (keyword='${kw}', grep exit=${gr}). A check that cannot run is not a pass." >&2
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

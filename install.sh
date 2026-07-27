#!/bin/bash
# SinkSeal install.sh — install the git hooks into a target repo, self-contained.
# Usage: ./install.sh /path/to/repo

set -euo pipefail

target="${1:?Usage: install.sh /path/to/repo}"
kit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hooks"

if [ ! -e "$target/.git" ]; then
  echo "Error: $target is not a git repository" >&2
  exit 1
fi
# Inside a worktree, .git is a file (a pointer to the real repo), not a
# directory, so a `-d` test would reject it (same issue pre-commit/commit-msg
# had to work around). Use `-e` (file or directory) and let git itself confirm
# validity.
if ! git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
  echo "Error: $target is not a git repository" >&2
  exit 1
fi

mkdir -p "$target/.githooks"
cp "$kit_dir/pre-commit" "$target/.githooks/pre-commit"
cp "$kit_dir/commit-msg" "$target/.githooks/commit-msg"
cp "$kit_dir/pre-push" "$target/.githooks/pre-push"
cp "$kit_dir/rflag-scan.sh" "$target/.githooks/rflag-scan.sh"
cp "$kit_dir/sink-scan.sh" "$target/.githooks/sink-scan.sh"
cp "$kit_dir/no-live-fire-check.sh" "$target/.githooks/no-live-fire-check.sh"
cp "$kit_dir/check-open-remediations.sh" "$target/.githooks/check-open-remediations.sh"
cp "$kit_dir/sink-inventory-drift.sh" "$target/.githooks/sink-inventory-drift.sh"
cp "$(dirname "$kit_dir")/lib/rflag-rules-default.txt" "$target/.githooks/rflag-rules-default.txt"
cp "$(dirname "$kit_dir")/lib/sinks-default.txt" "$target/.githooks/sinks-default.txt"
cp "$(dirname "$kit_dir")/lib/live-fire-vendors.txt" "$target/.githooks/live-fire-vendors.txt"
cp "$(dirname "$kit_dir")/lib/sink-hosts.txt" "$target/.githooks/sink-hosts.txt"
chmod +x "$target/.githooks/pre-commit" "$target/.githooks/commit-msg" "$target/.githooks/pre-push" \
         "$target/.githooks/rflag-scan.sh" "$target/.githooks/sink-scan.sh" \
         "$target/.githooks/no-live-fire-check.sh" "$target/.githooks/check-open-remediations.sh" \
         "$target/.githooks/sink-inventory-drift.sh"

git -C "$target" config core.hooksPath .githooks

echo "Installed: $target"
echo "  core.hooksPath = .githooks"
echo "  Add project-specific R-flag rules in: $target/.forge/rflag-rules.txt"
echo "  Add project-specific sink patterns in: $target/.forge/sinks.txt"
echo "  Allowlist for legitimate sink holders: $target/.forge/sinks-allow.txt (read by the CI sweep)"
echo "  Custom test command: $target/.forge/gates.sh (make it executable)"
echo "  Intentional live-fire demo ledger: $target/LIVE_FIRE.md (template: sinkseal/templates/LIVE_FIRE.md)"

# --- Machine-verify the CI wiring --------------------------------------------
# An earlier version stopped at printing "add this to your CI workflow." That
# instruction gets followed by whoever is paying close attention at install time
# and silently forgotten by everyone else — the live-fire CI sweep ended up
# actually wired into CI on a small minority of repos it was "installed" on,
# and nobody noticed for a long time because the install script itself reported
# success either way. Replace the instruction with a check.
missing=()
for chk in no-live-fire-check.sh sink-inventory-drift.sh; do
  if ! grep -rqs "$chk" "$target/.github/workflows/" 2>/dev/null; then
    missing+=("$chk")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo ""
  echo "WARNING: CI not wired up. The following are never invoked from any workflow:"
  printf '    - %s\n' "${missing[@]}"
  echo "    Add a job to .github/workflows/ci.yml that runs them, and register that job as a"
  echo "    required status check under branch protection."
  echo "    (Green CI without this wiring does not mean the install is complete.)"
  exit 2
fi
echo "  CI wiring: verified (both no-live-fire-check.sh and sink-inventory-drift.sh are invoked)"

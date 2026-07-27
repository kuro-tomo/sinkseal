#!/bin/bash
# SinkSeal's own pre-push test command (this repo's .forge/gates.sh).
# SinkSeal is a pure bash/text project (no package.json/requirements.txt),
# so pre-push's generic auto-detection finds nothing to run. This is the
# project-specific override it looks for instead.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

echo "-> Syntax-checking all shell scripts..."
for f in "$repo_root"/hooks/*.sh "$repo_root"/hooks/pre-commit "$repo_root"/hooks/commit-msg \
         "$repo_root"/hooks/pre-push "$repo_root"/install.sh "$repo_root"/tests/*.sh; do
  bash -n "$f" || fail=1
done

echo "-> Running smoke test suite..."
bash "$repo_root/tests/smoke_test.sh" || fail=1

echo "-> Running pattern-complexity guard..."
bash "$repo_root/tests/pattern_complexity_test.sh" || fail=1

exit "$fail"

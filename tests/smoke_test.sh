#!/bin/bash
# SinkSeal smoke test — codifies the scenarios manually verified during the
# ultracode review and Codex verification passes (2026-07-27) into a single
# repeatable script, so "it worked when I tried it by hand" becomes an actual
# regression test instead of a claim.
#
# Builds a throwaway git repo under a temp directory, installs the hooks into
# it, and asserts the exit code of each hook invocation for a battery of
# cases. Exits 0 if every case matches its expected exit code, exits 1 and
# prints which cases failed otherwise.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

pass=0
fail=0
failures=()

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    pass=$((pass + 1))
    echo "PASS: $desc (exit=$actual)"
  else
    fail=$((fail + 1))
    failures+=("$desc (expected exit=$expected, got exit=$actual)")
    echo "FAIL: $desc (expected exit=$expected, got exit=$actual)"
  fi
}

# --- set up a throwaway repo, installed the normal way -----------------------
REPO="$SCRATCH/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q
git config user.email test@example.com
git config user.name test
echo hello > README.md
git add README.md
git commit -q -m init
mkdir -p .github/workflows
printf 'jobs: {x: {steps: [{run: ./.githooks/no-live-fire-check.sh}, {run: ./.githooks/sink-inventory-drift.sh}]}}\n' > .github/workflows/ci.yml
git add .github/workflows/ci.yml
git commit -q -m ci

install_rc=0
"$KIT_DIR/install.sh" "$REPO" >/tmp/sinkseal_install.log 2>&1 || install_rc=$?
check "install.sh succeeds and verifies CI wiring" 0 "$install_rc"

# --- Case: committing the freshly-installed .githooks/ must not self-trigger
# an R-flag (the pattern tables' own "CONTENT:set-cookie" etc. lines would
# otherwise match themselves the moment they're first added to the repo --
# every single adopter would hit this on their very first commit) ----------
git add .githooks >/dev/null 2>&1
rc=0; .githooks/rflag-scan.sh >/dev/null 2>&1 || rc=$?
check "committing the installed .githooks/ does not self-trigger an R-flag" 0 "$rc"
git reset -q .githooks >/dev/null 2>&1

# --- Case 1: raw-HTTP bypass of an SDK (sink-hosts.txt) is caught -----------
mkdir -p demo
cat > demo/raw_http.py <<'EOF'
import requests
def fire():
    requests.post("https://api.twilio.com/2010-04-01/Accounts/AC1/Messages.json", data={})
EOF
git add demo/raw_http.py
rc=0; .githooks/sink-scan.sh >/dev/null 2>&1 || rc=$?
check "sink-scan.sh hard-blocks raw-HTTP bypass via sink-hosts.txt" 2 "$rc"
git reset -q demo/raw_http.py; rm -rf demo

# --- Case 2: 'attestation.py' must not be exempted as a test path -----------
cat > attestation.py <<'EOF'
def fire():
    twilio_service.send("hi")
EOF
git add attestation.py
rc=0; .githooks/sink-scan.sh >/dev/null 2>&1 || rc=$?
check "sink-scan.sh does not misclassify attestation.py as a test path" 1 "$rc"
git reset -q attestation.py; rm -f attestation.py

# --- Case 3: 'seeding_data.py' must not be hard-blocked as a demo path ------
cat > seeding_data.py <<'EOF'
def fire():
    twilio_service.send("hi")
EOF
git add seeding_data.py
rc=0; .githooks/sink-scan.sh >/dev/null 2>&1 || rc=$?
check "sink-scan.sh does not misclassify seeding_data.py as a demo path" 1 "$rc"
git reset -q seeding_data.py; rm -f seeding_data.py

# --- Case 4: a real demo/ path still hard-blocks (anchoring regression) ----
mkdir -p demo
cat > demo/x.py <<'EOF'
def fire():
    twilio_service.send("hi")
EOF
git add demo/x.py
rc=0; .githooks/sink-scan.sh >/dev/null 2>&1 || rc=$?
check "sink-scan.sh still hard-blocks a genuine demo/ path" 2 "$rc"
git reset -q demo/x.py; rm -rf demo

# --- Case 5: code sharing a line with a comment-closer is still scanned ----
cat > weird.js <<'EOF'
/* old note
*/twilio_service.send("hi")
EOF
git add weird.js
rc=0; .githooks/sink-scan.sh >/dev/null 2>&1 || rc=$?
check "sink-scan.sh detects a sink call sharing a line with */" 1 "$rc"
git reset -q weird.js; rm -f weird.js

# --- Case 6/7: commit-msg trailer anchoring ----------------------------------
git_dir=$(git rev-parse --absolute-git-dir)
printf 'Summary\n\nR-Flag: yesfurthermore\n' > /tmp/sinkseal_msg1.txt
touch "$git_dir/FORGE_RFLAG_DETECTED"
rc=0; .githooks/commit-msg /tmp/sinkseal_msg1.txt >/dev/null 2>&1 || rc=$?
check "commit-msg rejects 'R-Flag: yesfurthermore'" 1 "$rc"

printf 'Summary\n\nR-Flag: yes\n' > /tmp/sinkseal_msg2.txt
touch "$git_dir/FORGE_RFLAG_DETECTED"
rc=0; .githooks/commit-msg /tmp/sinkseal_msg2.txt >/dev/null 2>&1 || rc=$?
check "commit-msg accepts 'R-Flag: yes'" 0 "$rc"
rm -f /tmp/sinkseal_msg1.txt /tmp/sinkseal_msg2.txt

# --- Case 8: no-live-fire-check.sh stock sweep + allowlist ------------------
mkdir -p demo
cat > demo/trigger.py <<'EOF'
import twilio.rest
def fire():
    twilio.rest.Client().messages.create(to="+1", body="hi")
EOF
git add demo/trigger.py
rc=0; .githooks/no-live-fire-check.sh >/dev/null 2>&1 || rc=$?
check "no-live-fire-check.sh (stock sweep) flags an un-allowlisted sink" 1 "$rc"
mkdir -p .forge
echo 'demo/trigger\.py$' > .forge/sinks-allow.txt
rc=0; .githooks/no-live-fire-check.sh >/dev/null 2>&1 || rc=$?
check "no-live-fire-check.sh passes once the file is allowlisted" 0 "$rc"
git reset -q demo/trigger.py; rm -rf demo .forge/sinks-allow.txt

# --- Case 9: sink-inventory-drift.sh covers the newly added SDK vendors ----
echo '{"dependencies": {"vonage": "^3.0.0", "messagebird": "^4.0.0"}}' > package.json
git add package.json
rc=0; .githooks/sink-inventory-drift.sh >/dev/null 2>&1 || rc=$?
check "sink-inventory-drift.sh covers vonage/messagebird via new patterns" 0 "$rc"
git reset -q package.json; rm -f package.json

# --- Case 10: fail-closed when pattern tables are entirely absent -----------
ISOLATED=$(mktemp -d)
cp "$KIT_DIR/hooks/sink-scan.sh" "$ISOLATED/"
rc=0; "$ISOLATED/sink-scan.sh" >/dev/null 2>&1 || rc=$?
check "sink-scan.sh fails closed (exit 1) with no pattern table reachable" 1 "$rc"
rm -rf "$ISOLATED"

# --- Case 11: ../lib fallback works from the source checkout layout --------
mkdir -p demo
cat > demo/raw_http2.py <<'EOF'
import requests
def fire():
    requests.post("https://api.twilio.com/x", data={})
EOF
git add demo/raw_http2.py
rc=0; "$KIT_DIR/hooks/sink-scan.sh" >/dev/null 2>&1 || rc=$?
check "sink-scan.sh finds patterns via ../lib fallback (source layout)" 2 "$rc"
git reset -q demo/raw_http2.py; rm -rf demo

# --- Case 12: shipped pattern tables carry no nested-quantifier (ReDoS) shapes ---
rc=0; "$KIT_DIR/tests/pattern_complexity_test.sh" >/dev/null 2>&1 || rc=$?
check "lib/*.txt pattern tables pass the complexity guard (dcr-scan f001)" 0 "$rc"

echo ""
echo "=== $pass passed, $fail failed ==="
if [ "$fail" -gt 0 ]; then
  printf 'FAILED: %s\n' "${failures[@]}"
  exit 1
fi
exit 0

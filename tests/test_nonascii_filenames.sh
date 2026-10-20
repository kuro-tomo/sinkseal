#!/bin/bash
# tests/test_nonascii_filenames.sh -- non-ASCII (and awkward) file names must not fall out of the hooks' view.
#
# Why this exists: by default git C-quotes any non-ASCII file name into octal
# escapes ("docs/\346\227\245..." -- wrapped in double quotes). The hooks used the
# output of `git diff --cached --name-only` / `git ls-files` as if it were the raw
# name, so for a file named in Japanese (or any non-ASCII script):
#   - rflag-scan.sh:             anchored path rules such as (^|/)auth never matched -> no R-flag
#   - sink-scan.sh:              `git diff -- "$f"` matched nothing -> the raw sink was skipped,
#                                including the demo/mock HARD BLOCK
#   - check-open-remediations.sh: the "\346" in the name was read as a regex back-reference,
#                                grep exited "invalid backreference number" and `|| true`
#                                swallowed it -> the whole check silently did nothing
#   - no-live-fire-check.sh:     `$repo_root/$f` pointed at a non-existent path -> CI sweep passed
#   - sink-inventory-drift.sh:   manifests under a non-ASCII directory dropped out of the inventory
# This test pins each of those, plus the fail-closed rule: if git/grep cannot do the
# inspection, the hook must stop (and pre-commit must refuse) -- "could not inspect"
# is never a pass.
#
# Every rejection/detection is checked for its REASON, not only its exit code: the output
# must contain the raw file name (not the octal-quoted one), so a hook that fails for some
# unrelated reason cannot masquerade as a working check.
#
# Usage: tests/test_nonascii_filenames.sh   (exit 0 = all cases pass)

set -u
# Hooks run in the user's real environment (usually a UTF-8 locale). macOS's stock bash 3.2
# mis-parses a variable name that is directly followed by a multibyte character when the
# locale is UTF-8, which aborts under `set -u`. Pinning the test to the C locale would hide
# that whole class of bug, so the suite runs the hooks under C and, where available, UTF-8.
if [ -z "${HOOK_LC:-}" ]; then
  utf8=""
  for c in $(locale -a 2>/dev/null | grep -iE '^(en_US|C|ja_JP)\.utf-?8$'); do utf8="${c}"; break; done
  rc=0
  for lc in C ${utf8}; do
    echo "##### hook locale: ${lc}"
    HOOK_LC="${lc}" bash "${BASH_SOURCE[0]}" || rc=1
  done
  [ -n "${utf8}" ] || echo "NOTE: no UTF-8 locale on this machine; ran under C only (UTF-8-specific bugs cannot be caught here)"
  exit "${rc}"
fi
export LC_ALL=C
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "${here}")"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sinkseal-nonascii.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

GIT="$(command -v git)"
[ -n "${GIT}" ] || { echo "FAIL: git not found"; exit 1; }

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
ng() { fail=$((fail + 1)); echo "FAIL: $1"; }

# pre-commit runs gitleaks if present; stub it so the suite does not depend on it.
stub="${tmp}/stub"; mkdir -p "${stub}"
printf '#!/bin/bash\nexit 0\n' > "${stub}/gitleaks"; chmod +x "${stub}/gitleaks"
export PATH="${stub}:${PATH}"

JP='日本語'   # a non-ASCII name

mkrepo() {
  local d; d=$(mktemp -d "${tmp}/r.XXXXXX")
  d=$(cd "${d}" && pwd -P)
  "${GIT}" -C "${d}" init -q -b main
  "${GIT}" -C "${d}" config user.name tester
  "${GIT}" -C "${d}" config user.email tester@example.com
  "${GIT}" -C "${d}" config commit.gpgsign false
  # Pin git's default (core.quotepath=true) so a user's global config cannot change the result.
  "${GIT}" -C "${d}" config core.quotepath true
  mkdir -p "${d}/.githooks"
  cp "${root}"/hooks/* "${d}/.githooks/"
  cp "${root}"/lib/* "${d}/.githooks/"
  chmod +x "${d}"/.githooks/*
  "${GIT}" -C "${d}" config core.hooksPath .githooks
  echo "${d}"
}
# run <dir> <script> [env...] -- output goes to ${tmp}/out (stdout+stderr merged); prints the exit code
run() {
  local d="$1" s="$2"; shift 2
  ( cd "${d}" && env "LC_ALL=${HOOK_LC}" "$@" bash ".githooks/${s}" ) >"${tmp}/out" 2>&1
  echo $?
}
has() { grep -q -- "$1" "${tmp}/out"; }
has_head() { "${GIT}" -C "$1" rev-parse -q --verify HEAD >/dev/null 2>&1; }
show() { head -n 4 "${tmp}/out"; }

echo "== 1. rflag-scan: path rules match a non-ASCII file name =="
d=$(mkrepo); mkdir -p "${d}/auth"; echo x > "${d}/auth/login.py"; "${GIT}" -C "${d}" add auth/login.py
rc=$(run "${d}" rflag-scan.sh)
if [ "${rc}" = "1" ] && has 'auth/login.py'; then ok "control: ASCII auth/login.py is R-flagged"; else ng "control broken (test bug): rc=${rc} $(show)"; fi

d=$(mkrepo); mkdir -p "${d}/auth"; echo x > "${d}/auth/${JP}.py"; "${GIT}" -C "${d}" add "auth/${JP}.py"
rc=$(run "${d}" rflag-scan.sh)
if [ "${rc}" = "1" ]; then ok "auth/${JP}.py is R-flagged (exit 1)"; else ng "auth/${JP}.py passed with no flag (rc=${rc}): $(show)"; fi
if has "auth/${JP}.py"; then ok "  output shows the raw file name (not an octal-quoted one)"; else ng "  output lacks the raw file name: $(show)"; fi

# Several staged files: names must stay separate (NUL -> newline), not be glued together so the anchor is lost.
d=$(mkrepo); mkdir -p "${d}/auth"; echo x > "${d}/aaa.txt"; echo x > "${d}/auth/${JP}.py"   # aaa.txt sorts first: glued names would lose the auth/ anchor
"${GIT}" -C "${d}" add aaa.txt "auth/${JP}.py"
rc=$(run "${d}" rflag-scan.sh)
if [ "${rc}" = "1" ] && has "auth/${JP}.py"; then ok "auth/${JP}.py is detected as its own entry among several staged files"; else ng "names glued together among several files? (rc=${rc}): $(show)"; fi

echo "== 2. sink-scan: a sink in a non-ASCII-named file is detected =="
d=$(mkrepo); echo 'from twilio.rest import Client' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" sink-scan.sh)
if [ "${rc}" = "1" ]; then ok "control: ASCII svc_ascii.py is a soft R-flag (exit 1)"; else ng "control broken (test bug): rc=${rc} $(show)"; fi

d=$(mkrepo); echo 'from twilio.rest import Client' > "${d}/svc_${JP}.py"; "${GIT}" -C "${d}" add "svc_${JP}.py"
rc=$(run "${d}" sink-scan.sh)
if [ "${rc}" = "1" ]; then ok "svc_${JP}.py is a soft R-flag (exit 1)"; else ng "svc_${JP}.py sink was missed (rc=${rc}): $(show)"; fi
if has "svc_${JP}.py"; then ok "  output shows the raw file name"; else ng "  output lacks the raw file name: $(show)"; fi

d=$(mkrepo); echo 'from twilio.rest import Client' > "${d}/demo_${JP}.py"; "${GIT}" -C "${d}" add "demo_${JP}.py"
rc=$(run "${d}" sink-scan.sh)
if [ "${rc}" = "2" ]; then ok "demo_${JP}.py is a HARD block (exit 2)"; else ng "demo_${JP}.py hard block did not fire (rc=${rc}): $(show)"; fi

# A rename plus an added sink line must still be scanned (--diff-filter keeps R).
d=$(mkrepo)
"${GIT}" -C "${d}" config --unset core.hooksPath
i=0; : > "${d}/old.py"; while [ "${i}" -lt 100 ]; do echo "line_${i} = ${i}" >> "${d}/old.py"; i=$((i + 1)); done
"${GIT}" -C "${d}" add old.py; "${GIT}" -C "${d}" commit -q -m seed
"${GIT}" -C "${d}" mv old.py "svc_${JP}.py"; echo 'from twilio.rest import Client' >> "${d}/svc_${JP}.py"
"${GIT}" -C "${d}" add -A
if "${GIT}" -C "${d}" diff --cached --name-status | grep '^R' >/dev/null; then
  rc=$(run "${d}" sink-scan.sh)
  if [ "${rc}" = "1" ]; then ok "rename to a non-ASCII name plus an added sink line is detected"; else ng "renamed non-ASCII file's sink was missed (rc=${rc}): $(show)"; fi
else ng "test bug: git did not report the change as a rename"; fi

echo "== 3. check-open-remediations: names are not read as regexes; a failed match is not a pass =="
# The memory directory is looked up under $HOME; give each case a throwaway HOME holding an open item.
mkmem() { # <repo dir> <memory body>
  local h="${tmp}/home.$$.${RANDOM}"
  local san; san=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')
  mkdir -p "${h}/.claude/projects/${san}/memory"
  printf '%s\n' "$2" > "${h}/.claude/projects/${san}/memory/m.md"
  echo "${h}"
}
d=$(mkrepo); h=$(mkmem "${d}" "- [ ] sat-guard_manual open item")
echo x > "${d}/sat-guard_manual.md"; "${GIT}" -C "${d}" add sat-guard_manual.md
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if [ "${rc}" = "1" ] && has 'sat-guard_manual'; then ok "control: an ASCII name matches its open item"; else ng "control broken (test bug): rc=${rc} $(show)"; fi

d=$(mkrepo); h=$(mkmem "${d}" "- [ ] sat-guard_${JP} open item")
echo x > "${d}/sat-guard_${JP}.md"; "${GIT}" -C "${d}" add "sat-guard_${JP}.md"
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if has 'invalid backreference'; then ng "the name's octal escapes were read as a back-reference and grep aborted: $(show)"; else ok "grep does not abort on a non-ASCII name"; fi
if [ "${rc}" = "1" ] && has "sat-guard_${JP}"; then ok "  the open item is found (exit 1, matched on the raw name)"; else ng "  the open item for a non-ASCII name was missed (rc=${rc}): $(show)"; fi

# Several staged files: names must stay separate so the keyword is not corrupted.
d=$(mkrepo); h=$(mkmem "${d}" "- [ ] sat-guard_${JP} open item")
echo x > "${d}/zzzz_other.md"; echo x > "${d}/sat-guard_${JP}.md"
"${GIT}" -C "${d}" add zzzz_other.md "sat-guard_${JP}.md"
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if [ "${rc}" = "1" ] && has "sat-guard_${JP}"; then ok "sat-guard_${JP}.md is matched as its own entry among several staged files"; else ng "names glued together among several files? (rc=${rc}): $(show)"; fi

# A name containing a back-reference shape (\1) or bracket is matched literally.
d=$(mkrepo); h=$(mkmem "${d}" '- [ ] ab\1cd[x] open item')
echo x > "${d}/"'ab\1cd[x].txt'; "${GIT}" -C "${d}" add -- 'ab\1cd[x].txt'
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if has 'invalid backreference' || has 'grep:'; then ng "a name containing \\1 / [x] was parsed as a regex: $(show)"; else ok "a name containing \\1 or [x] is not parsed as a regex"; fi
if [ "${rc}" = "1" ] && has 'ab\\1cd\[x\]'; then ok "  matched literally and detected"; else ng "  the literal match did not work (rc=${rc}): $(show)"; fi

# The flip side: an unrelated non-ASCII name must not raise a flag or a grep error.
d=$(mkrepo); h=$(mkmem "${d}" "- [ ] unrelated item qqqq")
echo x > "${d}/zzzz_${JP}.md"; "${GIT}" -C "${d}" add "zzzz_${JP}.md"
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if [ "${rc}" = "0" ] && ! has 'grep:'; then ok "an unrelated non-ASCII name raises neither a flag nor a grep error"; else ng "false positive or grep error on an unrelated name (rc=${rc}): $(show)"; fi

echo "== 4. no-live-fire-check (CI sweep): tracked non-ASCII-named files are swept =="
d=$(mkrepo); echo 'from twilio.rest import Client' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" no-live-fire-check.sh)
if [ "${rc}" = "1" ] && has 'svc_ascii.py'; then ok "control: the sweep flags an ASCII-named sink"; else ng "control broken (test bug): rc=${rc} $(show)"; fi

d=$(mkrepo); echo 'from twilio.rest import Client' > "${d}/svc_${JP}.py"; "${GIT}" -C "${d}" add "svc_${JP}.py"
rc=$(run "${d}" no-live-fire-check.sh)
if [ "${rc}" = "1" ]; then ok "the sweep flags the sink in svc_${JP}.py (exit 1)"; else ng "the sink in svc_${JP}.py passed the sweep (rc=${rc}): $(show)"; fi
if has "svc_${JP}.py"; then ok "  output shows the raw file name"; else ng "  output lacks the raw file name: $(show)"; fi

echo "== 5. sink-inventory-drift: a manifest under a non-ASCII directory counts toward the inventory =="
mkdrift() { # <directory name>
  local d; d=$(mkrepo)
  mkdir -p "${d}/$1" "${d}/.forge"
  echo '{"dependencies":{"acme-widget-sdk":"1.0.0"}}' > "${d}/$1/package.json"
  # A made-up vendor whose coverage pattern matches nothing in the sink table.
  echo 'acmewidget;;acme-widget-sdk;;zzz-never-matches-zzz;;test' > "${d}/.forge/vendors.txt"
  "${GIT}" -C "${d}" add -A
  echo "${d}"
}
d=$(mkdrift app)
rc=$(run "${d}" sink-inventory-drift.sh)
if [ "${rc}" = "1" ] && has 'acmewidget'; then ok "control: app/package.json is inventoried and the uncovered vendor is reported"; else ng "control broken (test bug): rc=${rc} $(show)"; fi

d=$(mkdrift "${JP}")
rc=$(run "${d}" sink-inventory-drift.sh)
if [ "${rc}" = "1" ] && has 'acmewidget'; then ok "${JP}/package.json is inventoried too; the uncovered vendor is reported"; else ng "${JP}/package.json was dropped from the inventory (rc=${rc}): $(show)"; fi

echo "== 6. pre-commit end to end: an R-flagged non-ASCII file does not commit without a trailer =="
d=$(mkrepo); mkdir -p "${d}/auth"; echo x > "${d}/auth/${JP}.py"; "${GIT}" -C "${d}" add "auth/${JP}.py"
( cd "${d}" && LC_ALL="${HOOK_LC}" "${GIT}" commit -q -m "change" ) >"${tmp}/out" 2>&1; rc=$?
if [ "${rc}" != "0" ] && ! has_head "${d}"; then ok "committing auth/${JP}.py without an R-Flag trailer is rejected"; else ng "auth/${JP}.py committed without a trailer (rc=${rc}): $(show)"; fi
if has 'R-Flag'; then ok "  rejection reason: the R-Flag trailer is required"; else ng "  rejected for some other reason: $(show)"; fi

echo "== 7. Unable to inspect is not a pass: when git or grep fails, stop instead of passing silently =="
# Wrappers around the real git/grep that fail only when the arguments contain FAIL_* and defer to the real tool otherwise.
real_git="$(command -v git)"; real_grep="$(command -v grep)"
gw="${tmp}/gw"; mkdir -p "${gw}"
# The wrapper bodies are written verbatim (single quotes are intended: $* / ${FAIL_*} expand when the wrapper runs).
# shellcheck disable=SC2016
printf '#!/bin/bash\ncase "$*" in *"${FAIL_GIT:-@@none@@}"*) echo "fake git failure" >&2; exit 128;; esac\nexec "%s" "$@"\n' "${real_git}" > "${gw}/git"
# shellcheck disable=SC2016
printf '#!/bin/bash\ncase "$*" in *"${FAIL_GREP:-@@none@@}"*) echo "fake grep failure" >&2; exit 2;; esac\nexec "%s" "$@"\n' "${real_grep}" > "${gw}/grep"
chmod +x "${gw}/git" "${gw}/grep"
gwenv() { echo "PATH=${gw}:${PATH}"; }

d=$(mkrepo); mkdir -p "${d}/auth"; echo x > "${d}/auth/login.py"; "${GIT}" -C "${d}" add auth/login.py
rc=$(run "${d}" rflag-scan.sh "$(gwenv)" "FAIL_GIT=--name-only")
if [ "${rc}" = "2" ] && has 'could not read the staged file list'; then ok "rflag-scan: a failed file listing is exit 2 (not a silent no-flag)"; else ng "rflag-scan swallowed the listing failure (rc=${rc}): $(show)"; fi

d=$(mkrepo); echo 'from twilio.rest import Client' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" sink-scan.sh "$(gwenv)" "FAIL_GIT=--name-only")
if [ "${rc}" = "3" ] && has 'could not read the staged file list'; then ok "sink-scan: a failed file listing is exit 3 (not a silent no-sink)"; else ng "sink-scan swallowed the listing failure (rc=${rc}): $(show)"; fi
rc=$(run "${d}" sink-scan.sh "$(gwenv)" "FAIL_GIT=:(literal)")
if [ "${rc}" = "3" ] && has 'could not read the staged diff'; then ok "sink-scan: a failed per-file diff is exit 3"; else ng "sink-scan swallowed the per-file diff failure (rc=${rc}): $(show)"; fi

d=$(mkrepo); h=$(mkmem "${d}" "- [ ] sat-guard_manual open item")
echo x > "${d}/sat-guard_manual.md"; "${GIT}" -C "${d}" add sat-guard_manual.md
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}" "$(gwenv)" "FAIL_GIT=--name-only")
if [ "${rc}" = "2" ] && has 'could not read the staged file list'; then ok "check-open-remediations: a failed file listing is exit 2"; else ng "check-open-remediations swallowed the listing failure (rc=${rc}): $(show)"; fi
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}" "$(gwenv)" "FAIL_GREP=-iF")
if [ "${rc}" = "2" ] && has 'matching failed'; then ok "check-open-remediations: a failing grep is exit 2 (not 'no related item')"; else ng "check-open-remediations swallowed the grep failure (rc=${rc}): $(show)"; fi

d=$(mkrepo); echo 'from twilio.rest import Client' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" no-live-fire-check.sh "$(gwenv)" "FAIL_GIT=ls-files")
if [ "${rc}" = "2" ] && has 'cannot run'; then ok "no-live-fire-check: a failed tracked-file listing is exit 2 (not a pass)"; else ng "no-live-fire-check swallowed the listing failure (rc=${rc}): $(show)"; fi

d=$(mkdrift app)
rc=$(run "${d}" sink-inventory-drift.sh "$(gwenv)" "FAIL_GIT=ls-files")
if [ "${rc}" = "1" ] && has 'cannot run'; then ok "sink-inventory-drift: a failed tracked-file listing is exit 1 (an empty inventory is not a pass)"; else ng "sink-inventory-drift swallowed the listing failure (rc=${rc}): $(show)"; fi

# pre-commit must refuse -- and a trailer must not be able to wave it through -- when a scan could not run.
# (git puts its own exec-path at the front of PATH when it runs a hook, which would bypass the fake `git`
# wrapper -- so for the git-failure cases pre-commit is invoked directly. A non-zero pre-commit aborts the
# commit before commit-msg runs, so no trailer can rescue it.)
d=$(mkrepo); mkdir -p "${d}/auth"; echo x > "${d}/auth/login.py"; "${GIT}" -C "${d}" add auth/login.py
rc=$(run "${d}" pre-commit "$(gwenv)" "FAIL_GIT=--name-only")
if [ "${rc}" = "1" ] && has 'R-flag scan failed to run'; then ok "pre-commit: a failed R-flag scan is refused (exit 1) instead of being treated as a flag a trailer can clear"; else ng "pre-commit let a failed R-flag scan through (rc=${rc}): $(show)"; fi
if [ ! -f "${d}/.git/FORGE_RFLAG_DETECTED" ]; then ok "  no trailer-clearable R-flag marker was left behind"; else ng "  a trailer-clearable marker was left for a scan that could not run"; fi

d=$(mkrepo); echo 'from twilio.rest import Client' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" pre-commit "$(gwenv)" "FAIL_GIT=:(literal)")
if [ "${rc}" = "1" ] && has 'sink scan failed to run'; then ok "pre-commit: a failed sink scan is refused (exit 1)"; else ng "pre-commit let a failed sink scan through (rc=${rc}): $(show)"; fi
if [ ! -f "${d}/.git/FORGE_RFLAG_DETECTED" ]; then ok "  no trailer-clearable R-flag marker was left behind"; else ng "  a trailer-clearable marker was left for a scan that could not run"; fi

d=$(mkrepo); h=$(mkmem "${d}" "- [ ] sat-guard_manual open item")
echo x > "${d}/sat-guard_manual.md"; "${GIT}" -C "${d}" add sat-guard_manual.md
( cd "${d}" && env "LC_ALL=${HOOK_LC}" "HOME=${h}" "$(gwenv)" "FAIL_GREP=-iF" "${GIT}" commit -q -m "change

Remediation-Check: unrelated (trailer must not rescue a check that could not run)" ) >"${tmp}/out" 2>&1; rc=$?
if [ "${rc}" != "0" ] && ! has_head "${d}"; then ok "pre-commit: a failed remediation check rejects the commit even with a trailer"; else ng "pre-commit let a failed remediation check through (rc=${rc}): $(show)"; fi
if has 'open-remediation check failed to run'; then ok "  rejection reason: the open-remediation check could not run"; else ng "  rejected for some other reason: $(show)"; fi

echo "== 8. Other ways a scan can be unable to run must not read as 'nothing found' (found by the Stage-0 review) =="
# 8a. A missing sink table is exit 3 (never 1): exit 1 is a soft R-flag that an R-Flag trailer can clear.
d=$(mkrepo); rm -f "${d}/.githooks/sinks-default.txt" "${d}/.githooks/sink-hosts.txt"
echo 'from twilio.rest import Client' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" sink-scan.sh)
if [ "${rc}" = "3" ] && has 'cannot run'; then ok "sink-scan: no pattern table is exit 3, not a trailer-clearable exit 1"; else ng "sink-scan with no pattern table (rc=${rc}): $(show)"; fi
( cd "${d}" && LC_ALL="${HOOK_LC}" "${GIT}" commit -q -m "change

R-Flag: no (trailer must not rescue a scan that could not run)" ) >"${tmp}/out" 2>&1; rc=$?
if [ "${rc}" != "0" ] && ! has_head "${d}"; then ok "pre-commit: a damaged install is refused even with an R-Flag trailer"; else ng "a damaged install committed with a trailer (rc=${rc}): $(show)"; fi

# 8b. A missing R-flag rules table must stop the scan (exit 2) instead of flagging nothing.
d=$(mkrepo); rm -f "${d}/.githooks/rflag-rules-default.txt"
mkdir -p "${d}/auth"; echo x > "${d}/auth/login.py"; "${GIT}" -C "${d}" add auth/login.py
rc=$(run "${d}" rflag-scan.sh)
if [ "${rc}" = "2" ] && has 'rules table'; then ok "rflag-scan: no rules table is exit 2 (not a silent no-flag)"; else ng "rflag-scan with no rules table (rc=${rc}): $(show)"; fi

# 8c. A broken regex in an adopter's own table must stop the scan, not silently switch the rule off.
d=$(mkrepo); mkdir -p "${d}/.forge"; echo '(unbalanced' > "${d}/.forge/sinks.txt"
echo 'from twilio.rest import Client' > "${d}/demo_x.py"; "${GIT}" -C "${d}" add demo_x.py
rc=$(run "${d}" sink-scan.sh)
if [ "${rc}" = "3" ] && has 'not a valid regular expression'; then ok "sink-scan: an invalid regex in .forge/sinks.txt is exit 3 (the demo hard block is not silently lost)"; else ng "sink-scan swallowed an invalid sink pattern (rc=${rc}): $(show)"; fi

d=$(mkrepo); mkdir -p "${d}/.forge" "${d}/auth"; echo 'PATH:(unbalanced' > "${d}/.forge/rflag-rules.txt"
echo x > "${d}/auth/login.py"; "${GIT}" -C "${d}" add auth/login.py
rc=$(run "${d}" rflag-scan.sh)
if [ "${rc}" = "2" ] && has 'not a valid regular expression'; then ok "rflag-scan: an invalid regex in .forge/rflag-rules.txt is exit 2"; else ng "rflag-scan swallowed an invalid rule (rc=${rc}): $(show)"; fi

# 8d. The staged diff body is read separately from the file list; its failure must not read as 'no added lines'.
d=$(mkrepo); mkdir -p "${d}/auth"; echo x > "${d}/auth/login.py"; "${GIT}" -C "${d}" add auth/login.py
rc=$(run "${d}" rflag-scan.sh "$(gwenv)" "FAIL_GIT=--cached -- .")
if [ "${rc}" = "2" ] && has 'could not read the staged diff'; then ok "rflag-scan: a failed diff read is exit 2 (CONTENT rules cannot silently match nothing)"; else ng "rflag-scan swallowed the diff failure (rc=${rc}): $(show)"; fi

# 8e. A file name containing a newline cannot be classified by line-oriented grep: refuse, do not guess.
d=$(mkrepo); nl_name=$'demo_x\ntest_y.py'
echo 'from twilio.rest import Client' > "${d}/${nl_name}"; "${GIT}" -C "${d}" add -- "${nl_name}"
rc=$(run "${d}" sink-scan.sh)
if [ "${rc}" = "3" ] && has 'newline'; then ok "sink-scan: a staged name containing a newline is exit 3 (it cannot be classified as a test file by accident)"; else ng "sink-scan classified a newline name (rc=${rc}): $(show)"; fi

# 8f. An unusable temporary directory is reported as such (and still refused), not as a mystery failure.
d=$(mkrepo); echo 'from twilio.rest import Client' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" sink-scan.sh "TMPDIR=${tmp}/does-not-exist")
if [ "${rc}" = "3" ] && has 'TMPDIR'; then ok "sink-scan: an unusable TMPDIR is exit 3 and the message names TMPDIR"; else ng "sink-scan with an unusable TMPDIR (rc=${rc}): $(show)"; fi
rc=$(run "${d}" no-live-fire-check.sh "TMPDIR=${tmp}/does-not-exist")
if [ "${rc}" = "2" ] && has 'TMPDIR'; then ok "no-live-fire-check: an unusable TMPDIR is exit 2 and the message names TMPDIR"; else ng "no-live-fire-check with an unusable TMPDIR (rc=${rc}): $(show)"; fi
d=$(mkdrift app)
rc=$(run "${d}" sink-inventory-drift.sh "TMPDIR=${tmp}/does-not-exist")
if [ "${rc}" = "1" ] && has 'TMPDIR'; then ok "sink-inventory-drift: an unusable TMPDIR is exit 1 and the message names TMPDIR"; else ng "sink-inventory-drift with an unusable TMPDIR (rc=${rc}): $(show)"; fi

echo
echo "passed ${pass} / failed ${fail}"
[ "${fail}" -eq 0 ]

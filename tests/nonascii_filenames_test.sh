#!/bin/bash
# SinkSeal: non-ASCII / special-character file-name regression test.
#
# Background: by default (core.quotepath=true) git prints a non-ASCII file name
# wrapped in double quotes with octal escapes, e.g.
#   "docs/\344\273\225\346\247\230_v051.md"
# Hooks that took `git diff --cached --name-only` / `git ls-files` output as-is
# therefore saw a quoted, escaped string instead of the real name, and:
#   - check-open-remediations: the "\344" inside the keyword was read by grep as a
#     regex back-reference ("invalid backreference number"); the `|| true` that
#     followed swallowed the failure, so the open-item cross-check silently did
#     nothing for any non-ASCII file name (a check that could not run was
#     treated as a pass);
#   - rflag-scan: the quoted name starts with '"', so anchored PATH rules such
#     as (^|/)auth never matched;
#   - sink-scan: `git diff -- "$f"` with the quoted name matched no path, so the
#     file's sinks were skipped;
#   - no-live-fire-check: "$repo_root/$f" was a path that does not exist and the
#     file was skipped;
#   - sink-inventory-drift: a manifest under a non-ASCII-named directory was
#     dropped from the dependency inventory.
#
# Rejection cases are asserted on the exit code AND on the wording of the output
# (a test that merely sees a non-zero exit can pass for the wrong reason).
#
# The hooks are run under BOTH the C locale and a UTF-8 locale (where available):
# a test pinned to C alone would miss bugs that only show under the user's real
# locale. Usage: tests/nonascii_filenames_test.sh   (exit 0 = all passed)

set -u
if [ -z "${HOOK_LC:-}" ]; then
  utf8=""
  for c in $(locale -a 2>/dev/null | grep -iE '^(en_US|C|ja_JP)\.utf-?8$'); do utf8="${c}"; break; done
  rc=0
  for lc in C ${utf8}; do
    echo "##### hook locale: ${lc}"
    HOOK_LC="${lc}" bash "${BASH_SOURCE[0]}" || rc=1
  done
  [ -n "${utf8}" ] || echo "NOTE: no UTF-8 locale on this machine; ran under C only (UTF-8-specific bugs cannot be detected)."
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

# A no-op gitleaks so pre-commit's secret scan neither warns nor needs the real tool.
stub="${tmp}/stub"; mkdir -p "${stub}"
printf '#!/bin/bash\nexit 0\n' > "${stub}/gitleaks"; chmod +x "${stub}/gitleaks"
export PATH="${stub}:${PATH}"

JP='日本語'   # a non-ASCII name component

mkrepo() {
  local d; d=$(mktemp -d "${tmp}/r.XXXXXX")
  d=$(cd "${d}" && pwd -P)
  "${GIT}" -C "${d}" init -q -b main
  "${GIT}" -C "${d}" config user.name tester
  "${GIT}" -C "${d}" config user.email tester@example.com
  "${GIT}" -C "${d}" config commit.gpgsign false
  # Pin core.quotepath to git's default (true) so a user's global config cannot hide the defect.
  "${GIT}" -C "${d}" config core.quotepath true
  mkdir -p "${d}/.githooks"
  cp "${root}"/hooks/* "${d}/.githooks/"
  cp "${root}"/lib/* "${d}/.githooks/"
  chmod +x "${d}"/.githooks/*
  "${GIT}" -C "${d}" config core.hooksPath .githooks
  echo "${d}"
}
# run <dir> <script> [ENV=val...] -- output (stdout+stderr) goes to ${tmp}/out, prints the exit code.
# The hook is executed through its shebang (/bin/bash), as git would run it.
run() {
  local d="$1" s="$2"; shift 2
  ( cd "${d}" && env "LC_ALL=${HOOK_LC}" "$@" "./.githooks/${s}" ) >"${tmp}/out" 2>&1 </dev/null
  echo $?
}
has() { grep -q -- "$1" "${tmp}/out"; }
has_head() { "${GIT}" -C "$1" rev-parse -q --verify HEAD >/dev/null 2>&1; }
show() { head -n 4 "${tmp}/out"; }

# Memory notes live under HOME; give each case a throwaway HOME whose memory dir
# matches how the hook derives it (every non-alphanumeric character becomes "-").
mkmem() { # <repo dir> <memory text>
  local h="${tmp}/home.$$.${RANDOM}"
  local san; san=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')
  mkdir -p "${h}/.claude/projects/${san}/memory"
  printf '%s\n' "$2" > "${h}/.claude/projects/${san}/memory/m.md"
  echo "${h}"
}

echo "== 1. check-open-remediations: names are matched as literal strings; a failed check is not a pass =="
d=$(mkrepo); h=$(mkmem "${d}" "- [ ] sat-guard_manual still open")
echo x > "${d}/sat-guard_manual.md"; "${GIT}" -C "${d}" add sat-guard_manual.md
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if [ "${rc}" = "1" ] && has 'sat-guard_manual'; then ok "control: an ASCII-only name hits the open item"; else ng "control failed (test defect): rc=${rc} $(show)"; fi

d=$(mkrepo); h=$(mkmem "${d}" "- [ ] sat-guard_${JP} still open")
echo x > "${d}/sat-guard_${JP}.md"; "${GIT}" -C "${d}" add "sat-guard_${JP}.md"
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if has 'invalid backreference'; then ng "the octal-escaped name was read as a regex back-reference: $(show)"; else ok "a non-ASCII name does not make grep die"; fi
if [ "${rc}" = "1" ] && has "sat-guard_${JP}"; then ok "  a non-ASCII-only name hits the open item (exit 1, matched by its real basename)"; else ng "  non-ASCII-only name was missed (rc=${rc}): $(show)"; fi

# Several staged files: names must stay separate (NUL -> newline), not be glued together.
d=$(mkrepo); h=$(mkmem "${d}" "- [ ] sat-guard_${JP} still open
- [ ] zzzz_other also open")
mkdir -p "${d}/docs"; echo x > "${d}/zzzz_other.md"; echo x > "${d}/docs/sat-guard_${JP}.md"
"${GIT}" -C "${d}" add zzzz_other.md "docs/sat-guard_${JP}.md"
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if [ "${rc}" = "1" ] && has "sat-guard_${JP}" && has 'zzzz_other'; then ok "several files, one in a subdirectory (ASCII + non-ASCII): each is matched by its own basename"; else ng "several files: names were glued or one was missed (rc=${rc}): $(cat "${tmp}/out" | head -n 6)"; fi

# A name containing a back-reference shape, a bracket and a star is matched literally.
d=$(mkrepo); h=$(mkmem "${d}" '- [ ] ab\1cd[x] still open')
echo x > "${d}/"'ab\1cd[x].txt'; "${GIT}" -C "${d}" add -- 'ab\1cd[x].txt'
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if has 'invalid backreference' || has 'grep:'; then ng "the name \\1[x] was reinterpreted as a regex: $(show)"; else ok "a name containing \\1 and [x] is not reinterpreted as a regex"; fi
if [ "${rc}" = "1" ] && has 'ab\\1cd\[x\]'; then ok "  it is matched literally and hits the open item"; else ng "  literal match failed (rc=${rc}): $(show)"; fi

d=$(mkrepo); h=$(mkmem "${d}" '- [ ] star*name still open')
echo x > "${d}/"'star*name.txt'; "${GIT}" -C "${d}" add -- 'star*name.txt'
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if [ "${rc}" = "1" ] && has 'star\*name'; then ok "a name containing '*' is matched literally (a regex reading would miss it)"; else ng "'*' in a name was not matched literally (rc=${rc}): $(show)"; fi

# A name that starts with "-" is not taken for a grep option.
d=$(mkrepo); h=$(mkmem "${d}" '- [ ] -dash_name still open')
echo x > "${d}/"'-dash_name.md'; "${GIT}" -C "${d}" add -- '-dash_name.md'
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if [ "${rc}" = "1" ] && has 'dash_name'; then ok "a name starting with '-' is matched as a name, not parsed as a grep option"; else ng "leading '-' in a name broke the lookup (rc=${rc}): $(show)"; fi

# Matching is case-insensitive (names are lower-cased; the note may not be).
d=$(mkrepo); h=$(mkmem "${d}" '- [ ] MIXEDCASE_NAME still open')
echo x > "${d}/MixedCase_Name.md"; "${GIT}" -C "${d}" add MixedCase_Name.md
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if [ "${rc}" = "1" ] && has 'MIXEDCASE_NAME'; then ok "matching is case-insensitive"; else ng "case-insensitive match failed (rc=${rc}): $(show)"; fi

# Names shorter than 4 characters stay out of the keyword set (noise filter).
d=$(mkrepo); h=$(mkmem "${d}" '- [ ] abc still open')
echo x > "${d}/abc.md"; "${GIT}" -C "${d}" add abc.md
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if [ "${rc}" = "0" ]; then ok "a name under 4 characters is not used as a keyword"; else ng "short-name noise filter lost (rc=${rc}): $(show)"; fi

# The flip side: an unrelated non-ASCII name must not raise a flag or an error.
d=$(mkrepo); h=$(mkmem "${d}" "- [ ] unrelated item qqqq")
echo x > "${d}/zzzz_${JP}.md"; "${GIT}" -C "${d}" add "zzzz_${JP}.md"
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if [ "${rc}" = "0" ] && ! has 'grep:'; then ok "an unrelated non-ASCII name raises no flag and no grep error"; else ng "unrelated name: false positive or error (rc=${rc}): $(show)"; fi

# Opt-out branches that were never in scope for the check still pass quietly.
d=$(mkrepo); h="${tmp}/home.nomem.${RANDOM}"; mkdir -p "${h}"
echo x > "${d}/sat-guard_${JP}.md"; "${GIT}" -C "${d}" add "sat-guard_${JP}.md"
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if [ "${rc}" = "0" ]; then ok "no memory directory at all: exits 0 (the check is opt-in)"; else ng "no memory directory: rc=${rc} $(show)"; fi

# An empty memory directory (no *.md) is also "nothing to check". Stdin carries a line that WOULD match: a hook that
# fell through to `grep` with no file operands would read stdin and report a hit.
d=$(mkrepo); h=$(mkmem "${d}" "- [ ] sat-guard_manual still open")
san=$(printf '%s' "${d}" | sed 's/[^A-Za-z0-9]/-/g'); rm -f "${h}/.claude/projects/${san}/memory/m.md"
echo x > "${d}/sat-guard_manual.md"; "${GIT}" -C "${d}" add sat-guard_manual.md
( cd "${d}" && printf -- '- [ ] sat-guard_manual from stdin\n' | env "LC_ALL=${HOOK_LC}" "HOME=${h}" ./.githooks/check-open-remediations.sh ) >"${tmp}/out" 2>&1; rc=$?
if [ "${rc}" = "0" ] && ! has 'unbound'; then ok "an empty memory directory (no *.md): exits 0, never reads stdin, and trips no unbound-variable error"; else ng "empty memory directory: rc=${rc} $(show)"; fi

# Nothing staged: nothing to check.
d=$(mkrepo); h=$(mkmem "${d}" "- [ ] sat-guard_manual still open")
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if [ "${rc}" = "0" ]; then ok "nothing staged: exits 0"; else ng "nothing staged: rc=${rc} $(show)"; fi

echo "== 2. a check that cannot run is refused (exit 2) with the reason on stderr, not passed =="
# Wrappers around the real git / grep that fail only when the argument list contains FAIL_GIT / FAIL_GREP.
real_git="$(command -v git)"; real_grep="$(command -v grep)"
gw="${tmp}/gw"; mkdir -p "${gw}"
# shellcheck disable=SC2016 # the wrapper script body is meant to be written out unexpanded
printf '#!/bin/bash\ncase "$*" in *"${FAIL_GIT:-@@none@@}"*) echo "fake git failure" >&2; exit 128;; esac\nexec "%s" "$@"\n' "${real_git}" > "${gw}/git"
# shellcheck disable=SC2016 # same: unexpanded on purpose
printf '#!/bin/bash\ncase "$*" in *"${FAIL_GREP:-@@none@@}"*) echo "fake grep failure" >&2; exit 2;; esac\nexec "%s" "$@"\n' "${real_grep}" > "${gw}/grep"
chmod +x "${gw}/git" "${gw}/grep"
gwenv() { echo "PATH=${gw}:${PATH}"; }

d=$(mkrepo); h=$(mkmem "${d}" "- [ ] sat-guard_manual still open")
echo x > "${d}/sat-guard_manual.md"; "${GIT}" -C "${d}" add sat-guard_manual.md
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}" "$(gwenv)" "FAIL_GIT=--name-only")
if [ "${rc}" = "2" ] && has 'could not list the staged files'; then ok "listing the staged files fails -> exit 2, reason names the failed step"; else ng "list failure was swallowed or mis-reported (rc=${rc}): $(show)"; fi
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}" "$(gwenv)" "FAIL_GREP=-inE")
if [ "${rc}" = "2" ] && has 'could not read the memory notes'; then ok "reading the memory notes fails -> exit 2, reason names the failed step"; else ng "memory read failure was swallowed or mis-reported (rc=${rc}): $(show)"; fi
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}" "$(gwenv)" "FAIL_GREP=-iF")
if [ "${rc}" = "2" ] && has 'keyword lookup failed' && has 'sat-guard_manual'; then ok "the keyword grep fails (exit 2) -> exit 2, reason names the step and the keyword"; else ng "keyword grep failure was swallowed (rc=${rc}): $(show)"; fi

# pre-commit must refuse on that exit code, not accept a trailer for it.
( cd "${d}" && env "LC_ALL=${HOOK_LC}" "HOME=${h}" "$(gwenv)" "FAIL_GREP=-iF" "${GIT}" commit -q -m "change

Remediation-Check: unrelated (trailer must not rescue a check that never ran)" ) >"${tmp}/out" 2>&1; rc=$?
if [ "${rc}" != "0" ] && ! has_head "${d}"; then ok "pre-commit refuses the commit when the cross-check could not run"; else ng "pre-commit let a never-run check through (rc=${rc}): $(show)"; fi
if has 'failed to run' && has 'keyword lookup failed'; then ok "  the refusal names the cause (pre-commit message + the hook's own reason)"; else ng "  the refusal reason is missing: $(show)"; fi

echo "== 3. rflag-scan: a non-ASCII name still meets the path rules =="
d=$(mkrepo); mkdir -p "${d}/auth"; echo x > "${d}/auth/login.py"; "${GIT}" -C "${d}" add auth/login.py
rc=$(run "${d}" rflag-scan.sh)
if [ "${rc}" = "1" ] && has 'auth'; then ok "control: auth/login.py is flagged"; else ng "control failed (test defect): rc=${rc} $(show)"; fi
d=$(mkrepo); mkdir -p "${d}/auth"; echo x > "${d}/auth/${JP}.py"; "${GIT}" -C "${d}" add "auth/${JP}.py"
rc=$(run "${d}" rflag-scan.sh)
if [ "${rc}" = "1" ]; then ok "auth/${JP}.py is flagged (exit 1)"; else ng "auth/${JP}.py passed without a flag (rc=${rc}): $(show)"; fi
d=$(mkrepo); mkdir -p "${d}/auth"; echo x > "${d}/aaa.txt"; echo x > "${d}/auth/${JP}.py"
"${GIT}" -C "${d}" add aaa.txt "auth/${JP}.py"
rc=$(run "${d}" rflag-scan.sh)
if [ "${rc}" = "1" ] && has '(\^|/)auth'; then ok "several files: auth/${JP}.py is flagged as its own name (anchor intact)"; else ng "several files: names were glued (rc=${rc}): $(show)"; fi
d=$(mkrepo); mkdir -p "${d}/auth"; echo x > "${d}/auth/login.py"; "${GIT}" -C "${d}" add auth/login.py
rc=$(run "${d}" rflag-scan.sh "$(gwenv)" "FAIL_GIT=--name-only")
if [ "${rc}" = "2" ] && has 'could not list the staged files'; then ok "rflag-scan: listing failure -> exit 2 (not 'no flag')"; else ng "rflag-scan: listing failure swallowed (rc=${rc}): $(show)"; fi
# pre-commit is run directly here: `git commit` puts git's own exec dir first on the hook's PATH, which would bypass the git wrapper.
rc=$(run "${d}" pre-commit "$(gwenv)" "FAIL_GIT=--name-only")
if [ "${rc}" = "1" ] && has 'R-flag scan failed to run' && has 'could not list the staged files'; then ok "pre-commit refuses (exit 1) when the R-flag scan could not run, naming both causes (no trailer path)"; else ng "pre-commit let a never-run R-flag scan through (rc=${rc}): $(show)"; fi

echo "== 4. sink-scan: a non-ASCII name still has its sinks scanned =="
d=$(mkrepo); echo 'twilio_service.send("hi")' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" sink-scan.sh)
if [ "${rc}" = "1" ] && has 'svc_ascii.py'; then ok "control: ASCII svc_ascii.py is a soft R-flag (exit 1)"; else ng "control failed (test defect): rc=${rc} $(show)"; fi
d=$(mkrepo); echo 'twilio_service.send("hi")' > "${d}/svc_${JP}.py"; "${GIT}" -C "${d}" add "svc_${JP}.py"
rc=$(run "${d}" sink-scan.sh)
if [ "${rc}" = "1" ] && has "svc_${JP}.py"; then ok "svc_${JP}.py is a soft R-flag (exit 1, real name in the output)"; else ng "svc_${JP}.py's sink was missed (rc=${rc}): $(show)"; fi
d=$(mkrepo); echo 'twilio_service.send("hi")' > "${d}/demo_${JP}.py"; "${GIT}" -C "${d}" add "demo_${JP}.py"
rc=$(run "${d}" sink-scan.sh)
if [ "${rc}" = "2" ] && has "demo_${JP}.py"; then ok "demo_${JP}.py is hard-blocked (exit 2)"; else ng "demo_${JP}.py hard block did not fire (rc=${rc}): $(show)"; fi
# rename + added sink line: the rename must not drop out of the scan.
d=$(mkrepo)
"${GIT}" -C "${d}" config --unset core.hooksPath
i=0; : > "${d}/old.py"; while [ "${i}" -lt 100 ]; do echo "line_${i} = ${i}" >> "${d}/old.py"; i=$((i + 1)); done
"${GIT}" -C "${d}" add old.py; "${GIT}" -C "${d}" commit -q -m seed
"${GIT}" -C "${d}" mv old.py "svc_${JP}.py"; echo 'twilio_service.send("hi")' >> "${d}/svc_${JP}.py"
"${GIT}" -C "${d}" add -A
if "${GIT}" -C "${d}" diff --cached --name-status | grep '^R' >/dev/null; then
  rc=$(run "${d}" sink-scan.sh)
  if [ "${rc}" = "1" ]; then ok "a rename that adds a sink line is also detected"; else ng "renamed non-ASCII file's sink was missed (rc=${rc}): $(show)"; fi
else ng "test defect: git did not report a rename"; fi
d=$(mkrepo); echo 'twilio_service.send("hi")' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" sink-scan.sh "$(gwenv)" "FAIL_GIT=--name-only")
if [ "${rc}" = "3" ] && has 'could not list the staged files'; then ok "sink-scan: listing failure -> exit 3 (not 'no sink')"; else ng "sink-scan: listing failure swallowed (rc=${rc}): $(show)"; fi
rc=$(run "${d}" sink-scan.sh "$(gwenv)" "FAIL_GIT=:(literal)")
if [ "${rc}" = "3" ] && has 'could not fetch the diff of svc_ascii.py'; then ok "sink-scan: per-file diff failure -> exit 3, names the file"; else ng "sink-scan: diff failure swallowed (rc=${rc}): $(show)"; fi
rc=$(run "${d}" pre-commit "$(gwenv)" "FAIL_GIT=:(literal)")
if [ "${rc}" = "1" ] && has 'sink scan failed to run' && has 'could not fetch the diff'; then ok "pre-commit refuses (exit 1) when the sink scan could not run, naming both causes (no trailer path)"; else ng "pre-commit let a never-run sink scan through (rc=${rc}): $(show)"; fi

echo "== 5. no-live-fire-check (CI sweep): tracked non-ASCII-named files are scanned =="
d=$(mkrepo); echo 'twilio_service.send("hi")' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" no-live-fire-check.sh)
if [ "${rc}" = "1" ] && has 'svc_ascii.py'; then ok "control: an ASCII sink is reported by the sweep"; else ng "control failed (test defect): rc=${rc} $(show)"; fi
d=$(mkrepo); echo 'twilio_service.send("hi")' > "${d}/svc_${JP}.py"; "${GIT}" -C "${d}" add "svc_${JP}.py"
rc=$(run "${d}" no-live-fire-check.sh)
if [ "${rc}" = "1" ] && has "svc_${JP}.py"; then ok "svc_${JP}.py's sink is reported by the sweep (exit 1, real name in the output)"; else ng "svc_${JP}.py slipped through the sweep (rc=${rc}): $(show)"; fi
d=$(mkrepo); echo 'twilio_service.send("hi")' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" no-live-fire-check.sh "$(gwenv)" "FAIL_GIT=ls-files")
if [ "${rc}" = "2" ] && has 'could not list the tracked files'; then ok "no-live-fire-check: listing failure -> exit 2 (not a pass)"; else ng "no-live-fire-check: listing failure swallowed (rc=${rc}): $(show)"; fi

echo "== 6. sink-inventory-drift: a manifest under a non-ASCII-named directory counts as inventory =="
mkdrift() { # <dir name>
  local dd; dd=$(mkrepo)
  mkdir -p "${dd}/$1" "${dd}/.forge"
  echo '{"dependencies":{"acme-widget-sdk":"1.0.0"}}' > "${dd}/$1/package.json"
  # A made-up vendor that no sink pattern covers (coverage field matches nothing).
  echo 'acmewidget;;acme-widget-sdk;;zzz-never-matches-zzz;;test' > "${dd}/.forge/vendors.txt"
  "${GIT}" -C "${dd}" add -A
  echo "${dd}"
}
d=$(mkdrift app)
rc=$(run "${d}" sink-inventory-drift.sh)
if [ "${rc}" = "1" ] && has 'acmewidget'; then ok "control: app/package.json is inventoried and the uncovered vendor is reported"; else ng "control failed (test defect): rc=${rc} $(show)"; fi
d=$(mkdrift "${JP}")
rc=$(run "${d}" sink-inventory-drift.sh)
if [ "${rc}" = "1" ] && has 'acmewidget'; then ok "${JP}/package.json is inventoried too (uncovered vendor reported)"; else ng "${JP}/package.json was dropped from the inventory (rc=${rc}): $(show)"; fi
d=$(mkdrift app)
rc=$(run "${d}" sink-inventory-drift.sh "$(gwenv)" "FAIL_GIT=ls-files")
if [ "${rc}" = "1" ] && has 'could not list the tracked files'; then ok "sink-inventory-drift: listing failure -> exit 1 (an empty inventory is not a pass)"; else ng "sink-inventory-drift: listing failure swallowed (rc=${rc}): $(show)"; fi

echo "== 6b. an unusable temp directory is refused too (the file list is staged through a temp file) =="
d=$(mkrepo); echo 'twilio_service.send("hi")' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" sink-scan.sh "TMPDIR=${tmp}/no-such-dir")
if [ "${rc}" = "3" ]; then ok "sink-scan: no usable temp directory -> exit 3"; else ng "sink-scan: temp failure passed or mis-coded (rc=${rc}): $(show)"; fi
rc=$(run "${d}" no-live-fire-check.sh "TMPDIR=${tmp}/no-such-dir")
if [ "${rc}" = "2" ]; then ok "no-live-fire-check: no usable temp directory -> exit 2"; else ng "no-live-fire-check: temp failure passed or mis-coded (rc=${rc}): $(show)"; fi
d=$(mkdrift app)
rc=$(run "${d}" sink-inventory-drift.sh "TMPDIR=${tmp}/no-such-dir")
if [ "${rc}" = "1" ] && ! has 'acmewidget'; then ok "sink-inventory-drift: no usable temp directory -> exit 1 (stopped before reading any inventory)"; else ng "sink-inventory-drift: temp failure passed or mis-coded (rc=${rc}): $(show)"; fi

echo "== 6c. missing or invalid pattern tables are refused, not read as 'nothing to flag' =="
# A hook copied alone into iso/ has no pattern tables next to it (and no ../lib), as in a broken install.
mkiso() { # <repo dir> <hook script> [extra file to copy into iso/]
  mkdir -p "$1/iso"; cp "$1/.githooks/$2" "$1/iso/$2"; [ -n "${3:-}" ] && cp "$1/.githooks/$3" "$1/iso/$3"
  return 0
}
d=$(mkrepo); mkiso "${d}" sink-scan.sh
rc=$(run "${d}" ../iso/sink-scan.sh)
if [ "${rc}" = "3" ] && has 'cannot run' && has 'no sink pattern table'; then ok "sink-scan: no pattern table -> exit 3 (could not run) and says why"; else ng "sink-scan: missing table not refused (rc=${rc}): $(show)"; fi
# pre-commit must refuse on it too (exit 1 used to be read as a soft R-flag that a trailer could wave through).
cp "${d}/.githooks/pre-commit" "${d}/iso/pre-commit"; cp "${d}/.githooks/rflag-scan.sh" "${d}/.githooks/rflag-rules-default.txt" "${d}/iso/"; cp "${d}/.githooks/check-open-remediations.sh" "${d}/iso/"
echo 'twilio_service.send("hi")' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" ../iso/pre-commit)
if [ "${rc}" = "1" ] && has 'sink scan failed to run'; then ok "pre-commit: a sink scan with no pattern table is refused, not treated as a soft R-flag"; else ng "pre-commit let a table-less sink scan through (rc=${rc}): $(show)"; fi
d=$(mkrepo); mkiso "${d}" no-live-fire-check.sh
rc=$(run "${d}" ../iso/no-live-fire-check.sh)
if [ "${rc}" = "1" ] && has 'cannot run' && has 'pattern table not found'; then ok "no-live-fire-check: no pattern table -> refuses (exit 1) and says why"; else ng "no-live-fire-check: missing table not refused (rc=${rc}): $(show)"; fi
d=$(mkrepo); mkdir -p "${d}/.forge"; printf '(unclosed\n' > "${d}/.forge/sinks.txt"
rc=$(run "${d}" no-live-fire-check.sh)
if [ "${rc}" = "1" ] && has 'invalid regex'; then ok "no-live-fire-check: an invalid regex in the table -> refuses (exit 1) and says why"; else ng "no-live-fire-check: invalid regex not refused (rc=${rc}): $(show)"; fi
d=$(mkrepo); mkiso "${d}" sink-inventory-drift.sh
rc=$(run "${d}" ../iso/sink-inventory-drift.sh)
if [ "${rc}" = "1" ] && has 'cannot run' && has 'vendor table not found'; then ok "sink-inventory-drift: no vendor table -> refuses (exit 1) and says why"; else ng "sink-inventory-drift: missing vendor table not refused (rc=${rc}): $(show)"; fi
d=$(mkrepo); mkiso "${d}" sink-inventory-drift.sh live-fire-vendors.txt
rc=$(run "${d}" ../iso/sink-inventory-drift.sh)
if [ "${rc}" = "1" ] && has 'cannot run' && has 'sink pattern table not found'; then ok "sink-inventory-drift: vendor table but no sink table -> refuses (exit 1) and says why"; else ng "sink-inventory-drift: missing sink table not refused (rc=${rc}): $(show)"; fi

# sink-scan with an invalid regex in the pattern table (no-live-fire-check already refused this; sink-scan silently passed).
d=$(mkrepo); mkdir -p "${d}/.forge"; printf '(unclosed\n' > "${d}/.forge/sinks.txt"
echo 'twilio_service.send("hi")' > "${d}/svc_ascii.py"; "${GIT}" -C "${d}" add svc_ascii.py
rc=$(run "${d}" sink-scan.sh)
if [ "${rc}" = "3" ] && has 'invalid regex' && has 'cannot run'; then ok "sink-scan: an invalid regex in the pattern table -> exit 3, says why (was: silent pass)"; else ng "sink-scan: invalid table regex swallowed (rc=${rc}): $(show)"; fi
rc=$(run "${d}" pre-commit)
if [ "${rc}" = "1" ] && has 'sink scan failed to run'; then ok "pre-commit refuses the commit in that case"; else ng "pre-commit let it through (rc=${rc}): $(show)"; fi

echo "== 7. pre-commit end to end: a non-ASCII R-flag file cannot be committed without the trailer =="
d=$(mkrepo); mkdir -p "${d}/auth"; echo x > "${d}/auth/${JP}.py"; "${GIT}" -C "${d}" add "auth/${JP}.py"
( cd "${d}" && LC_ALL="${HOOK_LC}" "${GIT}" commit -q -m "change" ) >"${tmp}/out" 2>&1; rc=$?
if [ "${rc}" != "0" ] && ! has_head "${d}"; then ok "auth/${JP}.py without an R-Flag trailer is refused"; else ng "auth/${JP}.py went through without a trailer (rc=${rc}): $(show)"; fi
if has 'R-Flag'; then ok "  the refusal is about the R-Flag trailer"; else ng "  the refusal is for some other reason: $(show)"; fi
( cd "${d}" && LC_ALL="${HOOK_LC}" "${GIT}" commit -q -m "change

R-Flag: yes" ) >"${tmp}/out" 2>&1; rc=$?
if [ "${rc}" = "0" ] && has_head "${d}"; then ok "  with 'R-Flag: yes' it is accepted"; else ng "  the trailer did not unblock the commit (rc=${rc}): $(show)"; fi

echo "== 8. no silent miss on large inputs (grep -q + pipefail SIGPIPE), and no silent skip of a broken rule =="
# A sink on the first line followed by ~300KB: grep -q would stop early and the writer die of SIGPIPE, which pipefail
# turned into "no match" (measured before the fix: exit 0).
d=$(mkrepo)
{ echo 'twilio_service.send("hi")'; head -c 300000 /dev/zero | tr '\0' 'x' | fold -w 80; } > "${d}/big_svc.py"
"${GIT}" -C "${d}" add big_svc.py
rc=$(run "${d}" sink-scan.sh)
if [ "${rc}" = "1" ] && has 'big_svc.py'; then ok "sink-scan: a sink on line 1 of a ~300KB file is still detected"; else ng "sink-scan: large-file sink missed (rc=${rc}): $(show)"; fi

d=$(mkrepo); mkdir -p "${d}/app" "${d}/.forge"
{ echo '{"dependencies":{"acme-widget-sdk":"1.0.0"},'; head -c 300000 /dev/zero | tr '\0' 'x' | fold -w 80 | sed 's/^/"k":"/; s/$/",/'; echo '"z":"z"}'; } > "${d}/app/package.json"
echo 'acmewidget;;acme-widget-sdk;;zzz-never-matches-zzz;;test' > "${d}/.forge/vendors.txt"
"${GIT}" -C "${d}" add -A
rc=$(run "${d}" sink-inventory-drift.sh)
if [ "${rc}" = "1" ] && has 'acmewidget'; then ok "sink-inventory-drift: a vendor at the top of a ~300KB manifest is still inventoried"; else ng "sink-inventory-drift: large-manifest vendor missed (rc=${rc}): $(show)"; fi

# The opposite direction: a covering pattern at the top of a large sink table must count as covered (not 'uncovered').
d=$(mkdrift app)
echo 'acmewidget;;acme-widget-sdk;;acmecover;;test' > "${d}/.forge/vendors.txt"
{ echo 'acmecover'; head -c 300000 /dev/zero | tr '\0' 'x' | fold -w 100; } > "${d}/.forge/sinks.txt"
"${GIT}" -C "${d}" add -A
rc=$(run "${d}" sink-inventory-drift.sh)
if [ "${rc}" = "0" ]; then ok "sink-inventory-drift: a covering pattern at the top of a large sink table counts as covered"; else ng "sink-inventory-drift: large sink table misjudged (rc=${rc}): $(show)"; fi

# A rule that cannot be compiled must stop the scan, not silently never fire.
d=$(mkrepo); mkdir -p "${d}/auth" "${d}/.forge"; echo x > "${d}/auth/login.py"; "${GIT}" -C "${d}" add auth/login.py
printf 'PATH:(unclosed\n' > "${d}/.forge/rflag-rules.txt"
rc=$(run "${d}" rflag-scan.sh)
if [ "${rc}" = "2" ] && has 'PATH rule is invalid' && has 'unclosed'; then ok "rflag-scan: an invalid PATH rule -> exit 2, names the rule"; else ng "rflag-scan: invalid PATH rule swallowed (rc=${rc}): $(show)"; fi
printf 'CONTENT:[\n' > "${d}/.forge/rflag-rules.txt"
rc=$(run "${d}" rflag-scan.sh)
if [ "${rc}" = "2" ] && has 'CONTENT rule is invalid'; then ok "rflag-scan: an invalid CONTENT rule -> exit 2, names the kind"; else ng "rflag-scan: invalid CONTENT rule swallowed (rc=${rc}): $(show)"; fi
rm -f "${d}/.forge/rflag-rules.txt"
rc=$(run "${d}" rflag-scan.sh "$(gwenv)" "FAIL_GIT=cached -- .")
if [ "${rc}" = "2" ] && has 'could not fetch the staged diff'; then ok "rflag-scan: failure to fetch the staged diff -> exit 2 (not 'no added lines')"; else ng "rflag-scan: diff failure swallowed (rc=${rc}): $(show)"; fi

echo "== 9. non-UTF-8 bytes, invalid vendor regexes, unreadable memory entries, and the grep-failure guards =="
# A file holding non-UTF-8 bytes (Shift-JIS "\x83\x65") ahead of a sink. Under a UTF-8 locale BSD sed aborts with
# "illegal byte sequence" and the swallowed failure used to read as "no added lines" (clean).
d=$(mkrepo); printf 'x = "\x83\x65"\ntwilio_service.send("hi")\n' > "${d}/svc_sjis.py"; "${GIT}" -C "${d}" add svc_sjis.py
rc=$(run "${d}" sink-scan.sh)
if [ "${rc}" = "1" ] && has 'svc_sjis.py'; then ok "sink-scan: a sink in a file with non-UTF-8 bytes is still detected"; else ng "sink-scan: non-UTF-8 file passed as clean (rc=${rc}): $(show)"; fi
d=$(mkrepo); printf 'x = "\x83\x65"\ntwilio_service.send("\x83\x65")\n' > "${d}/svc_sjis.py"; "${GIT}" -C "${d}" add svc_sjis.py
rc=$(run "${d}" no-live-fire-check.sh)
if [ "${rc}" = "1" ] && has 'svc_sjis.py'; then ok "no-live-fire-check: a sink in a file with non-UTF-8 bytes is still reported"; else ng "no-live-fire-check: non-UTF-8 file passed as clean (rc=${rc}): $(show)"; fi

# Negative controls (the matcher must not flag clean input).
d=$(mkrepo); echo 'print("hello")' > "${d}/plain.py"; "${GIT}" -C "${d}" add plain.py
rc=$(run "${d}" sink-scan.sh)
if [ "${rc}" = "0" ]; then ok "sink-scan: a file with no sink is not flagged"; else ng "sink-scan: false positive (rc=${rc}): $(show)"; fi
d=$(mkdrift app); echo 'acmewidget;;no-such-dependency;;zzz-never-matches-zzz;;test' > "${d}/.forge/vendors.txt"
rc=$(run "${d}" sink-inventory-drift.sh)
if [ "${rc}" = "0" ]; then ok "sink-inventory-drift: a vendor that is not a dependency is not reported"; else ng "sink-inventory-drift: false positive (rc=${rc}): $(show)"; fi

# An invalid regex in a vendor table entry is reported, not read as "not present" / "not covered".
d=$(mkdrift app); echo 'acmewidget;;(acme-widget;;zzz;;test' > "${d}/.forge/vendors.txt"
rc=$(run "${d}" sink-inventory-drift.sh)
if [ "${rc}" = "1" ] && has 'invalid presence regex' && has 'acmewidget'; then ok "sink-inventory-drift: an invalid presence regex -> exit 1, names the vendor (was: silent pass)"; else ng "sink-inventory-drift: invalid presence regex swallowed (rc=${rc}): $(show)"; fi
d=$(mkdrift app); echo 'acmewidget;;acme-widget-sdk;;(zzz;;test' > "${d}/.forge/vendors.txt"
rc=$(run "${d}" sink-inventory-drift.sh)
if [ "${rc}" = "1" ] && has 'invalid coverage regex' && has 'acmewidget'; then ok "sink-inventory-drift: an invalid coverage regex -> exit 1, names the vendor"; else ng "sink-inventory-drift: invalid coverage regex swallowed (rc=${rc}): $(show)"; fi

# Unusable entries in the memory directory (dangling symlink, a directory named x.md) are skipped; they must not block
# the commit, and a real note beside them is still searched.
d=$(mkrepo); h=$(mkmem "${d}" "- [ ] sat-guard_manual still open")
san=$(printf '%s' "${d}" | sed 's/[^A-Za-z0-9]/-/g'); md="${h}/.claude/projects/${san}/memory"
ln -s "${tmp}/does-not-exist" "${md}/dangling.md"; mkdir "${md}/adir.md"
echo x > "${d}/sat-guard_manual.md"; "${GIT}" -C "${d}" add sat-guard_manual.md
rc=$(run "${d}" check-open-remediations.sh "HOME=${h}")
if [ "${rc}" = "1" ] && has 'sat-guard_manual' && ! has 'grep:'; then ok "memory dir with a dangling symlink and a directory named x.md: skipped, the real note still hits"; else ng "unusable memory entry blocked or hid the check (rc=${rc}): $(show)"; fi

# The matching step's own failure is refused. The wrapper fails a grep only when its arguments contain ' -E ' AND the
# marker (the validation call uses -IqE and the filter calls have no marker, so only the matcher is hit).
mkdir -p "${tmp}/gw2"
# shellcheck disable=SC2016 # the wrapper script body is meant to be written out unexpanded
printf '#!/bin/bash\ncase " $* " in *" -E "*"${FAIL_MATCH:-@@none@@}"*) echo "fake grep failure" >&2; exit 2;; esac\nexec "%s" "$@"\n' "${real_grep}" > "${tmp}/gw2/grep"
chmod +x "${tmp}/gw2/grep"
d=$(mkrepo); mkdir -p "${d}/.forge"; echo 'zzmarkerzz' > "${d}/.forge/sinks.txt"; echo 'zzmarkerzz()' > "${d}/svc_marker.py"; "${GIT}" -C "${d}" add svc_marker.py
rc=$(run "${d}" sink-scan.sh "PATH=${tmp}/gw2:${PATH}" "FAIL_MATCH=zzmarkerzz")
if [ "${rc}" = "3" ] && has 'matching the sink patterns'; then ok "sink-scan: a failing matcher grep -> exit 3, says which step (not 'no match')"; else ng "sink-scan: matcher failure swallowed (rc=${rc}): $(show)"; fi

echo
echo "passed ${pass} / failed ${fail}"
[ "${fail}" -eq 0 ]

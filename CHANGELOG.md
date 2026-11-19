# Changelog

All notable changes to SinkSeal are recorded here.

## [Unreleased]

### Fixed

- **Hooks silently skipped files with non-ASCII names** (e.g. Japanese file
  names). By default git prints such names quoted and octal-escaped
  (`"docs/\344\273\225..._v051.md"`), and several hooks used that string as if
  it were the real name:
  - `check-open-remediations.sh`: the escaped name became a grep keyword; its
    `\344` was read as a regex back-reference, grep died with `invalid
    backreference number`, and the trailing `|| true` swallowed the failure — so
    the open-item cross-check did nothing and the commit went through (a check
    that could not run was treated as a pass). It now reads names with
    `git diff --cached --name-only -z`, matches each basename as a literal string
    (`grep -iF --`, so `\1`, `[`, `*` or a leading `-` in a name are harmless),
    and exits 2 with a reason on stderr when listing the files, reading the
    memory notes, or the keyword lookup fails (grep exit 2 or more). An absent or
    empty memory directory remains a quiet pass (the check is opt-in).
  - `rflag-scan.sh`: the quoted name starts with `"`, so anchored PATH rules such
    as `(^|/)auth` never matched it. Names are now read with `-z`; a failure to
    list them exits 2 instead of reporting "no flag".
  - `sink-scan.sh`: `git diff -- "$f"` with the quoted name matched no path, so
    the file's sinks were skipped. Names are read with `-z`, the per-file diff
    uses `:(literal)`, and failure to list or diff exits 3 (could not run).
  - `no-live-fire-check.sh`: `"$repo_root/$f"` pointed at a path that does not
    exist and the file was skipped, so a raw sink in a non-ASCII-named file
    passed the CI sweep. Tracked files are read with `git ls-files -z`; failure
    to list exits 2.
  - `sink-inventory-drift.sh`: a dependency manifest under a non-ASCII-named
    directory was dropped from the inventory. Tracked files are read with
    `git ls-files -z`; failure to list exits 1 rather than reading an empty
    inventory as a pass.
  - `pre-commit` now refuses the commit (exit 1) when the R-flag scan, the sink
    scan, or the open-remediation cross-check could not run, instead of treating
    any non-zero exit as "flagged" and letting a trailer
    (`R-Flag: no` / `Remediation-Check: unrelated`) wave through a check that
    never ran.
- **Two more silent-miss paths in the same hooks** (found by the sweep; same
  "a check that could not run read as a pass" shape):
  - `sink-scan.sh` and `sink-inventory-drift.sh` used `grep -q` on a pipe under
    `pipefail`. `-q` stops at the first match and the writer dies of SIGPIPE,
    which reads as "no match": a sink on the first line of a ~300KB file was
    reported clean (exit 0), and a vendor at the top of a large dependency
    manifest was not inventoried. They now read all input.
  - `rflag-scan.sh` swallowed errors with `|| true`: an invalid regex in a
    `PATH:`/`CONTENT:` rule meant the rule silently never fired, and a failed
    `git diff` read as "no added lines". Both now exit 2 with the rule (or the
    step) named.
  - `sink-scan.sh` did not validate its pattern table: one invalid regex line
    made every later grep exit 2, which `|| continue` read as "no match", so
    the whole scan passed silently (`no-live-fire-check.sh` already refused this).
    It now validates up front and exits 3 with the cause; `pre-commit` refuses.
  - `sink-scan.sh` with no pattern table reachable (a broken install) exited 1,
    which `pre-commit` reads as "soft R-flag" -- satisfiable with an
    `R-Flag: no` trailer. It now exits 3 ("could not run"), which `pre-commit`
    refuses. **Behaviour change:** anything that relied on exit 1 for this case
    must expect 3 (the bundled smoke test's Case 10 is updated accordingly).

### Added

- `tests/nonascii_filenames_test.sh` — regression test for the above (57 cases,
  run under both the C and a UTF-8 locale; rejection cases assert the reason in
  the output, not just a non-zero exit).
- `tests/mutate_nonascii_filenames.py` — mutation check: mechanically plants one
  defect at a time in the relevant hook lines and confirms the test fails.

### Version note

Hook headers still read `SinkSeal version: 0.1.0`. This change alters hook
behaviour (new exit codes, stricter `pre-commit`), so a release bump (suggested:
0.1.1) is proposed for the maintainer's decision; it is deliberately not made here.

## [0.1.0] — 2026-07-27

Initial public release.

### Added

- Core git hooks: `pre-commit`, `commit-msg`, `pre-push`
- `rflag-scan.sh` — risk-flag pattern matching engine (`PATH:`/`CONTENT:` rules)
- `sink-scan.sh` — live-fire sink scan for the staged diff (flow check)
- `no-live-fire-check.sh` — full-tree live-fire sweep for CI (stock check)
- `sink-inventory-drift.sh` — ledger-coverage check against dependency manifests
- `check-open-remediations.sh` — Claude Code memory cross-check (no-op elsewhere)
- Default pattern tables (`lib/rflag-rules-default.txt`, `lib/sinks-default.txt`,
  `lib/sink-hosts.txt`, `lib/live-fire-vendors.txt`)
- `install.sh` — self-contained installer with machine-verified CI wiring
  (GitHub Actions, GitLab CI, Bitbucket Pipelines, CircleCI)
- `templates/LIVE_FIRE.md` — registration template for intentional live-fire paths
- Regression suite: `tests/smoke_test.sh` (15 cases), `tests/pattern_complexity_test.sh`
- `SECURITY.md`, `THREAT_MODEL.md` (generated per release, not tracked in git)

### Fixed (pre-release hardening)

- `sink-scan.sh` now loads `lib/sink-hosts.txt`, closing a raw-HTTP bypass gap
  that existed at the flow (pre-commit) stage
- `sink-scan.sh` / `no-live-fire-check.sh` demo/test path classification is now
  boundary-anchored (previously an unanchored substring match could misclassify
  e.g. `attestation.py` as a test path or `seeding_data.py` as a demo path)
- `sink-scan.sh` fails closed (instead of silently passing) when no sink
  pattern table is reachable
- `check-open-remediations.sh` path sanitization now matches Claude Code's
  actual directory-naming convention (all non-alphanumeric characters, not
  just `/`)
- `commit-msg` trailer matching is now boundary-anchored (previously
  `R-Flag: yesfurthermore` would have satisfied the `R-Flag: yes` check)
- `rflag-scan.sh` no longer self-triggers an R-flag on the first commit of its
  own installed `.githooks/` copy (the pattern definitions were matching
  themselves)
- Added a static ReDoS guard (`tests/pattern_complexity_test.sh`) flagging
  nested-quantifier patterns in `lib/*.txt` before they ship

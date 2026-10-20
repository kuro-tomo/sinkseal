# Changelog

All notable changes to SinkSeal are recorded here.

## [Unreleased]

### Fixed

- **Non-ASCII file names silently escaped every hook.** By default git C-quotes a
  non-ASCII file name into octal escapes (`"auth/\346\227\245..."`). The hooks used
  `git diff --cached --name-only` / `git ls-files` output as if it were the raw name, so
  for a file with a non-ASCII name: `rflag-scan.sh` never matched anchored path rules
  (e.g. `auth/`), `sink-scan.sh` skipped the file's sink (including the demo/mock
  **hard block**), `no-live-fire-check.sh` swept a path that does not exist,
  `sink-inventory-drift.sh` dropped manifests under non-ASCII directories from the
  inventory, and `check-open-remediations.sh` died with `grep: invalid backreference
  number` (swallowed by `|| true`), skipping the whole check. File lists are now read
  NUL-delimited (`-z`), names are matched as fixed strings (`grep -F`), and the per-file
  diff uses a `:(literal)` pathspec.
- **"Could not inspect" is no longer a pass.** If git or grep fails while listing or
  matching, the hooks now stop (`rflag-scan.sh` / `check-open-remediations.sh` exit 2,
  `sink-scan.sh` exit 3, `no-live-fire-check.sh` exit 2, `sink-inventory-drift.sh` exit 1)
  instead of reading an empty result as "nothing found". `pre-commit` refuses the commit
  for any exit code other than the documented ones, so an R-Flag / Remediation-Check
  trailer can no longer wave through a scan that never ran.

### Added

- `tests/test_nonascii_filenames.sh` (36 cases, run under the C locale and a UTF-8
  locale) and `tests/mutate_nonascii_filenames.py` (35 generated mutants, all killed).

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

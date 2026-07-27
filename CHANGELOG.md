# Changelog

All notable changes to SinkSeal are recorded here.

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

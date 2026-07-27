---
name: sinkseal-setup
description: Install SinkSeal (git-hook guardrails against secret leaks and live-fire accidents) into a repo, wire it into CI, and walk through the first commit's R-flag trailer. Use when the user asks to "set up SinkSeal", "add SinkSeal to this repo", or "install git-hook guardrails for AI agents".
---

# SinkSeal setup

Installs [SinkSeal](https://github.com/kuro-tomo/sinkseal) into the current repo end-to-end: the hooks themselves, CI wiring, and getting the user past the one thing every first-time adopter hits (an R-flag trailer requirement on the very commit that adds the hooks would be self-referential noise if the hook weren't already fixed to exclude its own pattern-table files — as of SinkSeal 0.1.0 it is, so this should be a non-issue, but if an older SinkSeal is in use, don't be surprised by it).

## Procedure

1. **Confirm this is a git repo.**
   ```
   git rev-parse --show-toplevel
   ```
   If it isn't, stop and say so — SinkSeal only makes sense inside a git repo.

2. **Get SinkSeal.** If the user doesn't already have a local checkout of the SinkSeal repo, clone it to a scratch location:
   ```
   git clone https://github.com/kuro-tomo/sinkseal /tmp/sinkseal-src
   ```

3. **Run the installer against the target repo.**
   ```
   /tmp/sinkseal-src/install.sh <path-to-target-repo>
   ```
   Read its output carefully — it ends with either a success summary (including confirmation that CI wiring was verified) or `exit 2` with a specific list of what's missing. Don't report "installed" until you've seen which one it was.

4. **If CI wiring is reported missing**, add a job to whichever CI system the repo uses that runs `no-live-fire-check.sh` and `sink-inventory-drift.sh` (both live in `.githooks/` after install). For GitHub Actions specifically, this repo's own `.github/workflows/ci.yml` is a working reference — copy the `no-live-fire` and `sink-inventory-drift` jobs from it, adjusting paths/branch names as needed. Re-run `install.sh` afterward to confirm the wiring check now passes.

5. **Register SinkSeal's branch protection as a required check** (GitHub: repo Settings → Branches → branch protection rule for the default branch → enable "Require status checks to pass" and add the jobs from step 4, plus `gitleaks` and `shellcheck` if those are also wired in). This step needs repo admin access — if the current user doesn't have it, tell them explicitly what to configure rather than silently skipping it.

6. **Stage and commit the installed hooks.**
   ```
   git add .githooks
   git commit -m "Install SinkSeal git-hook guardrails"
   ```
   If `pre-commit` reports an R-flag on this commit, it means an older SinkSeal without the self-reference fix is in use — add an `R-Flag: no (installing SinkSeal itself, no risk-category code touched)` trailer and note to the user that upgrading to a current SinkSeal release removes this one-time friction.

7. **Explain the two review points that follow every future commit**, so the user isn't surprised the first time they hit one:
   - An **R-flag trailer** requirement (`R-Flag: yes` or `R-Flag: no (reason)`) when a commit touches a risk category (auth, payments, migrations, etc.) — this is a prompt for a human acknowledgment, not a block.
   - A **hard block** if a commit adds a raw call to a live-fire sink (SMS/payment/posting API) from what looks like a demo or mock path — this one *is* a block, by design (see the README's "core idea: sink sealing" section for why).

## What this skill does not do

It does not add SinkSeal's paid Pro Kit (industry-specific pattern packs, the `/done` and `/ship` skills) — that's a separate purchase, see the README's "SinkSeal Pro Kit" section. It also does not configure `.forge/rflag-rules.txt` or `.forge/sinks.txt` customizations — those are project-specific and the user should author them deliberately, not have an agent guess at them.

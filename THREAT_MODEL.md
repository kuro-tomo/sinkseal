# Threat Model: SinkSeal

## 1. System context

SinkSeal is a bash-based git-hook toolkit (~1,600 lines across 8 hook scripts, 4 pattern-table text files, an install script, and a smoke-test suite) distributed as open source, with planned paid Gumroad tiers (a Pro Kit and an AI-SaaS Ship Kit). It gives any git repository — regardless of which coding agent or human writes the commits — mechanical enforcement of three things on every commit and push: secret scanning (via gitleaks), risk-category flagging (R-flag rules requiring an explicit commit-message trailer), and detection/blocking of "live-fire" calls to external irreversible-action APIs (SMS, payment, public-posting, etc.) from demo/test code paths. It runs entirely locally (via git hooks) and in CI (as a required GitHub Actions status check); it has no server component, no network listener, and no persistent state beyond files in the repo it's installed into. Its adopters are software teams using AI coding agents (Claude Code, Cursor, Codex) who want a machine-enforced safety net that doesn't depend on the agent remembering to ask for review.

## 2. Assets

| asset | description | sensitivity |
|---|---|---|
| Signal integrity | the correctness of the tool's pass/fail verdict on a commit or CI run — the entire value proposition depends on a "pass" being trustworthy | high |
| Developer/CI runtime environment integrity | secrets, cloud credentials, and code-execution capability available in the shell context a hook runs in (local dev machine or CI runner) | critical |
| Downstream adopters' environments in aggregate | supply-chain blast radius — every repo that runs install.sh inherits verbatim whatever the distributed hook scripts do; adoption growth directly grows this asset's value as a target | critical |
| Matched diff/config content confidentiality | hooks intentionally echo matched fragments (file paths, pattern names) to stdout for auditability; on a public repository this output can land in publicly-visible CI logs | medium |
| Developer productivity / CI availability | because `core.hooksPath` makes these hooks mandatory and branch protection makes the CI sweep a required check, a hung or wrongly fail-closed hook blocks commits/merges for the whole team | medium |

## 3. Entry points & trust boundaries

| entry_point | description | trust_boundary | reachable_assets |
|---|---|---|---|
| Staged git diff (added lines + file paths) | pre-commit invokes rflag-scan.sh and sink-scan.sh, which grep -E the staged diff content and changed file paths | anyone with local commit rights (including an AI coding agent acting under a bad instruction or prompt injection) -> the hook's pattern-matching verdict | Signal integrity, Developer productivity / CI availability |
| Full tracked file tree (git ls-files) | no-live-fire-check.sh and sink-inventory-drift.sh read every tracked file's content as the CI "stock" sweep | committed repo content -> CI job execution context | Signal integrity, Developer productivity / CI availability |
| .forge/*.txt config files | rflag-rules.txt, sinks.txt, sinks-allow.txt, vendors.txt, vendors-allow.txt, changelog-path.txt — read as regex patterns or file paths by the hooks and trusted at face value | repo committer -> the hook's allow/deny trust decisions | Signal integrity |
| .forge/gates.sh | pre-push executes this file directly and unconditionally whenever it exists and is executable, with no sandboxing or restriction on what it may do | repo committer -> arbitrary code execution in the developer or CI environment | Developer/CI runtime environment integrity |
| install.sh \<target-dir\> argument | local operator supplies a filesystem path; the script copies hook files into \<target\>/.githooks/ after only confirming it's a git repo | local operator -> filesystem write | Downstream adopters' environments in aggregate |
| Dependency manifests (package.json, requirements.txt, etc.) | sink-inventory-drift.sh reads these as plain text to decide whether a live-fire vendor is "present" and whether it's covered by a sink pattern | committed manifest content -> ledger-coverage verdict | Signal integrity, Developer productivity / CI availability |
| SinkSeal's own distribution channel | today a GitHub clone; planned future paid downloads via Gumroad. install.sh copies hook scripts verbatim into every adopting repo's .githooks/ | upstream maintainer/repo -> every downstream adopter's dev and CI environment | Developer/CI runtime environment integrity, Downstream adopters' environments in aggregate |
| git commit/push --no-verify | a standard git flag that skips hook execution entirely; explicitly documented in README as an accepted gap, mitigated only for Claude Code users who separately configure a PreToolUse hook not shipped by this project | local operator, or an AI agent acting with the operator's own git credentials -> total bypass of all SinkSeal enforcement | Signal integrity |

## 4. Threats

| id | threat | actor | surface | asset | impact | likelihood | status | controls | evidence |
|---|---|---|---|---|---|---|---|---|---|
| T1 | Arbitrary code execution via an unrestricted .forge/gates.sh hook | insider | .forge/gates.sh | Developer/CI runtime environment integrity | critical | possible | unmitigated | none | |
| T2 | Supply-chain compromise of the SinkSeal distribution propagates to every downstream adopter | supply_chain | SinkSeal's own distribution channel | Downstream adopters' environments in aggregate | critical | rare | unmitigated | none | |
| T3 | Total bypass of all enforcement via --no-verify, including by an AI agent acting under a bad instruction | insider | git commit/push --no-verify | Signal integrity | high | almost_certain | partially_mitigated | Claude Code users may separately configure a PreToolUse hook that blocks --no-verify; not shipped by SinkSeal and not available to Cursor/Codex users | |
| T4 | Detection bypass via regex evasion of pattern-based sink/R-flag matching | insider | Staged git diff (added lines + file paths); .forge/*.txt config files | Signal integrity | high | likely | partially_mitigated | boundary-anchored path regexes, comment-stripping with leading `*/` handling, hard/soft block tiers (2026-07-27 fixes) | |
| T5 | Regular-expression denial of service (ReDoS) or process-DoS via crafted diff content or dependency-manifest entries | insider | Staged git diff (added lines + file paths); Dependency manifests | Developer productivity / CI availability | medium | possible | partially_mitigated | tests/pattern_complexity_test.sh statically flags nested-quantifier patterns in lib/*.txt before they ship (2026-07-27, dcr-scan finding f001); does not cover a downstream adopter's own .forge/*.txt additions | |
| T6 | Overly broad or malicious allowlist entry silently exempts a real live-fire sink from detection | insider | .forge/*.txt config files | Signal integrity | medium | possible | partially_mitigated | start-anchored allowlist matching (2026-07-26 fix) prevents substring-match over-permission, but an authorized user can still author a legitimately-anchored yet overly broad pattern | |
| T7 | A malformed or missing pattern-table config unintentionally blocks all commits org-wide (self-inflicted denial of service via the fail-closed safety design) | insider | Staged git diff (added lines + file paths); Full tracked file tree (git ls-files); .forge/*.txt config files | Developer productivity / CI availability | medium | possible | partially_mitigated | explicit, distinguishing error messages for missing/malformed pattern tables (2026-07-26/27 fixes) so a misconfiguration is diagnosable rather than a silent hang | |
| T8 | Sensitive fragment disclosure via matched-pattern output landing in public CI logs | remote_unauth | Full tracked file tree (git ls-files) | Matched diff/config content confidentiality | low | possible | unmitigated | none | |
| T9 | install.sh writes into an unintended location due to a mistaken or attacker-influenced target path | local_user | install.sh \<target-dir\> argument | Downstream adopters' environments in aggregate | low | rare | partially_mitigated | install.sh verifies the target is a valid git repository before writing (via git rev-parse --git-dir) | |

## 5. Deprioritized

| threat | reason |
|---|---|
| Spoofing of a trusted remote identity | SinkSeal has no network component and performs no authentication of its own; it has nothing to spoof against |
| Repudiation of hook actions | git's own commit history already provides attribution for every action; SinkSeal introduces no separate log requiring independent non-repudiation guarantees |
| Remote unauthenticated network attack | the tool has no listening service, API, or network-facing component; every entry point requires local repo commit access or a CI execution context already gated by the adopting organization's own access control |

## 6. Open questions

- Is a "curl \| bash" style one-line install ever planned for marketing/onboarding? Today install.sh is only documented as run from a local clone, which sidesteps a MITM/tampering concern that a hosted-script install would reintroduce — worth a firm decision before any such onboarding flow ships.
- What is the actual current adoption count and repo visibility mix (public vs private)? This directly affects the real-world likelihood of T8 (public CI log exposure) and T2 (supply-chain attractiveness as a target).
- Is there an intended process for reviewing `.forge/gates.sh` changes with the same scrutiny as a CI workflow change (e.g., CODEOWNERS on `.forge/`)? The tool currently has no opinion on this and it's left entirely to the adopting org.
- Will the Pro/Ship Kit tiers ship signed artifacts or checksums, or continue to rely on git clone integrity alone?
- Is there an appetite to ship an official, tested `--no-verify`-blocking hook (for at least Claude Code, with guidance for others) as part of the product itself, rather than leaving T3 to each adopter's own setup?

## 7. Provenance

- mode: bootstrap
- date: 2026-07-27
- target: local checkout of this repository @ not a git repo (at time of analysis)
- inputs: git-log + CHANGELOG mined (no git history yet; brand-new project, no prior CVEs/advisories)
- owner: unset

## 8. Recommended mitigations

| mitigation | threat_ids | closes_class | effort |
|---|---|---|---|
| ~~Add a regex-complexity smoke-test~~ — implemented as `tests/pattern_complexity_test.sh` (static nested-quantifier check, 2026-07-27); extend the same check to a downstream adopter's own `.forge/*.txt` additions for full coverage | T5 | partial | S |
| Document .forge/gates.sh as a CI-config-equivalent trust level requiring the same review scrutiny as a workflow file change (e.g. recommend CODEOWNERS on .forge/) | T1 | partial | S |
| Ship an optional, tested PreToolUse-hook template (Claude Code) plus guidance for other agents as part of the Pro Kit, instead of leaving --no-verify blocking entirely to each adopter | T3 | partial | S |
| State plainly in all product messaging that pattern-based detection is a probabilistic safety net, not a completeness guarantee; pair with periodic pattern-table review | T4 | partial | S |
| Publish signed releases / checksums for install.sh and the hooks/lib payload before the Gumroad Pro Kit ships | T2 | partial | M |

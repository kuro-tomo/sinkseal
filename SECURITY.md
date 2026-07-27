# Security Policy

SinkSeal is a security-adjacent tool (git hooks that catch secrets and
risk-prone changes), so we take reports about SinkSeal's own code seriously.

## Reporting a vulnerability

Please use [GitHub's private vulnerability reporting](https://github.com/kuro-tomo/sinkseal/security/advisories/new) for this repository rather than opening a public issue. This lets us assess and fix the issue before it's publicly disclosed.

If you can't use that flow, open a regular issue with as little detail as possible (e.g. "potential security issue, please advise how to report privately") and we'll follow up.

Please include:
- The affected file(s) and, if applicable, a specific commit/version
- Steps to reproduce, or a concrete exploit scenario
- What you'd expect the fix to look like, if you have a suggestion

## Scope

In scope: the hook scripts (`hooks/`), the pattern tables (`lib/`), `install.sh`, and the CI workflow shipped in this repo.

Out of scope: vulnerabilities in a downstream adopter's own `.forge/*.txt` additions or `.forge/gates.sh` content — those are the adopting repo's own trusted configuration, equivalent in trust level to any other file they choose to commit.

## Response time

We aim to acknowledge reports within 5 business days and to have a fix or mitigation plan within 2 weeks for confirmed issues, though this is a best-effort commitment, not an SLA.

## Known design tradeoffs

Some things that look like vulnerabilities are documented, accepted tradeoffs rather than bugs — see `THREAT_MODEL.md` in this repo (where present in a given release) for the full reasoning:

- `.forge/gates.sh` is executed with no sandboxing by `pre-push` — this is by design (an escape hatch for custom test commands), and carries the same trust level as any other file a repo committer can add.
- `git commit/push --no-verify` bypasses all hooks entirely — this is standard git behavior, not something SinkSeal can or should try to prevent from inside a hook.
- Pattern-based detection (`rflag-scan.sh`, `sink-scan.sh`, etc.) is a probabilistic safety net, not a completeness guarantee — a sufficiently determined actor with existing commit access can craft input that evades a specific regex.

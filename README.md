# SinkSeal

[![CI](https://github.com/kuro-tomo/sinkseal/actions/workflows/ci.yml/badge.svg)](https://github.com/kuro-tomo/sinkseal/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Git-hook guardrails for AI coding agents. Works regardless of which agent
writes the code — Claude Code, Cursor, Codex, or a human — because the
control lives in the git hook, not in any one tool's configuration.

Read this in [English](#english) or [日本語](#japanese).

<a name="english"></a>
## English

### Why this exists

AI coding agents move fast and generate a lot of diffs. Two failure modes
show up repeatedly once agents are doing real work against real
infrastructure:

1. **Ordinary risk misses.** A secret slips into a commit, a migration goes
   out unreviewed, an auth code path changes without anyone flagging it —
   not because anyone was careless, but because the volume of agent-generated
   diffs makes it easy for a risky one to blend in with routine ones.
2. **Live-fire accidents.** A demo or test code path calls a *real* external
   service directly — an SMS API, a payment API, a public-posting API — and
   because it "was only a demo," nobody put a guard on it. One documented
   incident: a product's interactive demo (clicking a logo, pressing a "test
   notification" button) was wired straight to a live SMS/voice vendor, and a
   routine demo session produced real phone charges. The demo code wasn't
   malicious or even obviously wrong to read — it just called the same
   function production did, with no guard checking whether the caller was a
   demo.

Diff review alone doesn't reliably catch either of these, for two reasons.
First, a risk marker on "the lines that changed" misses a call site that
already existed on the main branch before anyone started paying attention to
it. Second, "read the whole function" as a review instruction degrades under
volume — it depends on a human remembering to do it every time, and that's
exactly the kind of dependency a checklist should replace with something a
machine checks instead.

SinkSeal is a set of git hooks that encode both checks mechanically, so
they run on every commit and every push regardless of which agent (or human)
authored the change, and regardless of whether anyone remembered to ask for a
review.

### What's inside

```
hooks/
  pre-commit                  gitleaks (staged diff) + R-flag scan + live-fire
                               sink scan + open-remediation cross-check
  commit-msg                   requires an explicit trailer when pre-commit
                               raised a flag (no silent pass-through)
  pre-push                     runs typecheck/tests on push to the default
                               branch; optional same-day changelog reminder
  rflag-scan.sh                pattern-matching engine for risk-flag rules
  sink-scan.sh                 live-fire sink scan for the staged diff (the
                               "flow" check — catches new sink usage)
  no-live-fire-check.sh        full-tree live-fire sweep for CI (the "stock"
                               check — catches sinks that predate this tool)
  sink-inventory-drift.sh      ledger-coverage check: flags a live-fire vendor
                               present in your dependencies with no matching
                               sink pattern
  check-open-remediations.sh   Claude Code-specific: cross-checks a change
                               against open items ("- [ ] ") in that project's
                               memory notes; a no-op everywhere else
lib/
  rflag-rules-default.txt      default risk-flag patterns (PATH: / CONTENT:)
  sinks-default.txt            default live-fire sink patterns
  sink-hosts.txt                vendor API hostnames (catches raw-HTTP bypass
                               of an SDK)
  live-fire-vendors.txt        vendor table used by the ledger-coverage check
templates/
  LIVE_FIRE.md                  registration template for an intentional
                               live-fire demo path
skills/
  setup.md                      a Claude Code skill that installs SinkSeal end
                               to end (run install.sh, wire CI, walk through
                               the first commit) — drop into ~/.claude/skills/
                               or the Anthropic Skills directory
tests/
  smoke_test.sh                 end-to-end regression suite (throwaway repo,
                               installs the kit, asserts exit codes)
  pattern_complexity_test.sh    static ReDoS guard for lib/*.txt (flags a
                               nested-quantifier shape before it ships)
  test_nonascii_filenames.sh    non-ASCII file names stay in the hooks' view, and
                               "could not inspect" never reads as a pass
  mutate_nonascii_filenames.py  mutation check for the suite above (injects
                               defects into the hooks; every one must be caught)
install.sh                     installs everything into a target repo,
                               self-contained (no dependency on this checkout
                               continuing to exist)
```

### The core idea: sink sealing

A "sink" is the last line of code that turns a function call into something
irreversible in the outside world — an SMS actually sent, a charge actually
made, a post actually published. Callers of a sink multiply across a
codebase; the sinks themselves stay few. So the guard belongs **on the sink**,
not on every caller: a guarded relay (e.g. `notifier.notify()`) that
unconditionally no-ops for a synthetic/test/demo identifier, rather than
trusting every call site to remember to check first.

SinkSeal enforces this at two points:

- **Flow** (`sink-scan.sh`, runs on every commit): a demo/mock path adding a
  *raw* sink call — bypassing the guarded relay — is a hard block. Any other
  path touching a raw sink is a soft flag requiring acknowledgment. Paths that
  look like tests (`test`, `spec`, `e2e`, `__tests__`, `.stories.`) are treated
  as a safety net rather than a danger source and are excluded from both
  checks — a raw sink call added purely inside a test file produces neither a
  block nor a flag.
- **Stock** (`no-live-fire-check.sh`, runs in CI): a full-tree sweep, because
  the flow check only sees new diffs. Code that reached main before this tool
  was installed needs its own sweep.

A third check, `sink-inventory-drift.sh`, catches the failure mode neither of
those two can: your project adds a new live-fire vendor (say, switching from
Twilio to Vonage) and nobody adds a matching pattern to the sink tables. The
scan then goes quietly blind for that vendor while continuing to report
"pass." This check reads your dependency manifests as the source of truth for
"what's actually present" and fails if the ledger hasn't kept up.

An intentional live-fire path (a real sales demo that needs a real call to
land) isn't banned — it's registered as an exception in `LIVE_FIRE.md` and
added to `.forge/sinks-allow.txt`. See that template for the fields it
requires, in particular that "disabled" must say specifically *which guard
layer* is down, not just the word "disabled."

### Prerequisites

- `gitleaks` on `PATH` for the secret scan in `pre-commit` to actually run. If
  it isn't installed, `pre-commit` prints a warning and continues *without*
  scanning for secrets — it does not block the commit and does not fail
  loud beyond that one warning line. Install it from
  https://github.com/gitleaks/gitleaks before relying on this check.

### Installation

```
./install.sh /path/to/your/repo
```

This copies the hooks self-contained into `<repo>/.githooks/` and sets
`core.hooksPath` accordingly. Because the copy is self-contained, it survives
even if this SinkSeal checkout is later deleted, and it's inherited
automatically by any git worktree of that repo (worktrees share tracked
files).

`install.sh` also verifies that `no-live-fire-check.sh` and
`sink-inventory-drift.sh` are actually referenced somewhere in your CI config
(GitHub Actions, GitLab CI, Bitbucket Pipelines, or CircleCI) — not just
installed, but wired into CI — and exits non-zero if not. A hook nobody's CI
ever runs provides no protection, and an install script that reports success
either way just teaches everyone to trust an install that, in practice, was
never actually wired up.

**Updating the kit.** `install.sh` copies files; it doesn't leave a link back
to this checkout. If you pull a newer SinkSeal and want the changes, re-run
`install.sh` against each repo you installed it into — there's no automatic
propagation.

### Per-project tuning

- `.forge/rflag-rules.txt` — additional risk-flag rules (same `PATH:`/`CONTENT:` format)
- `.forge/sinks.txt` — additional sink patterns
- `.forge/sinks-allow.txt` — allowlist of files legitimately holding a sink (read by the CI sweep)
- `.forge/vendors.txt` — additional live-fire vendors for the ledger-coverage check (same `vendor;;presence;;coverage;;category` format as `lib/live-fire-vendors.txt`)
- `.forge/vendors-allow.txt` — vendors judged not to be live-fire in this project, with a reason
- `.forge/gates.sh` — project-specific test/typecheck command (make it executable) — overrides the generic auto-detection in `pre-push`
- `.forge/changelog-path.txt` — optional: a repo-relative path to a changelog file; `pre-push` warns (non-blocking) if it has no entry dated today

Every pattern you add to `.forge/rflag-rules.txt` or `.forge/sinks.txt` is fed straight into `grep -E` on every commit and CI run, with no complexity check beyond the regex being syntactically valid. A pathological pattern (a repetition quantifier wrapping a group that already has one, e.g. `(a+)+`) can degrade every future commit for the life of the repo. `tests/pattern_complexity_test.sh` statically flags that shape in this kit's own `lib/*.txt` before it ships — copy the same check against your own `.forge/*.txt` additions before merging them.

### On bypassing

`git commit --no-verify` / `git push --no-verify` skip these hooks entirely —
that's how git hooks work, and SinkSeal doesn't try to hide that. What it
does provide is a machine-enforced default: every commit and push gets
checked unless someone deliberately opts out, which is a very different
posture from "checked only when someone remembers to ask." If you use Claude
Code specifically, you can additionally configure a `PreToolUse` hook in your
own environment to block `--no-verify` invocations at the tool layer — that's
a personal/organizational policy choice outside the scope of what this repo
ships, since it depends on your own agent tooling.

### SinkSeal Pro Kit

Need risk-flag rules for a regulated industry (finance/PCI, healthcare/HIPAA,
EU GDPR) beyond the generic defaults here, or the `/done` and `/ship` Claude
Code skills that pair with this kit's branch-protection model? Those ship
separately as the paid **SinkSeal Pro Kit** on Gumroad — everything on this
page stays free either way.

<!-- TODO(sinkseal): fill in the Gumroad product URL once the listing is live -->

### License

MIT. See `LICENSE`.

---

<a name="japanese"></a>
## 日本語

### これは何か・なぜ作ったか

AIコーディングエージェントは大量の差分を高速に生成する。実際のインフラに対して
本物の作業をさせ始めると、以下の二つの見落としが繰り返し発生する。

1. **通常のリスク見落とし。** 誰かが不注意だったからではなく、大量の差分の中に
   危険な一件が紛れ込みやすくなるために、秘密情報の混入・未レビューのマイグレーション・
   認証経路の変更などが素通りしてしまう。
2. **実弾事故。** デモ/テスト用のコード経路が「本物の」外部サービス（SMS API・
   決済API・公開投稿API等）を直接呼び出してしまい、「デモに過ぎぬ」という思い込みから
   誰も歯止めをかけていない。実例：ある製品の対話デモ（ロゴのダブルクリック・
   「通知テスト」ボタンの押下）が実際のSMS/音声ベンダーへ直結しており、通常のデモ
   操作が実際の電話料金を発生させた。デモコード自体は悪意もなく、読んで明白に
   おかしいわけでもない——本番と同じ関数を、呼び出し元がデモか否かを確認せぬまま
   呼んでいただけである。

差分レビューだけではこの両方を確実には捕捉できない。第一に、「変更行のみ」を見る
リスク判定は、統制が敷かれる以前からmainに存在していた呼び出し箇所を見逃す。
第二に、「関数全文を読め」という指示は量が増えるほど劣化する——毎回人間が覚えて
実行することに依存しており、それこそがチェックリストを機械照合へ置き換えるべき
典型例である。

SinkSealは、この両方の検査を機械的に組み込んだGit hook一式である。どの
エージェント（あるいは人間）が変更を書いたかに関わらず、また誰かがレビューを
思い出したか否かに関わらず、コミット・プッシュの都度作動する。

### 構成

`hooks/`（pre-commit・commit-msg・pre-push・rflag-scan.sh・sink-scan.sh・
no-live-fire-check.sh・sink-inventory-drift.sh・check-open-remediations.sh）、
`lib/`（既定のR旗規則・砲口パターン・ベンダー表）、`templates/LIVE_FIRE.md`
（意図的な実弾デモの登録雛形）、`install.sh`（導入スクリプト）。詳細は上の
英語セクションの構成図を参照（コメントも含め内容は同一）。

### 核心思想：砲口封印

「砲口（sink）」とは、関数呼び出しを外部世界における不可逆な作用——実際に送信
されたSMS、実際に確定した決済、実際に公開された投稿——に変える最後の呼び出し
箇所である。砲口の呼び出し元はコードベース中に増殖するが、砲口自体は少数に
留まる。ゆえにガードは全ての呼び出し元でなく**砲口自身**に置く：合成/テスト/
デモ用の識別子に対して無条件でno-opするガード付き中継（例：`notifier.notify()`）
を経由させ、各呼び出し元が確認を怠らぬことに期待しない。

SinkSealはこれを二点で強制する——**flow**（`sink-scan.sh`・毎コミット。デモ/
モック領域からの生砲口追加はハードブロック、その他は軟R旗）と、**stock**
（`no-live-fire-check.sh`・CI必須。統制施行前からmainに眠る経路を全木走査で
掃討）。三つ目の`sink-inventory-drift.sh`は、新しい実弾ベンダーを導入した際に
砲口パターンの追加を忘れる、という前二者では捕捉できぬ劣化を検知する。

意図的な実弾デモ（本物の営業実演等）は禁止でなく、`LIVE_FIRE.md`への登録
例外として統制下に置く。「無効化済み」の一語で済ませず、どの層が生きて
どの層が落ちているかを具体的に記す欄が要る。

### 導入

```
./install.sh /path/to/your/repo
```

対象リポジトリの`.githooks/`へ自己完結の形で複製し、`core.hooksPath`を
設定する。自己完結ゆえこのSinkSeal自体を後で削除しても動作し、worktreeにも
自動継承される。`install.sh`は`no-live-fire-check.sh`・`sink-inventory-drift.sh`
が実際にCI設定（GitHub Actions・GitLab CI・Bitbucket Pipelines・CircleCIのいずれか）
から呼ばれているかを機械検証し、未配線ならexit 2で知らせる——「導入した」と
「CIで実際に動いている」は別物であるため。

**キット更新時：** `install.sh`はファイルを複製するのみで、この配布元への
参照を残さぬ。新しいSinkSealを取得した際に反映させるには、導入済みの各
リポジトリへ`install.sh`を再実行する要あり——自動的な伝播はせぬ。

### 案件固有の調律

`.forge/rflag-rules.txt`・`.forge/sinks.txt`・`.forge/sinks-allow.txt`・
`.forge/vendors-allow.txt`・`.forge/gates.sh`・`.forge/changelog-path.txt`
（詳細は英語セクション参照）。

### 迂回について

`--no-verify`はhookそのものを迂回する——これはgit hookの仕様であり、隠す
つもりはない。本ツールが提供するのは「誰も明示的に外さぬ限り、全コミット・
全プッシュが検査される」という既定動作であり、「誰かが思い出した時だけ
検査される」姿勢とは質的に異なる。Claude Codeを使う場合、自環境で
`PreToolUse` hookを設け`--no-verify`自体をツール層で拒否することも可能だが、
それは各自のエージェント運用に依存する個人/組織側の方針であり、本リポジトリ
が同梱する範囲を超える。

### SinkSeal Pro Kit

金融（PCI関連）・医療（HIPAA関連）・EU GDPR等、規制産業向けの拡張R旗パターン、
及びこのキットのbranch protection運用と対になる`/done`・`/ship`のClaude Code
スキルは、有料の**SinkSeal Pro Kit**として別途Gumroadにて提供予定
（本ページの内容はいずれも無料のまま）。

<!-- TODO(sinkseal): Gumroad商品ページ確定後にURLを追記 -->

### セキュリティ

脆弱性の報告は`SECURITY.md`を参照。本ツール自身の脅威モデル（想定する脅威・
対策状況の一覧）は`THREAT_MODEL.md`にて公開している——弱点を隠さず示す
ことが、セキュリティ関連ツールへの信頼の土台になると考えるため。

### ライセンス

MIT。`LICENSE`を参照。

#!/usr/bin/env python3
"""Mutation check for the non-ASCII file-name / fail-closed handling in the hooks.

Plants one deliberate defect at a time in the relevant lines of hooks/ and checks
that tests/nonascii_filenames_test.sh fails (i.e. kills the mutant). A surviving
mutant means the test would not notice that particular breakage.

Usage:  python3 tests/mutate_nonascii_filenames.py [--jobs N]
Exit:   0 = every mutant killed
        1 = at least one mutant survived
        2 = the checker itself is unsound (the unmutated control run failed, a
            mutant changed nothing, or no mutants were generated)

Mutants are generated mechanically by scanning every non-comment line of each
hook for the constructs this fix relies on (a hand-picked list would leave gaps):
  - dropping -z from a git file-listing call (names come back quoted again)
  - dropping `read -d ''` / `tr '\\0' '\\n'` (NUL-delimited input no longer parsed)
  - dropping -F from the keyword grep (names read as regexes), dropping `--`
    (a leading '-' read as an option), dropping -i (case-sensitive)
  - dropping :(literal) (names read as pathspecs)
  - discarding git's exit status (`exit "${PIPESTATUS[0]}"` -> `exit 0`)
  - disabling a guard (`if [ "$gr" -ne 0 ]` / `-ge 2` / `if ! git ...`) so a failed
    check falls through as if it had passed
  - turning a refusal's exit code into 0
  - putting grep -q back where the whole input must be read (SIGPIPE false "no match")
  - dropping R from --diff-filter=ACMR (renames fall out of the scan)
  - dropping nullglob / the empty-memory-dir guard / the 4-character noise filter
  - in pre-commit: removing the "could not run" refusal branches, and widening
    `-eq 1` to `-ne 0` (the old behaviour: any non-zero exit read as a flag)
The test runs the hooks under both the C and a UTF-8 locale; on a machine without
a UTF-8 locale, UTF-8-only mutants cannot be killed.

Deliberately NOT mutated: the `mktemp ... || exit N` lines. If mktemp fails the
variable is empty, the next redirect (`> ""`) fails, and the very next guard
refuses anyway, so a mutant there is behaviourally equivalent (the tests still
assert the refusal exit code when the temp directory is unusable).
"""
import argparse
import concurrent.futures as cf
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST = os.path.join("tests", "nonascii_filenames_test.sh")
HOOKS = [
    "hooks/rflag-scan.sh",
    "hooks/sink-scan.sh",
    "hooks/check-open-remediations.sh",
    "hooks/no-live-fire-check.sh",
    "hooks/sink-inventory-drift.sh",
    "hooks/pre-commit",
]
REFUSAL_WORDS = ("could not", "cannot run", "failed to run")
TIMEOUT = 600


def is_comment(line):
    return line.lstrip().startswith("#")


def generate():
    """Return [(name, rel_path, line_index, mutated_line)] by scanning every hook line."""
    out = []
    for rel in HOOKS:
        lines = open(os.path.join(ROOT, rel), encoding="utf-8").read().split("\n")
        for i, ln in enumerate(lines):
            if is_comment(ln):
                continue
            tag = "%s:%d" % (rel, i + 1)
            if re.search(r"\bgit\b.* -z\b", ln):
                out.append(("%s drop -z from the git call (names come back quoted)" % tag, rel, i,
                            re.sub(r" -z\b", "", ln, count=1)))
            if "read -r -d ''" in ln:
                out.append(("%s drop -d '' from read (NUL input not parsed)" % tag, rel, i,
                            ln.replace("read -r -d ''", "read -r")))
            if "tr '\\0' '\\n'" in ln:
                out.append(("%s drop tr '\\0' (NUL-separated names stay glued)" % tag, rel, i,
                            ln.replace("tr '\\0' '\\n'", "cat")))
            if "grep -iF -- " in ln:
                out.append(("%s drop -F from the keyword grep (names read as regex)" % tag, rel, i,
                            ln.replace("grep -iF -- ", "grep -i -- ")))
                out.append(("%s drop -- from the keyword grep (leading '-' read as option)" % tag, rel, i,
                            ln.replace("grep -iF -- ", "grep -iF ")))
                out.append(("%s drop -i from the keyword grep (case-sensitive)" % tag, rel, i,
                            ln.replace("grep -iF -- ", "grep -F -- ")))
            if ":(literal)" in ln:
                out.append(("%s drop :(literal) (name read as a pathspec)" % tag, rel, i,
                            ln.replace(":(literal)", "")))
            if 'exit "${PIPESTATUS[0]}"' in ln:
                out.append(("%s discard git's exit status" % tag, rel, i,
                            ln.replace('exit "${PIPESTATUS[0]}"', "exit 0")))
            if "--diff-filter=ACMR" in ln:
                out.append(("%s drop R from --diff-filter (renames fall out)" % tag, rel, i,
                            ln.replace("ACMR", "ACM")))
            if "shopt -s nullglob" in ln:
                out.append(("%s drop nullglob (empty memory dir hands grep a literal glob)" % tag, rel, i,
                            ln.replace("shopt -s nullglob", "true")))
            if '[ "${#memory_files[@]}" -eq 0 ] && exit 0' in ln:
                out.append(("%s drop the empty-memory-dir guard" % tag, rel, i,
                            ln.replace('[ "${#memory_files[@]}" -eq 0 ] && exit 0', "true")))
            if "awk 'length($0) >= 4'" in ln:
                out.append(("%s drop the 4-character noise filter" % tag, rel, i,
                            ln.replace("length($0) >= 4", "length($0) >= 1")))
            if "${p##*/}" in ln:
                out.append(("%s keep the directory part of the name (basename not taken)" % tag, rel, i,
                            ln.replace("${p##*/}", "${p}")))
            if "${b%.*}" in ln:
                out.append(("%s keep the extension in the keyword" % tag, rel, i,
                            ln.replace("${b%.*}", "${b}")))
            # Reads that must consume all their input: put grep -q (early exit -> SIGPIPE -> false "no match") back.
            m = re.search(r'\| grep (-[A-Za-z]+) ("\$\w+") >/dev/null', ln)
            if m:
                out.append(("%s grep -q instead of reading all input (SIGPIPE under pipefail)" % tag, rel, i,
                            ln.replace(m.group(0), "| grep -q%s %s" % (m.group(1)[1:], m.group(2)))))
            # A guard that turns a failed check into a refusal: disable it, so failure falls through as a pass.
            m = re.match(r'^(\s*)if \[ "\$gr" -(ne 0|ge 2) \]; then(.*)$', ln)
            if m:
                out.append(("%s disable the failure guard (failed check falls through)" % tag, rel, i,
                            "%sif false; then%s" % (m.group(1), m.group(3))))
            m = re.match(r"^(\s*)if ! (.*); then$", ln)
            if m and "git " in m.group(2):
                inner = m.group(2)
                out.append(("%s disable the git-failure guard" % tag, rel, i,
                            "%s%s || true; if false; then" % (m.group(1), inner)))
            # A refusal's exit code turned into 0 (the preceding lines explain the failure).
            m = re.match(r"^(\s*)exit ([1-9])$", ln)
            if m and any(any(w in p for w in REFUSAL_WORDS) for p in lines[max(0, i - 3):i]):
                out.append(("%s refusal exit %s turned into 0" % (tag, m.group(2)), rel, i,
                            "%sexit 0" % m.group(1)))
            # pre-commit: drop the "could not run" refusal branches; widen `-eq 1` to the old `-ne 0`.
            m = re.match(r'^(elif \[ "\$(rflag_rc|sink_rc|rem_rc)" -ne 0 \]; then)$', ln)
            if m:
                out.append(("%s drop the could-not-run refusal branch (%s)" % (tag, m.group(2)), rel, i,
                            "elif false; then"))
            m = re.match(r'^if \[ "\$(rflag_rc|rem_rc)" -eq 1 \]; then$', ln)
            if m:
                out.append(("%s treat any non-zero %s as 'flagged' (the old behaviour)" % (tag, m.group(1)), rel, i,
                            'if [ "$%s" -ne 0 ]; then' % m.group(1)))
    return out


def run_mutant(m):
    name, rel, idx, new_line = m
    d = tempfile.mkdtemp(prefix="sinkseal-mut.")
    try:
        for sub in ("hooks", "lib", "tests"):
            shutil.copytree(os.path.join(ROOT, sub), os.path.join(d, sub))
        p = os.path.join(d, rel)
        lines = open(p, encoding="utf-8").read().split("\n")
        if lines[idx] == new_line:
            return name, "inert"
        lines[idx] = new_line
        open(p, "w", encoding="utf-8").write("\n".join(lines))
        try:
            r = subprocess.run(["bash", os.path.join(d, TEST)], capture_output=True, text=True,
                               errors="replace", stdin=subprocess.DEVNULL, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            return name, "killed"   # a hang is a detected change in behaviour
        return name, ("killed" if r.returncode != 0 else "survived")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=6)
    args = ap.parse_args()

    # Control run with no mutation: if the test does not pass untouched, "all killed" proves nothing.
    r = subprocess.run(["bash", os.path.join(ROOT, TEST)], capture_output=True, text=True, errors="replace",
                       stdin=subprocess.DEVNULL)
    if r.returncode != 0:
        print("ABORT: the unmutated control run failed, so the mutation result would be meaningless.\n" + r.stdout[-600:])
        return 2
    print("control run: the test passes with no mutation")

    mutants = generate()
    if not mutants:
        print("ABORT: no mutants were generated (checker defect)")
        return 2
    print("mutants generated: %d" % len(mutants))

    survived, inert = [], []
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for name, res in ex.map(run_mutant, mutants):
            print({"killed": "killed   ", "survived": "SURVIVED!", "inert": "INERT!   "}[res], name)
            if res == "survived":
                survived.append(name)
            elif res == "inert":
                inert.append(name)
    killed = len(mutants) - len(survived) - len(inert)
    print("mutants %d: killed %d, survived %d, inert %d" % (len(mutants), killed, len(survived), len(inert)))
    if inert:
        return 2
    return 1 if survived else 0


if __name__ == "__main__":
    sys.exit(main())

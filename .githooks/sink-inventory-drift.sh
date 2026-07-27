#!/bin/bash
# SinkSeal version: 0.1.0
# SinkSeal: live-fire ledger coverage check (sink-inventory-drift)
#
# Division of labor with no-live-fire-check.sh:
#   no-live-fire-check.sh ... "does a file outside the allowlist touch a *known*
#                              sink pattern?"
#   this check            ... "does the ledger even cover the live-fire vendors
#                              this project actually depends on?"
#
# The first check alone goes blind the moment a project adds a new live-fire
# vendor (Vonage, Postmark, PayPal, etc.) and nobody adds a matching sink
# pattern — the scan quietly reports "pass" forever after. This check reads
# dependency manifests as the source of truth for "what's actually present" and
# makes the machine say so when the ledger hasn't kept up.
#
# Verdict: a vendor is present in a dependency manifest AND no line in the sink
# pattern tables covers it -> violation.
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Installed repos keep these directly under .githooks/; running from the
# SinkSeal checkout itself keeps them under ../lib/ — check both.
find_lib() {
  if [ -f "$hook_dir/$1" ]; then echo "$hook_dir/$1"
  elif [ -f "$hook_dir/../lib/$1" ]; then echo "$hook_dir/../lib/$1"
  fi
}

vendors_file=$(find_lib live-fire-vendors.txt)
sinks_default=$(find_lib sinks-default.txt)
custom_vendors="$repo_root/.forge/vendors.txt"
custom_sinks="$repo_root/.forge/sinks.txt"
vendors_allow="$repo_root/.forge/vendors-allow.txt"

# A safety net must not report green when it's out of fuel (fail closed). Both
# tables are checked independently — an earlier version only checked
# vendors_file and missed sinks_default, which mostly fails toward
# over-detection but can silently pass on a repo with an empty inventory.
if [ -z "$vendors_file" ]; then
  echo "Live-fire ledger coverage: **cannot run** — vendor table not found (live-fire-vendors.txt missing)." >&2
  echo "  Re-run install.sh to redistribute the SinkSeal hooks." >&2
  exit 1
fi
if [ -z "$sinks_default" ]; then
  echo "Live-fire ledger coverage: **cannot run** — sink pattern table not found (sinks-default.txt missing)." >&2
  echo "  Re-run install.sh to redistribute the SinkSeal hooks." >&2
  exit 1
fi

# --- Gather the active sink pattern table (comments and blanks excluded) ---
sink_lines=""
for f in "$sinks_default" "$custom_sinks"; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  while IFS= read -r l; do
    case "$l" in ''|\#*) continue ;; esac
    sink_lines="$sink_lines$l"$'\n'
  done < "$f"
done

# --- Gather dependency manifests (the primary source for "what's present").
# Lockfiles are excluded — they're noisy with transitive dependencies. ---
manifest_re='(^|/)(package\.json|requirements[^/]*\.txt|pyproject\.toml|Pipfile|go\.mod|Gemfile)$'
manifest_body=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in *node_modules/*) continue ;; esac
  manifest_body="$manifest_body$(cat "$repo_root/$f" 2>/dev/null)"$'\n'
done < <(git ls-files | grep -E "$manifest_re" || true)

# --- Vendors this project has explicitly judged not to be live-fire ---
allow_keys=""
[ -f "$vendors_allow" ] && allow_keys=$(grep -vE '^\s*(#|$)' "$vendors_allow" 2>/dev/null || true)

violations=()
malformed=()
for vf in "$vendors_file" "$custom_vendors"; do
  [ -f "$vf" ] || continue
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    vendor=${line%%;;*}; rest=${line#*;;}
    presence=${rest%%;;*}; rest=${rest#*;;}
    coverage=${rest%%;;*}; category=${rest#*;;}
    [ -z "$vendor" ] || [ -z "$presence" ] && continue

    # An empty coverage field means `grep -E ""` — which matches every non-empty
    # line under POSIX — so an uncovered vendor would be silently reported as
    # "covered." Treat a blank coverage field as a malformed line and route it
    # to violations rather than letting a formatting mistake pass silently.
    if [ -z "$coverage" ]; then
      malformed+=("$vendor (malformed vendors.txt entry: empty coverage field)")
      continue
    fi

    # Is it in the dependency inventory?
    printf '%s' "$manifest_body" | grep -qiE "$presence" || continue
    # Has it been explicitly exempted?
    printf '%s\n' "$allow_keys" | grep -qxF "$vendor" && continue
    # Does the ledger already cover it?
    printf '%s' "$sink_lines" | grep -qiE "$coverage" && continue

    violations+=("$vendor ($category)")
  done < "$vf"
done

if [ "${#malformed[@]}" -gt 0 ]; then
  echo "Live-fire ledger coverage: live-fire-vendors.txt / .forge/vendors.txt has malformed entries:" >&2
  printf '%s\n' "${malformed[@]}" | sed 's/^/  - /' >&2
  echo "  Format: vendor;;presence;;coverage;;category (the coverage field must not be empty)" >&2
fi

if [ "${#violations[@]}" -gt 0 ] || [ "${#malformed[@]}" -gt 0 ]; then
  if [ "${#violations[@]}" -gt 0 ]; then
    echo "Live-fire ledger coverage: dependency manifests reference a live-fire vendor with no matching sink pattern:" >&2
    printf '%s\n' "${violations[@]}" | sed 's/^/  - /' >&2
  fi
  echo "" >&2
  echo "Options:" >&2
  echo "  (a) It's used for live-fire -> add a sink pattern for it to .forge/sinks.txt" >&2
  echo "      (no-live-fire-check.sh will then surface the actual call sites; build the allowlist there)" >&2
  echo "  (b) Installed but unused (dead weight) -> remove it from your dependencies (the best control is no path at all)" >&2
  echo "  (c) Not used for anything irreversible in this project (read-only API, etc.) -> add it to" >&2
  echo "      .forge/vendors-allow.txt with a reason. Entries without a reason get pulled at audit time" >&2
  exit 1
fi

echo "Live-fire ledger coverage: every live-fire vendor in the dependency manifests is covered by a sink pattern (pass)."
exit 0

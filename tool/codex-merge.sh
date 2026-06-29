#!/usr/bin/env bash
# codex-merge.sh — the ONLY sanctioned way to merge a PR into main.
#
# Verifies the Codex all-clear gate, then merges the EXACT head SHA the gate
# validated (via --match-head-commit), so a commit pushed between the check and
# the merge can't ride in unreviewed. Repo-redirecting flags are rejected so the
# gate and the merge always act on the same repository.
#
# Usage: bash tool/codex-merge.sh <pr-number> [extra gh pr merge args...]
set -uo pipefail

PR="${1:?usage: codex-merge.sh <pr-number> [gh pr merge args...]}"
shift || true
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for a in "$@"; do
  case "$a" in
    -R|--repo|-R=*|--repo=*|-R*)
      echo "codex-merge: refusing repo-redirecting flag '$a' (gate and merge must use the same repo)." >&2
      exit 1 ;;
    --auto|--auto=*)
      echo "codex-merge: refusing '--auto' — auto-merge can land a later, unreviewed SHA after the gate passed." >&2
      exit 1 ;;
    --match-head-commit|--match-head-commit=*)
      echo "codex-merge: refusing caller-supplied '--match-head-commit' — the wrapper sets it to the validated SHA." >&2
      exit 1 ;;
  esac
done

out="$(bash "$dir/codex-gate.sh" "$PR")" || { echo "$out" >&2; echo "codex-merge: refusing PR #$PR — gate not GREEN." >&2; exit 1; }
echo "$out" >&2

# Bind the merge to the exact SHA the gate validated.
sha="$(printf '%s' "$out" | sed -n 's/^GREEN \([0-9a-f]\{7,\}\):.*/\1/p' | head -1)"
[ -n "$sha" ] || { echo "codex-merge: could not extract the validated head SHA — aborting." >&2; exit 1; }

args=("$@")
[ ${#args[@]} -gt 0 ] || args=(--merge)
echo "codex-merge: gate GREEN — merging PR #$PR at $sha (${args[*]})." >&2
exec gh pr merge "$PR" --match-head-commit "$sha" "${args[@]}"

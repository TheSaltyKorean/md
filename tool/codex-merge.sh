#!/usr/bin/env bash
# codex-merge.sh — the ONLY sanctioned way to merge a PR into main.
#
# Verifies the Codex all-clear gate, then merges. The PreToolUse hook blocks raw
# `gh pr merge` / pushes to main, so all merges must go through here.
#
# Usage: bash tool/codex-merge.sh <pr-number> [extra gh pr merge args...]
#   e.g. bash tool/codex-merge.sh 4 --merge --delete-branch
set -uo pipefail

PR="${1:?usage: codex-merge.sh <pr-number> [gh pr merge args...]}"
shift || true
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! bash "$dir/codex-gate.sh" "$PR"; then
  echo "codex-merge: refusing to merge PR #$PR — gate is not GREEN (see reason above)." >&2
  exit 1
fi

args=("$@")
[ ${#args[@]} -gt 0 ] || args=(--merge)
echo "codex-merge: gate GREEN — merging PR #$PR (${args[*]})."
exec gh pr merge "$PR" "${args[@]}"

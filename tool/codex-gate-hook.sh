#!/usr/bin/env bash
# codex-gate-hook.sh — Claude Code PreToolUse hook.
#
# Blocks any attempt to merge a PR into `main` (or push to main) unless
# tool/codex-gate.sh confirms a genuine Codex all-clear for that PR. Wire it in
# .claude/settings.json as a PreToolUse hook for the Bash and PowerShell tools.
#
# Exit 0 = allow; exit 2 = block (stderr is shown to the agent).
set -uo pipefail

input="$(cat)"   # PreToolUse JSON; we grep it raw to avoid needing a JSON parser.

# Only gate merge-to-main actions.
if ! echo "$input" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge|/pulls/[0-9]+/merge|git[[:space:]]+push[^|]*\bmain\b'; then
  exit 0
fi

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the PR number from the command, else from the current branch.
pr="$(echo "$input" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1)"
[ -z "$pr" ] && pr="$(echo "$input" | grep -oE '/pulls/[0-9]+/merge' | grep -oE '[0-9]+' | head -1)"
[ -z "$pr" ] && pr="$(gh pr view --json number --jq .number 2>/dev/null || true)"

if [ -z "$pr" ]; then
  echo "codex-gate: refusing a merge/push to main — could not determine the PR to verify the Codex all-clear." >&2
  exit 2
fi

if out="$("$dir/codex-gate.sh" "$pr" 2>&1)"; then
  echo "codex-gate: $out — merge allowed." >&2
  exit 0
fi

echo "codex-gate: BLOCKED merge of PR #$pr." >&2
echo "$out" >&2
echo "Run the Codex loop to a 👍 first. If findings are intentionally accepted, the USER must approve, then add the 'codex-accepted' label to the PR." >&2
exit 2

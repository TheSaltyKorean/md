#!/usr/bin/env bash
# codex-gate-hook.sh — Claude Code PreToolUse hook (fail-closed).
#
# Blocks ALL raw PR merges and pushes to `main`. Merges must instead go through
# `tool/codex-merge.sh`, which enforces the Codex all-clear gate. This keeps the
# hook free of fragile selector parsing: it doesn't need to know which PR — it
# simply refuses every direct merge path.
#
# Wire in .claude/settings.json as a PreToolUse hook for the shell tools.
# Exit 0 = allow; exit 2 = block (stderr shown to the agent).
set -uo pipefail

input="$(cat)"   # PreToolUse JSON; grepped raw (no JSON parser needed).

raw_merge='gh[[:space:]]+pr[[:space:]]+merge|/pulls/[0-9]+/merge'
push_main='git[[:space:]]+push[^|&;]*\bmain\b'

# Allow the sanctioned wrapper through — but only when it's NOT also smuggling a
# raw merge/push in the same command (defends against comment-injection bypass).
if echo "$input" | grep -q 'codex-merge\.sh' \
   && ! echo "$input" | grep -Eq "$raw_merge|$push_main"; then
  exit 0
fi

if echo "$input" | grep -Eq "$raw_merge"; then
  echo "codex-gate: BLOCKED. Merge PRs only via: bash tool/codex-merge.sh <PR> [args]" >&2
  echo "(it verifies the Codex all-clear gate; raw 'gh pr merge' is not allowed)." >&2
  exit 2
fi

if echo "$input" | grep -Eq "$push_main"; then
  echo "codex-gate: BLOCKED. No direct pushes to main — open a PR and merge via tool/codex-merge.sh." >&2
  exit 2
fi

exit 0

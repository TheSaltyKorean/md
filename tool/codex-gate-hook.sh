#!/usr/bin/env bash
# codex-gate-hook.sh — Claude Code PreToolUse hook (defense-in-depth).
#
# Blocks raw PR merges and direct pushes to `main`. The sanctioned merge path is
# `bash tool/codex-merge.sh <PR>` (enforces the Codex gate) — it contains no
# merge/push tokens, so it passes this hook naturally and does the gating itself.
#
# Honest limitation: a PreToolUse hook only inspects the INITIAL shell command,
# not subprocesses, so it can't stop a script that internally runs `gh pr merge`.
# This is a fast local speed bump; the server-side `codex-gate` required check
# (branch protection on main) is the real guarantee.
#
# Exit 0 = allow; exit 2 = block.
set -uo pipefail

# Normalize newlines so multi-line commands can't slip a merge/push past grep.
input="$(cat | tr '\n\r' '  ')"
proj="${CLAUDE_PROJECT_DIR:-$PWD}"

# 'pr merge' regardless of gh global flags, plus the merge REST endpoint.
raw_merge='(^|[[:space:]])pr[[:space:]]+merge|/pulls/[0-9]+/merge'
# 'git ... push' allowing global options like `git -C dir push`.
push_re='git([[:space:]]+[^|&;[:space:]]+)*[[:space:]]+push'

# Block direct pushes to main first (independent of anything else in the line).
if echo "$input" | grep -Eq "$push_re"; then
  cur="$(git -C "$proj" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if echo "$input" | grep -Eq '\bmain\b' || [ "$cur" = "main" ]; then
    echo "codex-gate: BLOCKED. No direct pushes to main — open a PR and merge via tool/codex-merge.sh." >&2
    echo "(current branch: ${cur:-unknown})" >&2
    exit 2
  fi
fi

# Block raw merges; the wrapper has no 'pr merge' token so it isn't caught here.
if echo "$input" | grep -Eq "$raw_merge"; then
  echo "codex-gate: BLOCKED. Merge only via: bash tool/codex-merge.sh <PR> [args]  (enforces the Codex gate)." >&2
  exit 2
fi

exit 0

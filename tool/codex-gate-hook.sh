#!/usr/bin/env bash
# codex-gate-hook.sh — Claude Code PreToolUse hook (fail-closed, best-effort).
#
# Blocks raw PR merges and pushes to `main`. Merges must go through the exact
# wrapper `tool/codex-merge.sh`, which enforces the Codex all-clear gate.
#
# NOTE (honest limitation): a PreToolUse hook only inspects the *initial* shell
# command, not subprocesses it spawns. It therefore cannot stop a script that
# internally calls `gh pr merge`. This is a good-faith speed bump for agents in
# this repo, NOT a hard guarantee — only server-side branch protection is.
#
# Exit 0 = allow; exit 2 = block (stderr shown to the agent).
set -uo pipefail

input="$(cat)"
proj="${CLAUDE_PROJECT_DIR:-$PWD}"

# Match 'pr merge' regardless of gh global flags (e.g. `gh -R o/r pr merge`),
# and the merge REST endpoint.
raw_merge='(^|[[:space:]])pr[[:space:]]+merge|/pulls/[0-9]+/merge'
# Match 'git ... push' allowing global options like `git -C dir push`.
push_re='git([[:space:]]+[^|&;[:space:]]+)*[[:space:]]+push'

# Allow ONLY the sanctioned wrapper, invoked from the project root (no cd-
# redirection that could resolve a different relative script) and not smuggling
# a raw merge in the same command.
if echo "$input" | grep -Eq '(^|[[:space:]])(bash[[:space:]]+)?(\./)?tool/codex-merge\.sh([[:space:]]|$)' \
   && ! echo "$input" | grep -Eq "$raw_merge" \
   && ! echo "$input" | grep -Eq '(^|[[:space:]&;|])cd[[:space:]]'; then
  exit 0
fi

if echo "$input" | grep -Eq "$raw_merge"; then
  echo "codex-gate: BLOCKED. Merge only via: bash tool/codex-merge.sh <PR> [args]  (enforces the Codex gate)." >&2
  exit 2
fi

# Pushes: block any explicit main target, OR any push while on the main branch
# (a no-refspec push defaults to the upstream, i.e. main).
if echo "$input" | grep -Eq "$push_re"; then
  cur="$(git -C "$proj" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if echo "$input" | grep -Eq '\bmain\b' || [ "$cur" = "main" ]; then
    echo "codex-gate: BLOCKED. No direct pushes to main — open a PR and merge via tool/codex-merge.sh." >&2
    echo "(current branch: ${cur:-unknown})" >&2
    exit 2
  fi
fi

exit 0

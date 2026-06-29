#!/usr/bin/env bash
# codex-gate.sh — verify a PR has a genuine Codex all-clear before it may merge.
#
# Exit 0 (GREEN) only when ALL of:
#   * a "@codex review" request comment exists that is newer than the PR head
#     commit (i.e. the latest code was actually submitted for review), AND
#   * the Codex bot reacted 👍 to that request (its documented "no suggestions"
#     signal), AND
#   * Codex has not posted a review with findings after that request.
#
# Override: a PR labelled `codex-accepted` is treated as GREEN (a deliberate,
# visible human decision to merge with accepted findings — see CLAUDE.md).
#
# Exit 1 (RED) otherwise, printing the reason.
#
# Usage: tool/codex-gate.sh <pr-number> [owner/repo]
set -euo pipefail

PR="${1:?usage: codex-gate.sh <pr-number> [owner/repo]}"
REPO="${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
BOT="chatgpt-codex-connector[bot]"

red() { echo "RED: $1"; exit 1; }

# Override label = explicit accepted-findings decision.
if gh api "repos/$REPO/issues/$PR/labels" --jq '.[].name' 2>/dev/null | grep -qx "codex-accepted"; then
  echo "GREEN: 'codex-accepted' label present (accepted findings)."; exit 0
fi

head_date=$(gh api "repos/$REPO/pulls/$PR" --jq '.head.sha' \
  | xargs -I{} gh api "repos/$REPO/commits/{}" --jq '.commit.committer.date')
[ -n "$head_date" ] || red "could not read PR head commit date."

# Latest "@codex review" request comment.
req=$(gh api "repos/$REPO/issues/$PR/comments?per_page=100" \
  --jq "[.[] | select(.body | test(\"@codex\"; \"i\"))] | sort_by(.created_at) | last")
[ "$req" != "null" ] && [ -n "$req" ] || red "no '@codex review' request comment found."

req_id=$(echo "$req" | gh api --jq '.id' 2>/dev/null || echo "$req" | python -c 'import sys,json;print(json.load(sys.stdin)["id"])' 2>/dev/null || echo "")
req_date=$(echo "$req" | sed -n 's/.*"created_at":"\([^"]*\)".*/\1/p' | head -1)
req_id=$(echo "$req" | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)
[ -n "$req_id" ] && [ -n "$req_date" ] || red "could not parse the review request comment."

# The request must be newer than the latest pushed code.
[[ "$req_date" > "$head_date" ]] || red "newest '@codex review' request ($req_date) predates the head commit ($head_date) — re-request after pushing."

# A Codex review with findings after the request => not clear.
later_review=$(gh api "repos/$REPO/pulls/$PR/reviews" \
  --jq "[.[] | select(.user.login==\"$BOT\") | select(.submitted_at > \"$req_date\")] | length")
[ "${later_review:-0}" = "0" ] || red "Codex posted a review with findings after the latest request."

# The 👍 (or equivalent) reaction from the Codex bot = all-clear.
ok=$(gh api "repos/$REPO/issues/comments/$req_id/reactions" \
  --jq "[.[] | select(.user.login==\"$BOT\") | select(.content==\"+1\" or .content==\"hooray\" or .content==\"heart\" or .content==\"rocket\")] | length")
[ "${ok:-0}" != "0" ] || red "no Codex 👍 all-clear reaction on the latest review request yet."

echo "GREEN: Codex all-clear (👍) on request $req_id, no later findings."
exit 0

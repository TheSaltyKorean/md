#!/usr/bin/env bash
# codex-gate.sh — verify a PR has a genuine Codex all-clear before it may merge.
#
# GREEN (exit 0) only when ALL hold:
#   * a "@codex review" request comment exists that is NEWER than the PR head
#     commit (the final code was actually submitted for review), AND
#   * the Codex bot reacted with a literal 👍 (+1) to that request — its
#     documented "no suggestions" signal, AND
#   * Codex has not submitted a review (findings) after that request.
#
# Override: label `codex-accepted` permits merging WITH findings, but ONLY if
# Codex still reviewed the current head (a 👍 or a review after the latest
# request) — so new commits can't ride in unreviewed behind an old label.
#
# RED (exit 1) otherwise, with the reason.
# Usage: tool/codex-gate.sh <pr-number> [owner/repo]
set -uo pipefail

PR="${1:?usage: codex-gate.sh <pr-number> [owner/repo]}"
REPO="${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
BOT="chatgpt-codex-connector[bot]"
red() { echo "RED: $1"; exit 1; }

head_sha="$(gh api "repos/$REPO/pulls/$PR" --jq '.head.sha' 2>/dev/null)"
[ -n "$head_sha" ] || red "could not read PR #$PR head SHA."
head_date="$(gh api "repos/$REPO/commits/$head_sha" --jq '.commit.committer.date' 2>/dev/null)"
[ -n "$head_date" ] || red "could not read head commit date."

# Latest "@codex review" request, across ALL pages (stream items, then pick max).
latest="$(gh api --paginate "repos/$REPO/issues/$PR/comments" \
  --jq '.[] | select((.body|test("@codex";"i")) and (.body|test("review";"i"))) | "\(.created_at)\t\(.id)"' \
  2>/dev/null | sort | tail -1)"
[ -n "$latest" ] || red "no '@codex review' request comment found."
req_date="${latest%%$'\t'*}"
req_id="${latest##*$'\t'}"

# The request must post-date the latest pushed code.
[[ "$req_date" > "$head_date" ]] || \
  red "newest '@codex review' ($req_date) is not after the head commit ($head_date) — re-request review after pushing."

# Codex reviews submitted after the request (findings).
later_reviews="$(gh api --paginate "repos/$REPO/pulls/$PR/reviews" \
  --jq ".[] | select(.user.login==\"$BOT\") | .submitted_at" 2>/dev/null \
  | awk -v d="$req_date" 'length($0) && $0 > d' | wc -l | tr -d ' ')"

# Literal 👍 (+1) from the Codex bot on the request.
thumbs="$(gh api --paginate "repos/$REPO/issues/comments/$req_id/reactions" \
  --jq ".[] | select(.user.login==\"$BOT\") | .content" 2>/dev/null \
  | grep -cx '+1' | tr -d ' ')"

reviewed_head=$(( ${later_reviews:-0} + ${thumbs:-0} ))

if gh api --paginate "repos/$REPO/issues/$PR/labels" --jq '.[].name' 2>/dev/null | grep -qx 'codex-accepted'; then
  [ "$reviewed_head" -gt 0 ] || \
    red "'codex-accepted' is set but Codex has not reviewed the current head (no 👍 or review after the latest request)."
  echo "GREEN: accepted findings ('codex-accepted'); Codex reviewed the current head (req $req_id)."
  exit 0
fi

[ "${later_reviews:-0}" -eq 0 ] || red "Codex submitted a review with findings after the latest request."
[ "${thumbs:-0}" -gt 0 ] || red "no literal Codex 👍 (+1) all-clear on the latest review request yet."

echo "GREEN: Codex all-clear (👍) on request $req_id; no later findings."
exit 0

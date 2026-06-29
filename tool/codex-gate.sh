#!/usr/bin/env bash
# codex-gate.sh — verify a PR has a genuine Codex all-clear before it may merge.
#
# GREEN (exit 0) prints "GREEN <head-sha>: ..." only when ALL hold:
#   * a "@codex review" request comment exists that is NEWER than the head
#     commit, AND
#   * the Codex bot reacted with a literal 👍 (+1) to that request, AND
#   * Codex has not submitted a review (findings) after that request.
# Every GitHub API call is fail-closed: a failure => RED.
#
# Override: label `codex-accepted` permits merging WITH findings, but only if
# Codex's latest review is on the CURRENT head SHA (so new commits can't ride in
# behind a stale label). Re-apply the label after any new Codex review.
#
# RED (exit 1) otherwise. Usage: tool/codex-gate.sh <pr> [owner/repo]
set -uo pipefail

PR="${1:?usage: codex-gate.sh <pr-number> [owner/repo]}"
REPO="${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}"
BOT="chatgpt-codex-connector[bot]"
red() { echo "RED: $1"; exit 1; }
api() { gh api "$@" 2>/dev/null || return 1; }

[ -n "$REPO" ] || red "could not determine repository."

head_sha="$(api "repos/$REPO/pulls/$PR" --jq '.head.sha')" || red "PR lookup failed (fail-closed)."
[ -n "$head_sha" ] || red "could not read PR #$PR head SHA."
head_date="$(api "repos/$REPO/commits/$head_sha" --jq '.commit.committer.date')" || red "head commit lookup failed."
[ -n "$head_date" ] || red "could not read head commit date."

# Latest "@codex review" request across all pages.
comments="$(api --paginate "repos/$REPO/issues/$PR/comments" \
  --jq '.[] | select((.body|test("@codex";"i")) and (.body|test("review";"i"))) | "\(.created_at)\t\(.id)"')" \
  || red "comments lookup failed (fail-closed)."
latest="$(printf '%s\n' "$comments" | grep -v '^$' | sort | tail -1)"
[ -n "$latest" ] || red "no '@codex review' request comment found."
req_date="${latest%%$'\t'*}"
req_id="${latest##*$'\t'}"

[[ "$req_date" > "$head_date" ]] || \
  red "newest '@codex review' ($req_date) is not after the head commit ($head_date) — re-request review after pushing."

# Codex reviews after the request (findings), with the SHA each was made on.
reviews="$(api --paginate "repos/$REPO/pulls/$PR/reviews" \
  --jq ".[] | select(.user.login==\"$BOT\") | \"\(.submitted_at)\t\(.commit_id)\"")" \
  || red "reviews lookup failed (fail-closed)."
later_reviews="$(printf '%s\n' "$reviews" | awk -F'\t' -v d="$req_date" 'length($1) && $1 > d' | wc -l | tr -d ' ')"
latest_review_sha="$(printf '%s\n' "$reviews" | grep -v '^$' | sort | tail -1 | cut -f2)"

# Literal 👍 (+1) from the Codex bot on the request.
reacts="$(api --paginate "repos/$REPO/issues/comments/$req_id/reactions" \
  --jq ".[] | select(.user.login==\"$BOT\") | .content")" || red "reactions lookup failed (fail-closed)."
thumbs="$(printf '%s\n' "$reacts" | grep -cx '+1' | tr -d ' ')"

if api --paginate "repos/$REPO/issues/$PR/labels" --jq '.[].name' | grep -qx 'codex-accepted'; then
  [ "$latest_review_sha" = "$head_sha" ] || \
    red "'codex-accepted' is set but Codex's latest review is not on the current head ($head_sha) — re-review and re-accept."
  echo "GREEN $head_sha: accepted findings ('codex-accepted') on the current head (req $req_id)."
  exit 0
fi

[ "${later_reviews:-0}" -eq 0 ] || red "Codex submitted a review with findings after the latest request."
[ "${thumbs:-0}" -gt 0 ] || red "no literal Codex 👍 (+1) all-clear on the latest review request yet."

echo "GREEN $head_sha: Codex all-clear (👍) on request $req_id; no later findings."
exit 0

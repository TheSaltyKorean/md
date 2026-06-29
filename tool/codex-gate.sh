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

# Latest "@codex review" request across all pages. Exclude the Codex bot itself:
# its review comments contain "@codex review" boilerplate and must never be
# mistaken for the human request that authorises the review.
comments="$(api --paginate "repos/$REPO/issues/$PR/comments" \
  --jq ".[] | select(.user.login != \"$BOT\") | select((.body|test(\"@codex\";\"i\")) and (.body|test(\"review\";\"i\"))) | \"\(.created_at)\t\(.id)\"")" \
  || red "comments lookup failed (fail-closed)."
latest="$(printf '%s\n' "$comments" | grep -v '^$' | sort | tail -1)"
[ -n "$latest" ] || red "no '@codex review' request comment found."
req_date="${latest%%$'\t'*}"
req_id="${latest##*$'\t'}"

# NOTE (residual limitation): this compares against the head commit's committer
# date, not the moment that SHA became the PR head. A crafted local commit with a
# back-dated committer time pushed after an old 👍 could slip past this single
# check. The findings path below binds acceptance/review to the exact head SHA;
# the clean-👍 path can't (reactions carry no SHA), so this date check is the
# best available proxy there. The server-side gate (trusted base ref) is the
# real guarantee.
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

# Comment-based all-clear: Codex signals a clean review by posting a comment such
# as "Codex Review: Didn't find any major issues" that names the reviewed commit
# ("Reviewed commit: <sha>"). Only the Codex bot can author a comment as $BOT, so
# this is trustworthy. To accept it we require ALL of:
#   * the comment is NEWER than the latest request (a fresh response to it, not a
#     stale clean comment carried over from an earlier cycle), AND
#   * the SHA parsed from its "Reviewed commit:" line is a prefix of the CURRENT
#     head SHA (exact binding, not a loose substring search anywhere in the body).
# Combined with the "no findings after the request" check below, a re-requested
# review can't go green on a stale clean comment.
clean_lines="$(api --paginate "repos/$REPO/issues/$PR/comments" \
  --jq ".[] | select(.user.login==\"$BOT\") | select(.body|test(\"find any major issues|no major issues\";\"i\")) | \"\(.created_at)\t\" + (.body|gsub(\"[\\n\\r]+\";\" \"))")" \
  || red "clean-review comment lookup failed (fail-closed)."
clean_on_head=0
while IFS=$'\t' read -r cdate cbody; do
  [ -n "$cdate" ] || continue
  [[ "$cdate" > "$req_date" ]] || continue   # fresh: posted after the latest request
  rsha="$(printf '%s' "$cbody" \
    | sed -nE 's/.*[Rr]eviewed[[:space:]_]*commit[^0-9a-fA-F]*([0-9a-fA-F]{7,40}).*/\1/p' | head -1)"
  [ -n "$rsha" ] || continue
  case "$head_sha" in "$rsha"*) clean_on_head=1; break;; esac
done <<EOF
$clean_lines
EOF

latest_review_date="$(printf '%s\n' "$reviews" | grep -v '^$' | sort | tail -1 | cut -f1)"

if api --paginate "repos/$REPO/issues/$PR/labels" --jq '.[].name' | grep -qx 'codex-accepted'; then
  # The accepted findings must be on the CURRENT head…
  [ "$latest_review_sha" = "$head_sha" ] || \
    red "'codex-accepted' is set but Codex's latest review is not on the current head ($head_sha) — re-review and re-accept."
  # …and the acceptance must be FRESH: the label was (re)applied after the latest
  # Codex review (so new findings can't ride in under a stale label).
  label_time="$(api --paginate "repos/$REPO/issues/$PR/timeline" \
    --jq '.[] | select(.event=="labeled" and .label.name=="codex-accepted") | .created_at' \
    2>/dev/null | grep -v '^$' | sort | tail -1)" || red "timeline lookup failed (fail-closed)."
  [ -n "$label_time" ] || red "'codex-accepted' present but no labeling event found."
  if [ -n "$latest_review_date" ]; then
    [[ "$label_time" > "$latest_review_date" ]] || \
      red "'codex-accepted' ($label_time) predates the latest Codex review ($latest_review_date) — re-accept after the new review."
  fi
  echo "GREEN $head_sha: accepted findings ('codex-accepted', re-accepted after the latest review)."
  exit 0
fi

[ "${later_reviews:-0}" -eq 0 ] || red "Codex submitted a review with findings after the latest request."

if [ "${thumbs:-0}" -gt 0 ]; then
  echo "GREEN $head_sha: Codex all-clear (👍 reaction) on request $req_id; no later findings."
  exit 0
fi
if [ "${clean_on_head:-0}" -gt 0 ]; then
  echo "GREEN $head_sha: Codex all-clear (fresh clean-review comment whose 'Reviewed commit' is the head); no later findings."
  exit 0
fi
red "no Codex all-clear yet: neither a 👍 reaction nor a fresh clean-review comment whose 'Reviewed commit' matches the current head."

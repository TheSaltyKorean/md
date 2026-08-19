#!/usr/bin/env bash
# Push changed URLs to IndexNow, which feeds Bing (and Yandex, Naver, Seznam).
#
# Google does NOT consume IndexNow — it still discovers changes by crawling the
# sitemap. This is purely the Bing-side fast path: instead of waiting for a
# recrawl, it tells Bing "these URLs changed, come look now".
#
# The key is proven by hosting it as a text file at the site root; the file's
# only content is the key itself. Do not delete docs/<key>.txt — IndexNow
# re-checks it on every submission.
#
# Usage:
#   bash tool/indexnow.sh                 # submit every URL in the sitemap
#   bash tool/indexnow.sh /print-profiles.html /  # submit specific paths
set -euo pipefail

HOST="markdownstudio.dev"
KEY="0f87e00326bb915ddcf83a1d69619b04"
KEY_LOCATION="https://$HOST/$KEY.txt"

if [ $# -gt 0 ]; then
  urls=()
  for p in "$@"; do
    case "$p" in
      https://*) urls+=("$p") ;;
      /*)        urls+=("https://$HOST$p") ;;
      *)         urls+=("https://$HOST/$p") ;;
    esac
  done
else
  # Pull the canonical list straight from the sitemap so the two never drift.
  mapfile -t urls < <(curl -fsS "https://$HOST/sitemap.xml" \
    | grep -oE '<loc>[^<]+</loc>' | sed -E 's#</?loc>##g')
fi

if [ ${#urls[@]} -eq 0 ]; then
  echo "no URLs to submit" >&2
  exit 1
fi

# Verify the key file is actually reachable before submitting; IndexNow
# rejects the whole batch with 403 if it cannot fetch the key.
if ! curl -fsS "$KEY_LOCATION" | grep -qx "$KEY"; then
  echo "ERROR: key file at $KEY_LOCATION is missing or does not contain the key." >&2
  echo "IndexNow would reject this submission with 403. Not submitting." >&2
  exit 1
fi

payload=$(printf '%s\n' "${urls[@]}" | python3 -c '
import json, sys
urls = [l.strip() for l in sys.stdin if l.strip()]
print(json.dumps({
    "host": "'"$HOST"'",
    "key": "'"$KEY"'",
    "keyLocation": "'"$KEY_LOCATION"'",
    "urlList": urls,
}))')

echo "Submitting ${#urls[@]} URL(s) to IndexNow:"
printf '  %s\n' "${urls[@]}"

code=$(curl -sS -o /tmp/indexnow.out -w '%{http_code}' \
  -X POST "https://api.indexnow.org/indexnow" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data "$payload")

echo "HTTP $code"
case "$code" in
  200|202) echo "accepted" ;;
  *)       echo "REJECTED — response body:"; cat /tmp/indexnow.out; exit 1 ;;
esac

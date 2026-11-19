#!/usr/bin/env bash
# Verify a Redmine issue page still renders after a description / note write.
# Textile mistakes return 200/204 from the JSON API but 500 on the live page.
# See "Description / notes (Textile)" in SKILL.md.
#
# usage: check-issue-html.sh <issue-id> [--expect 200]
#
# Exit codes:
#   0  page returned the expected code
#   1  page did not render (fix the Textile; do not create a new issue)
#   64 bad usage
set -euo pipefail

ID=""
EXPECT=200
while [ $# -gt 0 ]; do
  case "$1" in
    --expect) shift; EXPECT="${1:-}" ;;
    -*) echo "unknown flag: $1" >&2; exit 64 ;;
    *) ID="$1" ;;
  esac
  shift
done
[ -n "$ID" ] || { echo "usage: check-issue-html.sh <issue-id> [--expect 200]" >&2; exit 64; }

# Agent shells usually skip ~/.bashrc; credentials are never echoed.
if [ -z "${REDMINE_API_KEY:-}" ] || [ -z "${REDMINE_SERVER:-}" ]; then
  eval "$(grep -E '^export REDMINE_' "$HOME/.profile")"
fi

CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
  "${REDMINE_SERVER}/issues/${ID}")"

echo "issue #${ID}: HTTP ${CODE} (expect ${EXPECT})"
if [ "$CODE" = "$EXPECT" ]; then
  exit 0
fi
if [ "$CODE" = "500" ]; then
  echo "page 500: fix the Textile (see SKILL.md), do not create a new issue" >&2
else
  echo "page returned ${CODE}: check the issue id and access rights" >&2
fi
exit 1

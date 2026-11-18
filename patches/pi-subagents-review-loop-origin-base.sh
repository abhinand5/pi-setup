#!/usr/bin/env bash
# Give the packaged `/review-loop` prompt a rule about the diff base.
#
# `pi-subagents` ships `prompts/review-loop.md` as a Pi prompt template. The parent passes
# `BASE=<epic-branch>` and builds the artifact with `git diff "$BASE"...HEAD` — a *local* ref. A local
# branch lags silently, so the artifact carries commits the base does not have and misses ones it does.
# On 2026-11-17 a review of #15702 was taken against a local `main` two commits behind `origin/main`:
# the artifact included an unrelated #175 fix and the 0.28.8 release files, and both reviewers spent a
# P1 on "дифф против устаревшего main" (#15733 п.2). The repository canon and the project reviewer
# agent already say `origin/<base>`; the packaged prompt said nothing at all.
#
# Pi reinstalls npm packages on `pi install` / `pi update --extensions`, so the edit lives here and
# `install.sh` re-applies it. The inserted paragraph is project-neutral: a repository whose base has
# no remote-tracking ref keeps working, because the block names the fallback explicitly.
#
# Usage:
#   ./patches/pi-subagents-review-loop-origin-base.sh            # apply
#   ./patches/pi-subagents-review-loop-origin-base.sh --check    # exit 1 if the patch is missing
#   ./patches/pi-subagents-review-loop-origin-base.sh --dry-run  # show what would change

set -euo pipefail

DRY_RUN=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PI_HOME="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PROMPT="$PI_HOME/npm/node_modules/pi-subagents/prompts/review-loop.md"

# Строка, по которой видно, что абзац уже вставлен: ищем её, а не весь текст, чтобы
# правка формулировки не плодила второй абзац.
MARKER='The artifact under review is taken against `origin/<base>`'

# `origin/<base>` назван явно, фолбэк — тоже: иначе репозиторий без remote-tracking ref получил бы
# пустой дифф и «нашлось ноль проблем» вместо находок.
BLOCK='The artifact under review is taken against `origin/<base>`, not the local base branch: a local branch lags silently, so a diff against it carries commits the base does not have and misses ones it does. Fetch and diff against `origin/<base>` (`git diff origin/<base>...HEAD`); fall back to the local ref only when the remote-tracking ref is missing, and say so in the report.'

# Абзац про запуск ревьюеров: вставка идёт сразу после него.
ANCHOR='They must not rely on the main conversation history and must not edit files.'

if [[ ! -f "$PROMPT" ]]; then
  echo "pi-subagents-review-loop-origin-base: pi-subagents is not installed under $PI_HOME/npm; nothing to patch."
  exit 0
fi

if grep -qF "$MARKER" "$PROMPT"; then
  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "pi-subagents-review-loop-origin-base: OK — rule present in $PROMPT"
  else
    echo "pi-subagents-review-loop-origin-base: already patched, nothing to do."
  fi
  exit 0
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
  echo "pi-subagents-review-loop-origin-base: MISSING — $PROMPT has no origin/<base> rule." >&2
  exit 1
fi

if ! grep -qF "$ANCHOR" "$PROMPT"; then
  echo "pi-subagents-review-loop-origin-base: anchor paragraph not found in $PROMPT." >&2
  echo "The upstream prompt changed; re-read it and move ANCHOR before re-applying." >&2
  exit 3
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "would insert into $PROMPT:"
  echo "  $BLOCK"
  exit 0
fi

MARKER="$MARKER" BLOCK="$BLOCK" ANCHOR="$ANCHOR" PROMPT="$PROMPT" python3 - <<'PY'
import io
import os

path = os.environ['PROMPT']
anchor = os.environ['ANCHOR']
block = os.environ['BLOCK']

text = io.open(path, encoding='utf-8').read()
if os.environ['MARKER'] in text:
    raise SystemExit(0)
if anchor not in text:
    raise SystemExit(3)

text = text.replace(anchor, anchor + '\n\n' + block + '\n', 1)
io.open(path, 'w', encoding='utf-8').write(text)
PY

echo "pi-subagents-review-loop-origin-base: patched $PROMPT"

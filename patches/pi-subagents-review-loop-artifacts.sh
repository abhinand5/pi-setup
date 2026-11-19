#!/usr/bin/env bash
# Give the packaged `/review-loop` prompt two rules about losing reviewer output.
#
# 1. Every reviewer gets `output:` — a file that holds its report. On 2026-11-19 a parallel round of
#    three reviewers failed as a whole (`task-1 (reviewer) failed: bash failed (exit 1)`), and the
#    report of the child that finished was gone with the mission: both reviews were repeated
#    (#15836 п.1). In the same session a 30-minute round timed out with no artifact at all —
#    `subagent({action:"status"})` answers "Async run not found" and the completion-replay files
#    belonged to an earlier session (#15834 п.2).
# 2. A reviewer must not pipe `git` output into `head`/`tail`. The pipe closes early, the reviewer
#    dies on SIGPIPE with exit 1, and the round loses it — the failure in (1) was exactly that.
#
# Pi reinstalls npm packages on `pi install` / `pi update --extensions`, so the edit lives here and
# `install.sh` re-applies it. The inserted paragraphs are project-neutral.
#
# Usage:
#   ./patches/pi-subagents-review-loop-artifacts.sh            # apply
#   ./patches/pi-subagents-review-loop-artifacts.sh --check    # exit 1 if the patch is missing
#   ./patches/pi-subagents-review-loop-artifacts.sh --dry-run  # show what would change

set -euo pipefail

DRY_RUN=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PI_HOME="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PROMPT="$PI_HOME/npm/node_modules/pi-subagents/prompts/review-loop.md"

# Строка, по которой видно, что абзац уже вставлен: ищем её, а не весь текст, чтобы правка
# формулировки не плодила второй абзац.
MARKER='Pass `output:` to every reviewer'

# Абзац про запуск ревьюеров: вставка идёт сразу после него (та же точка, что у патча scope).
ANCHOR='They must not rely on the main conversation history and must not edit files.'

BLOCK='Pass `output:` to every reviewer — a path such as `reviewer-<angle>.md` — and treat that file as the report. When one child fails or the round times out, the reports of the children that already finished must still be readable: a failed mission that discards them costs the whole round. Set the round deadline with enough margin that a reviewer finishing near the end still writes its file, and tell each reviewer to write the report as its last action before returning.'
BLOCK="$BLOCK"$'\n\n''Reviewers must not pipe `git` output into `head`, `tail`, or anything else that exits early: the reviewer dies on SIGPIPE with `bash failed (exit 1)` and the round loses it. Write the log to a file and read the part you need.'

if [[ ! -f "$PROMPT" ]]; then
  echo "pi-subagents-review-loop-artifacts: pi-subagents is not installed under $PI_HOME/npm; nothing to patch."
  exit 0
fi

if grep -qF "$MARKER" "$PROMPT"; then
  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "pi-subagents-review-loop-artifacts: OK — rule present in $PROMPT"
  else
    echo "pi-subagents-review-loop-artifacts: already patched, nothing to do."
  fi
  exit 0
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
  echo "pi-subagents-review-loop-artifacts: MISSING — $PROMPT has no reviewer-output rule." >&2
  exit 1
fi

if ! grep -qF "$ANCHOR" "$PROMPT"; then
  echo "pi-subagents-review-loop-artifacts: anchor paragraph not found in $PROMPT." >&2
  echo "The upstream prompt changed; re-read it and move ANCHOR before re-applying." >&2
  exit 3
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "would insert into $PROMPT:"
  printf '%s\n' "$BLOCK"
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

echo "pi-subagents-review-loop-artifacts: patched $PROMPT"

#!/usr/bin/env bash
# Give the packaged `/review-loop` prompt three rules about reviewer output.
#
# 1. Every reviewer gets `output:` — a file that holds its report. On 2026-11-19 a parallel round of
#    three reviewers failed as a whole (`task-1 (reviewer) failed: bash failed (exit 1)`), and the
#    report of the child that finished was gone with the mission: both reviews were repeated
#    (#15836 п.1). In the same session a 30-minute round timed out with no artifact at all —
#    `subagent({action:"status"})` answers "Async run not found" and the completion-replay files
#    belonged to an earlier session (#15834 п.2).
# 2. A reviewer must not pipe `git` output into `head`/`tail`. The pipe closes early, the reviewer
#    dies on SIGPIPE with exit 1, and the round loses it — the failure in (1) was exactly that.
# 3. The file is the report, and the answer is not a second copy of it: the response names the path
#    and gives the verdict in three lines. `output:` alone did not stop the text from coming back
#    too — nine reports over four rounds of #15874 were 154 KB in the parent's context, and the
#    files already held every word (#15874 п.3).
#
# Pi reinstalls npm packages on `pi install` / `pi update --extensions`, so the edit lives here and
# `install.sh` re-applies it. The inserted paragraphs are project-neutral.
#
# Each rule has its own marker and is applied independently: a machine patched before rule 3 existed
# already carries the first two paragraphs, and a single marker would make the new rule skip.
#
# Usage:
#   ./patches/pi-subagents-review-loop-artifacts.sh            # apply
#   ./patches/pi-subagents-review-loop-artifacts.sh --check    # exit 1 if a rule is missing
#   ./patches/pi-subagents-review-loop-artifacts.sh --dry-run  # show what would change

set -euo pipefail

DRY_RUN=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PI_HOME="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PROMPT="$PI_HOME/npm/node_modules/pi-subagents/prompts/review-loop.md"

# Строки, по которым видно, что абзац уже вставлен: ищем маркер, а не весь текст, чтобы правка
# формулировки не плодила второй абзац.
MARKER_OUTPUT='Pass `output:` to every reviewer'
MARKER_ANSWER='The `output:` file is the report; the answer carries only its path'

# Абзац про запуск ревьюеров: вставка идёт сразу после него (та же точка, что у патчей scope и
# origin-base).
ANCHOR_ROUND='They must not rely on the main conversation history and must not edit files.'
# Абзац правила 1: правило 3 дописывается после его последней строки, чтобы путь и вердикт читались
# рядом с требованием передать `output:`.
ANCHOR_WRITE='tell each reviewer to write the report as its last action before returning.'

BLOCK_OUTPUT='Pass `output:` to every reviewer — a path such as `reviewer-<angle>.md` — and treat that file as the report. When one child fails or the round times out, the reports of the children that already finished must still be readable: a failed mission that discards them costs the whole round. Set the round deadline with enough margin that a reviewer finishing near the end still writes its file, and tell each reviewer to write the report as its last action before returning.'
BLOCK_OUTPUT="$BLOCK_OUTPUT"$'\n\n''Reviewers must not pipe `git` output into `head`, `tail`, or anything else that exits early: the reviewer dies on SIGPIPE with `bash failed (exit 1)` and the round loses it. Write the log to a file and read the part you need.'

BLOCK_ANSWER='The `output:` file is the report; the answer carries only its path and a verdict in at most three lines — pass or fail, findings by severity, and the one line that changes the decision. The report text does not come back in the answer: nine reports over four rounds of #15874 cost the parent 154 KB while the files already held every word. The parent reads the file when it needs the details.'

if [[ ! -f "$PROMPT" ]]; then
  echo "pi-subagents-review-loop-artifacts: pi-subagents is not installed under $PI_HOME/npm; nothing to patch."
  exit 0
fi

missing=0
patched=0
failed=0

# apply_rule <name> <marker> <anchor> <block>
apply_rule() {
  local marker="$2" anchor="$3" block="$4"

  if grep -qF "$marker" "$PROMPT"; then
    return 0
  fi

  missing=1

  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "pi-subagents-review-loop-artifacts: MISSING — '$marker' is not in $PROMPT." >&2
    return 0
  fi

  if ! grep -qF "$anchor" "$PROMPT"; then
    echo "pi-subagents-review-loop-artifacts: anchor paragraph not found in $PROMPT." >&2
    echo "The upstream prompt changed; re-read it and move the anchor before re-applying." >&2
    failed=1
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would insert into $PROMPT:"
    printf '%s\n' "$block"
    patched=1
    return 0
  fi

  MARKER="$marker" BLOCK="$block" ANCHOR="$anchor" PROMPT="$PROMPT" python3 - <<'PY'
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

  echo "pi-subagents-review-loop-artifacts: inserted a rule into $PROMPT"
  patched=1
}

apply_rule artifacts "$MARKER_OUTPUT" "$ANCHOR_ROUND" "$BLOCK_OUTPUT"
apply_rule answer "$MARKER_ANSWER" "$ANCHOR_WRITE" "$BLOCK_ANSWER"

if [[ "$failed" == "1" ]]; then
  exit 3
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
  if [[ "$missing" == "1" ]]; then
    exit 1
  fi
  echo "pi-subagents-review-loop-artifacts: OK — both rules present in $PROMPT"
  exit 0
fi

if [[ "$DRY_RUN" != "1" && "$patched" == "0" ]]; then
  echo "pi-subagents-review-loop-artifacts: already patched, nothing to do."
fi

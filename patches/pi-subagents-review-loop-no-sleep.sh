#!/usr/bin/env bash
# Give the packaged `/review-loop` prompt a rule about waiting for children.
#
# `pi-subagents` ships `prompts/review-loop.md`. It says plenty about launching reviewers asynchronously
# and about reading their reports, but nothing about what the parent does *while* they run. In practice
# the parent sat in a `sleep` loop: 17 `sleep` calls and 4415 seconds of waiting in one session
# (#15865 п.1, ретро #15812), although an async child returns control by itself and wakes the loop when
# it finishes. The repository canon (`.claude/commands/review-inline.md`) and `implement-plan` §7 now say
# "верни управление, не спи"; the packaged prompt said nothing at all.
#
# Pi reinstalls npm packages on `pi install` / `pi update --extensions`, so the edit lives here and
# `install.sh` re-applies it. The inserted paragraph is project-neutral: it names no repository, no
# branch and no tool beyond `sleep`.
#
# Usage:
#   ./patches/pi-subagents-review-loop-no-sleep.sh            # apply
#   ./patches/pi-subagents-review-loop-no-sleep.sh --check    # exit 1 if the patch is missing
#   ./patches/pi-subagents-review-loop-no-sleep.sh --dry-run  # show what would change

set -euo pipefail

DRY_RUN=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PI_HOME="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PROMPT="$PI_HOME/npm/node_modules/pi-subagents/prompts/review-loop.md"

# Строка, по которой видно, что абзац уже вставлен: ищем маркер, а не весь текст, чтобы правка
# формулировки не плодила второй абзац.
MARKER='While a child runs, do not sit in a wait loop'

BLOCK='While a child runs, do not sit in a wait loop: no `sleep`, no repeated status polls. An async child hands control back to me by itself and wakes the loop when it finishes, so the parent returning control costs nothing and lets me steer; a `sleep`-driven parent buys the same wall-clock while holding the turn, and it cannot react when a child goes quiet instead of finishing. If a round has to wait, wait on the child (async completion), not on the clock.'

# Абзац про одновременных писателей и изолированные worktree: вставка идёт сразу после него.
ANCHOR='Use only one writer against the active worktree at a time unless I explicitly ask for isolated worktrees.'

if [[ ! -f "$PROMPT" ]]; then
  echo "pi-subagents-review-loop-no-sleep: pi-subagents is not installed under $PI_HOME/npm; nothing to patch."
  exit 0
fi

if grep -qF "$MARKER" "$PROMPT"; then
  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "pi-subagents-review-loop-no-sleep: OK — rule present in $PROMPT"
  else
    echo "pi-subagents-review-loop-no-sleep: already patched, nothing to do."
  fi
  exit 0
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
  echo "pi-subagents-review-loop-no-sleep: MISSING — $PROMPT has no rule about waiting for children." >&2
  exit 1
fi

if ! grep -qF "$ANCHOR" "$PROMPT"; then
  echo "pi-subagents-review-loop-no-sleep: anchor paragraph not found in $PROMPT." >&2
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

echo "pi-subagents-review-loop-no-sleep: patched $PROMPT"

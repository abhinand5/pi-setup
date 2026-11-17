#!/usr/bin/env bash
# Give the packaged `/review-loop` prompt a rule about sibling worktrees.
#
# `pi-subagents` ships `prompts/review-loop.md` as a Pi prompt template. The parent
# passes `cwd` to every reviewer, but the prompt never says that a sibling worktree
# of the same repository holds another session's uncommitted work, and
# `git worktree list` actively invites the detour. On 2026-11-16 a reviewer did
# `cd .claude/worktrees/15659-agent-env-gates` and reported 13 dirty files of that
# session as findings about the diff it was given (#15674 п.3).
#
# Pi reinstalls npm packages on `pi install` / `pi update --extensions`, so the edit
# lives here and `install.sh` re-applies it. The inserted paragraph is
# project-neutral: a repository without `.claude/worktrees/` loses nothing.
#
# Usage:
#   ./patches/pi-subagents-review-loop-scope.sh            # apply
#   ./patches/pi-subagents-review-loop-scope.sh --check    # exit 1 if the patch is missing
#   ./patches/pi-subagents-review-loop-scope.sh --dry-run  # show what would change

set -euo pipefail

DRY_RUN=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PI_HOME="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PROMPT="$PI_HOME/npm/node_modules/pi-subagents/prompts/review-loop.md"

# Строка, по которой видно, что абзац уже вставлен: ищем её, а не весь текст, чтобы
# правка формулировки не плодила второй абзац.
MARKER='A sibling worktree of this repository'

# Путь к соседним воркдеревам намеренно не назван: у каждого репозитория он свой
# (`.claude/worktrees/<имя>`, `../msb-calculator-api-wt/<имя>`), и конкретный путь живёт
# в проектном `.pi/agents/reviewer.md`.
BLOCK='Scope each reviewer to the directory it was given. A sibling worktree of this repository — wherever this checkout keeps them — holds another session'"'"'s uncommitted work: reviewers must not read it, quote it, or count it as part of the target diff. Passing `cwd` is not enough on its own — `git worktree list` invites the detour, and a reviewer that takes it reports another session'"'"'s dirty files as findings about the current diff.'

# Абзац про запуск ревьюеров: вставка идёт сразу после него.
ANCHOR='They must not rely on the main conversation history and must not edit files.'

if [[ ! -f "$PROMPT" ]]; then
  echo "pi-subagents-review-loop-scope: pi-subagents is not installed under $PI_HOME/npm; nothing to patch."
  exit 0
fi

if grep -qF "$MARKER" "$PROMPT"; then
  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "pi-subagents-review-loop-scope: OK — rule present in $PROMPT"
  else
    echo "pi-subagents-review-loop-scope: already patched, nothing to do."
  fi
  exit 0
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
  echo "pi-subagents-review-loop-scope: MISSING — $PROMPT has no sibling-worktree rule." >&2
  exit 1
fi

if ! grep -qF "$ANCHOR" "$PROMPT"; then
  echo "pi-subagents-review-loop-scope: anchor paragraph not found in $PROMPT." >&2
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

echo "pi-subagents-review-loop-scope: patched $PROMPT"

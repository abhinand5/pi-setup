#!/usr/bin/env bash
# Tell the packaged `pi-subagents` skill where a per-child `output:` is accepted.
#
# The skill documents `output: "plans/x.md"` and the `workflow: "parallel"` call, but never says that
# the two do not mix. On 2026-11-22 a fan-out written as
# `subagent({ workflow: "parallel", args: { tasks: [{ agent, task, output }] } })` failed with
# `unsupported fields: output`; the rewrite around `runs.all` is what accepted `output` on each item
# (#15874 п.7). `resolveParallel` in the package allows only `agent`, `task`, `cwd` and `model` per
# task, so the failure is by design and the skill has to say so.
#
# Pi reinstalls npm packages on `pi install` / `pi update --extensions`, so the edit lives here and
# `install.sh` re-applies it. The inserted bullet is project-neutral.
#
# Usage:
#   ./patches/pi-subagents-skill-output.sh            # apply
#   ./patches/pi-subagents-skill-output.sh --check    # exit 1 if the rule is missing
#   ./patches/pi-subagents-skill-output.sh --dry-run  # show what would change

set -euo pipefail

DRY_RUN=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PI_HOME="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
SKILL="$PI_HOME/npm/node_modules/pi-subagents/skills/pi-subagents/SKILL.md"

# Строка, по которой видно, что пункт уже вставлен: ищем маркер, а не весь текст, чтобы правка
# формулировки не плодила второй пункт.
MARKER='A `workflow: "parallel"` task takes no `output:`'

# Последняя строка пункта про `output:`: новый пункт идёт сразу за ней, чтобы оба читались вместе.
ANCHOR='task ends, delete scratch briefs, scripts and reports you wrote anywhere
  else; keep final deliverables.'

BLOCK='- A `workflow: "parallel"` task takes no `output:` — it accepts `agent`,
  `task`, `cwd` and `model`, and anything else fails the whole call before a
  child starts (`unsupported fields: output`). When each parallel child needs
  its own report file, fan out with `await runs.all([{ key, agent, task,
  output }, ...])` instead.'

if [[ ! -f "$SKILL" ]]; then
  echo "pi-subagents-skill-output: pi-subagents is not installed under $PI_HOME/npm; nothing to patch."
  exit 0
fi

if grep -qF "$MARKER" "$SKILL"; then
  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "pi-subagents-skill-output: OK — rule present in $SKILL"
  else
    echo "pi-subagents-skill-output: already patched, nothing to do."
  fi
  exit 0
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
  echo "pi-subagents-skill-output: MISSING — $SKILL has no rule about per-child output." >&2
  exit 1
fi

if ! grep -qF "$ANCHOR" "$SKILL"; then
  echo "pi-subagents-skill-output: anchor bullet not found in $SKILL." >&2
  echo "The upstream skill changed; re-read it and move ANCHOR before re-applying." >&2
  exit 3
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "would insert into $SKILL:"
  printf '%s\n' "$BLOCK"
  exit 0
fi

MARKER="$MARKER" BLOCK="$BLOCK" ANCHOR="$ANCHOR" SKILL="$SKILL" python3 - <<'PY'
import io
import os

path = os.environ['SKILL']
anchor = os.environ['ANCHOR']
block = os.environ['BLOCK']

text = io.open(path, encoding='utf-8').read()
if os.environ['MARKER'] in text:
    raise SystemExit(0)
if anchor not in text:
    raise SystemExit(3)

text = text.replace(anchor, anchor + '\n' + block, 1)
io.open(path, 'w', encoding='utf-8').write(text)
PY

echo "pi-subagents-skill-output: patched $SKILL"

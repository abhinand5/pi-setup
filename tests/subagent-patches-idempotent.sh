#!/usr/bin/env bash
# Скрипты правки `pi-subagents` накатываются дважды и не дублируют правило (#15929).
#
# Скрипты живут в `patches/` и заново запускаются `install.sh` после каждого `pi update
# --extensions`, поэтому повторный прогон — не украшение, а условие: он обязан ничего не менять. У
# `pi-subagents-review-loop-artifacts.sh` это дороже, чем у соседей: у него три правила, и машина,
# где первые два абзаца уже стоят, должна получить третье, а не выйти по первому маркеру.
#
# Проверяется: (1) на чистом фикстуре обе правки вставляют правило и говорят `--check: OK`;
# (2) повторный прогон не меняет файл; (3) на промпте, где первые два абзаца уже стоят,
# `artifacts` дописывает только третье; (4) пропавший якорь — код 3, а не тихий ноль.
#
# Exit 0 — всё сошлось; 1 — проверка упала.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

ARTIFACTS="$ROOT/patches/pi-subagents-review-loop-artifacts.sh"
SKILL_PATCH="$ROOT/patches/pi-subagents-skill-output.sh"

# Временный Pi home: скрипты ищут пакет в `$PI_CODING_AGENT_DIR/npm`, больше им ничего не нужно.
home="$WORK/home"
prompt="$home/npm/node_modules/pi-subagents/prompts/review-loop.md"
skill="$home/npm/node_modules/pi-subagents/skills/pi-subagents/SKILL.md"
mkdir -p "$(dirname "$prompt")" "$(dirname "$skill")"

# Фикстуры повторяют только якоря правок: текста пакета здесь нет, и он не нужен.
cat >"$prompt" <<'EOF'
# Review loop

For each review round, launch fresh-context `reviewer` agents in parallel. Reviewers must inspect the repository directly. They must not rely on the main conversation history and must not edit files.

Tell reviewers to filter on evidence, not severity.

Merge verdict: BLOCK.
EOF

cat >"$skill" <<'EOF'
# Pi Subagents

- Bind files with `output: "plans/x.md"` and return `outputReference` or
  `artifactPaths`; a filename in task text does not route output. Relative
  paths land in run artifacts. Never send reports to the repo root. When the
  task ends, delete scratch briefs, scripts and reports you wrote anywhere
  else; keep final deliverables.
- `runs.lanes([{ key, stages: [...] }])` runs a predeclared plan.
EOF

count() { grep -cF "$1" "$2"; }

# (1) Чистый фикстур: обе правки красные на --check, зелёные после прогона.
PI_CODING_AGENT_DIR="$home" "$ARTIFACTS" --check >/dev/null 2>&1 \
  && fail "artifacts --check зелёный на чистом промпте"
PI_CODING_AGENT_DIR="$home" "$SKILL_PATCH" --check >/dev/null 2>&1 \
  && fail "skill-output --check зелёный на чистом скилле"

PI_CODING_AGENT_DIR="$home" "$ARTIFACTS" >/dev/null
PI_CODING_AGENT_DIR="$home" "$SKILL_PATCH" >/dev/null

PI_CODING_AGENT_DIR="$home" "$ARTIFACTS" --check >/dev/null \
  || fail "artifacts --check красный после прогона"
PI_CODING_AGENT_DIR="$home" "$SKILL_PATCH" --check >/dev/null \
  || fail "skill-output --check красный после прогона"

[[ "$(count 'Pass `output:` to every reviewer' "$prompt")" == "1" ]] \
  || fail "правило про output: не вставлено ровно один раз"
[[ "$(count 'The `output:` file is the report; the answer carries only its path' "$prompt")" == "1" ]] \
  || fail "правило про ответ не вставлено ровно один раз"
[[ "$(count 'A `workflow: "parallel"` task takes no `output:`' "$skill")" == "1" ]] \
  || fail "правило скилла не вставлено ровно один раз"

# (2) Повторный прогон файл не меняет.
cp "$prompt" "$WORK/prompt.once"
cp "$skill" "$WORK/skill.once"
PI_CODING_AGENT_DIR="$home" "$ARTIFACTS" >/dev/null
PI_CODING_AGENT_DIR="$home" "$SKILL_PATCH" >/dev/null
cmp -s "$prompt" "$WORK/prompt.once" || fail "второй прогон artifacts изменил промпт"
cmp -s "$skill" "$WORK/skill.once" || fail "второй прогон skill-output изменил скилл"

# (3) Промпт, где первые два абзаца уже стоят: правила про ответ нет.
cat >"$prompt" <<'EOF'
# Review loop

They must not rely on the main conversation history and must not edit files.

Pass `output:` to every reviewer — a path such as `reviewer-<angle>.md` — and treat that file as the report. Set the round deadline with enough margin that a reviewer finishing near the end still writes its file, and tell each reviewer to write the report as its last action before returning.

Reviewers must not pipe `git` output into `head`.

Merge verdict: BLOCK.
EOF

PI_CODING_AGENT_DIR="$home" "$ARTIFACTS" >/dev/null
[[ "$(count 'Pass `output:` to every reviewer' "$prompt")" == "1" ]] \
  || fail "старое правило про output: продублировано"
[[ "$(count 'The `output:` file is the report; the answer carries only its path' "$prompt")" == "1" ]] \
  || fail "третье правило не дописано на промпте, где первые два уже стоят"

# (4) Якорь пропал — код 3, а не «уже накатано».
printf '# Review loop\n\nNothing here.\n' >"$prompt"
if PI_CODING_AGENT_DIR="$home" "$ARTIFACTS" >/dev/null 2>&1; then
  fail "artifacts вернул 0, не найдя якорь"
fi
status=0
PI_CODING_AGENT_DIR="$home" "$ARTIFACTS" >/dev/null 2>&1 || status=$?
[[ "$status" == "3" ]] || fail "artifacts без якоря вернул $status, ожидался 3"

echo "OK: повторный прогон правок pi-subagents ничего не меняет, третье правило доезжает последним"

#!/usr/bin/env bash
# Хук `skill-tool-refs`: в скиллах не остаётся «Skill tool», а указатели `../<имя>/SKILL.md` ведут в
# существующий сосед. 21.11.2026 фраза стояла в 10 скиллах (20 вхождений): набор пришёл из корпуса
# под другой контур, а Pi грузит скилл чтением SKILL.md или `/skill:name` — команды «Skill tool» в нём
# нет, и ретро-сессия потратила вызов на попытку её выполнить.
#
# Проверяется: (1) на этом репозитории хук зелёный; (2) файл с фразой — красный и называет номер
# строки; (3) указатель в пустоту — красный; (4) читаемый указатель — зелёный.
#
# Exit 0 — всё сошлось; 1 — проверка упала.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

HOOK="$WORK/repo/scripts/prek/skill-tool-refs.sh"
mkdir -p "$(dirname "$HOOK")"
cp "$ROOT/scripts/prek/skill-tool-refs.sh" "$HOOK"

# (1) Репозиторий в том виде, в каком он лежит, хук проходит.
if ! bash "$ROOT/scripts/prek/skill-tool-refs.sh" >"$WORK/repo.log" 2>&1; then
  sed -n '1,20p' "$WORK/repo.log" >&2
  fail "хук красный на самом репозитории"
fi

# (2) Фраза про несуществующий инструмент.
mkdir -p "$WORK/repo/skills/phantom"
printf -- '---\nname: phantom\ndescription: fixture\n---\n1. Call the Skill tool with "grilling".\n' \
  > "$WORK/repo/skills/phantom/SKILL.md"
if bash "$HOOK" >"$WORK/phantom.log" 2>&1; then
  fail "фраза «Skill tool» не поймана"
fi
grep -q 'skills/phantom/SKILL.md:5' "$WORK/phantom.log" \
  || fail "хук не назвал файл и строку находки"

# (4) Сосед, на которого ссылаются, существует — зелёный.
mkdir -p "$WORK/repo/skills/good" "$WORK/repo/skills/neighbour"
printf -- '---\nname: neighbour\ndescription: fixture\n---\ntext\n' > "$WORK/repo/skills/neighbour/SKILL.md"
printf -- '---\nname: good\ndescription: fixture\n---\nRead `../neighbour/SKILL.md`.\n' \
  > "$WORK/repo/skills/good/SKILL.md"
rm -rf "$WORK/repo/skills/phantom"
if ! bash "$HOOK" >"$WORK/good.log" 2>&1; then
  sed -n '1,20p' "$WORK/good.log" >&2
  fail "указатель на существующего соседа назван битым"
fi

# (3) Указатель в пустоту.
printf -- '---\nname: good\ndescription: fixture\n---\nRead `../nosuch/SKILL.md`.\n' \
  > "$WORK/repo/skills/good/SKILL.md"
if bash "$HOOK" >"$WORK/nosuch.log" 2>&1; then
  fail "указатель на несуществующий сосед не пойман"
fi
grep -q 'nosuch/SKILL.md' "$WORK/nosuch.log" || fail "хук не назвал битый указатель"

echo "OK: skill-tool-refs ловит «Skill tool» и указатели в пустоту, репозиторий проходит хук"

#!/usr/bin/env bash
# Скилл не может звать инструмент, которого в Pi нет. Набор скиллов пришёл из корпуса под другой
# контур, и фраза «Call the Skill tool with "x"» стояла в 10 скиллах (20 вхождений) — загрузчик её не
# исполняет, а модель тратит вызов на попытку. Pi грузит скилл чтением `SKILL.md` или `/skill:name`
# (документация Pi, docs/skills.md), поэтому указатель — путь к файлу.
#
# Две проверки, потому что оба вида дрейфа дают один симптом «скилл позвали, толку нет»:
#   * «Skill tool» в тексте скилла — несуществующий инструмент;
#   * `../<имя>/SKILL.md`, которого нет рядом — указатель в пустоту (скилл переименовали или убрали).
#
# Аргументы — файлы из индекса (prek передаёт их сам); без аргументов проверяется весь `skills/`.
# Exit 0 — чисто; 1 — есть находки.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
status=0

files=("$@")
if ((${#files[@]} == 0)); then
  mapfile -t files < <(find "$ROOT/skills" -name 'SKILL.md' | sort)
fi

for file in "${files[@]}"; do
  [[ -f "$file" ]] || continue
  while IFS= read -r line; do
    echo "$file:$line: несуществующий инструмент «Skill tool» — читайте SKILL.md напрямую"
    status=1
  done < <(grep -n "Skill tool" "$file" | cut -d: -f1 || true)

  # Указатели вида `../grilling/SKILL.md` — только те, что уже есть в тексте.
  dir="$(dirname "$file")"
  while IFS= read -r ref; do
    target="$dir/$ref"
    if [[ ! -f "$target" ]]; then
      echo "$file: указатель на $ref, а такого скилла рядом нет"
      status=1
    fi
  done < <(grep -oE '\.\./[a-z0-9-]+/SKILL\.md' "$file" | sort -u || true)
done

exit "$status"

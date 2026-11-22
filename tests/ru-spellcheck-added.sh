#!/usr/bin/env bash
# ru-spellcheck --added BASE: проверять только добавленные строки, с файловой нумерацией.
#
# Зачем: правка шести строк в файле на 233 строки (`config/AGENTS.md`) упирается в гейт — он честно
# отказывает на длинном входе (exit 3), а полный прогон возвращает чужой долг файла. Обходом был клей
# `git diff -U0 | grep '^+' > /tmp/x && ru-spellcheck /tmp/x`: номера строк терялись, а сам клей
# приходилось собирать заново в каждой сессии (2026-11-21 — дважды).
#
# Проверяется: (1) полный прогон видит и старое, и новое; (2) --added называет только добавленную
# строку; (3) номер строки в отчёте — файловый, а не номер внутри вырезки; (4) на файле без правок
# --added зелёный; (5) без git — внятный отказ с кодом 2.
#
# Runs with a throwaway XDG_CONFIG_HOME, so the real allowlists are never touched.
# Exit 0 — all checks passed; 1 — a check failed; 77 — skipped (no hunspell ru_RU).
set -euo pipefail

TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/ru-spellcheck"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -x "$TOOL" ]] || fail "нет $TOOL"
command -v python3 >/dev/null || fail "нужен python3"

export XDG_CONFIG_HOME="$WORK/config"
mkdir -p "$XDG_CONFIG_HOME/ru-spellcheck"
: > "$XDG_CONFIG_HOME/ru-spellcheck/allow.txt"

repo="$WORK/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email "spellcheck-added@example.invalid"
git -C "$repo" config user.name "spellcheck added test"

doc="$repo/doc.md"
printf 'Старый абзац с ошибкой: лоkalной путь.\nСтрока без ошибок.\n' > "$doc"
git -C "$repo" add -A && git -C "$repo" commit -qm base
printf 'Старый абзац с ошибкой: лоkalной путь.\nСтрока без ошибок.\nНовая строка: восстанóвленное значение.\n' > "$doc"

# (1) Полный прогон видит обе находки — иначе тест не доказывает, что фильтр вообще что-то делает.
full="$(cd "$repo" && "$TOOL" doc.md 2>&1 || true)"
printf '%s\n' "$full" | grep -q 'лоkalной' || fail "полный прогон не увидел старую находку"
printf '%s\n' "$full" | grep -q 'восстанóвленное' || fail "полный прогон не увидел новую находку"

# (2)+(3) --added: только добавленная строка, номер строки файловый.
added="$(cd "$repo" && "$TOOL" --added HEAD doc.md 2>&1 || true)"
printf '%s\n' "$added" | grep -q 'лоkalной' && fail "--added вернул находку из неизменённой строки"
printf '%s\n' "$added" | grep -qE '^doc\.md:3:[0-9]+ ' \
  || fail "--added не назвал строку 3 файла (получено: $added)"

# (4) Файл без правок относительно базы — зелёный, а не «пустой вход».
git -C "$repo" stash -q
if ! (cd "$repo" && "$TOOL" --added HEAD doc.md >"$WORK/clean.log" 2>&1); then
  sed -n '1,10p' "$WORK/clean.log" >&2
  fail "--added на файле без правок не зелёный"
fi
git -C "$repo" stash pop -q

# (5) Вне git — отказ с кодом 2, а не мнимая чистота.
mkdir -p "$WORK/plain"
cp "$doc" "$WORK/plain/doc.md" 2>/dev/null || printf 'Строка: лоkalной.\n' > "$WORK/plain/doc.md"
set +e
(cd "$WORK/plain" && "$TOOL" --added HEAD doc.md >"$WORK/plain.log" 2>&1)
rc=$?
set -e
[[ "$rc" == "2" ]] || fail "вне git ожидался код 2, получен $rc"
grep -q 'не git-репозиторий' "$WORK/plain.log" || fail "вне git отказ не объяснён"

echo "OK: --added проверяет только добавленные строки и держит файловую нумерацию"

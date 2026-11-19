#!/usr/bin/env bash
# ru-spellcheck: deny-список — приоритет над allow, отказ `--add`, точное совпадение формы.
#
# Повод: агент сам добавлял в allow придуманные англицизмы (воркtree, харнесс, резолв), и проверка
# переставала их видеть. Deny-список — владение человека: слово из него находка всегда, даже если оно
# есть в allow, в словаре или в baseline; агент не может ни дописать слово в deny, ни узаконить его
# через `--add`.
#
# Работает на временном XDG_CONFIG_HOME, живой словарь не трогается.
# Exit 0 — всё сошлось; 1 — проверка упала; 77 — пропуск (нет hunspell ru_RU).
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
: > "$XDG_CONFIG_HOME/ru-spellcheck/deny.txt"

# Запрещённое слово лежит и в allow: приоритет у deny.
printf 'резолв\n' > "$XDG_CONFIG_HOME/ru-spellcheck/allow.txt"
printf 'резолв\n' > "$XDG_CONFIG_HOME/ru-spellcheck/deny.txt"
printf 'Резолв прошёл.\n' > "$WORK/note.md"

out="$("$TOOL" "$WORK/note.md" 2>&1)" && fail "deny-слово принято как верное: $out"
case "$out" in
    *DENY*) ;;
    *) fail "нет находки DENY для слова из deny-списка: $out" ;;
esac
case "$out" in
    *SPELLING*) fail "слово из deny попало в обычные орфографические находки: $out" ;;
    *) ;;
esac

# Точное совпадение, без стемов: «сет» в deny не должен запрещать «сети».
printf 'сет\n' > "$XDG_CONFIG_HOME/ru-spellcheck/deny.txt"
printf 'Сети подняты и работают.\n' > "$WORK/nets.md"
"$TOOL" "$WORK/nets.md" >/dev/null || fail "deny-слово «сет» запретило верное «сети»"

# `--add` не узаконивает запрещённое слово — ни в проект, ни в личный словарь.
printf 'харнесс\n' > "$XDG_CONFIG_HOME/ru-spellcheck/deny.txt"
repo="$WORK/repo"
mkdir -p "$repo"
git -C "$repo" init -q
if (cd "$repo" && "$TOOL" --add харнесс >/dev/null 2>&1); then
    fail "--add записал слово из deny-списка"
fi
[[ -f "$repo/.ru-spellcheck-allow" ]] && fail "--add создал проектный словарь, хотя должен был отказать"
grep -qx 'харнесс' "$XDG_CONFIG_HOME/ru-spellcheck/allow.txt" && fail "--add-personal дописал deny-слово"

# Проектный deny-файл читается наравне с машинным и так же приоритетен.
: > "$XDG_CONFIG_HOME/ru-spellcheck/deny.txt"
printf 'инлайн\n' > "$repo/.ru-spellcheck-deny"
printf 'Инлайн-код не ломать.\n' > "$repo/note.md"
out="$("$TOOL" "$repo/note.md" 2>&1)" && fail "проектный deny-файл не применился: $out"
case "$out" in
    *DENY*) ;;
    *) fail "нет находки DENY из .ru-spellcheck-deny: $out" ;;
esac

echo "OK: deny-список приоритетнее allow, работают оба файла, --add запрещённое слово не узаконивает"

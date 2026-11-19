#!/usr/bin/env bash
# ru-spellcheck: deny-список — приоритет над allow, отказ `--add`, точное совпадение формы.
#
# Повод: агент сам добавлял в allow придуманные англицизмы (`воркtree`, `харнесс`, `резолв`), и проверка
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

# Форма `слово*` покрывает словоформы: множественное число запрещённого слова — DENY, а не SPELLING
# с ложной подсказкой (#15836 п.3). Короткие записи без звёздочки остаются точными — это проверено выше.
: > "$repo/.ru-spellcheck-deny"
printf 'ассерт*\n' > "$XDG_CONFIG_HOME/ru-spellcheck/deny.txt"
printf 'В тесте три ассерта.\n' > "$WORK/plural.md"
out="$("$TOOL" "$WORK/plural.md" 2>&1)" && fail "словоформа запрещённого слова принята как верная: $out"
case "$out" in
    *DENY*) ;;
    *) fail "словоформа из deny-списка не дала DENY: $out" ;;
esac
case "$out" in
    *SPELLING*) fail "словоформа уехала в SPELLING с подсказкой: $out" ;;
    *) ;;
esac

# Верное слово того же корня проходит: звёздочка матчит по началу слова, а не по любому совпадению.
printf 'ассертивность в переговорах уместна.\n' > "$WORK/stem-ok.md"
if ! "$TOOL" "$WORK/stem-ok.md" > /dev/null 2>&1; then
    # слово редкое — в словаре его может не быть; тогда правило стема всё равно не должно его банить
    out="$("$TOOL" "$WORK/stem-ok.md" 2>&1)" || :
    case "$out" in
        *DENY*) fail "стем-запись запретила верное слово «ассертивность»: $out" ;;
        *) ;;
    esac
fi

# Textile-код — цитата, а не проза: то же слово в `@…@` находкой не считается, без кода — считается.
printf 'резолв\n' > "$XDG_CONFIG_HOME/ru-spellcheck/deny.txt"
printf 'Наш скрипт @резолв@ и @апрув@ прошёл проверку.\n' > "$WORK/textile.md"
if ! "$TOOL" "$WORK/textile.md" > /dev/null 2>&1; then
    out="$("$TOOL" "$WORK/textile.md" 2>&1)"
    fail "Textile-цитата проверена как проза: $out"
fi
printf 'Резолв прошёл без кода.\n' > "$WORK/no-textile.md"
out="$("$TOOL" "$WORK/no-textile.md" 2>&1)" && fail "слово вне Textile-кода не проверено: $out"

# Адрес почты не маскируется как Textile-код: `@` в нём одна.
printf 'Пишите на %%s@example.com.\n' 'denis' > "$WORK/mail.md"
if ! "$TOOL" "$WORK/mail.md" > /dev/null 2>&1; then
    out="$("$TOOL" "$WORK/mail.md" 2>&1)"
    case "$out" in
        *"example.com"*) fail "адрес почты попал в проверку как слово: $out" ;;
        *) ;;
    esac
fi

echo "OK: deny-список приоритетнее allow, работают оба файла, --add запрещённое слово не узаконивает, словоформа и Textile-код учтены"

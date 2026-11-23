#!/usr/bin/env bash
# ru-spellcheck: словоформа верного слова со словарной основой (#15877 п.4).
#
# enchant знает «маржа», но не творительный «маржой»: в словаре флаг без падежных форм, и верное
# слово уходило в SPELLING с подсказкой «баржой». Тот же отчёт стоил раунда публикации: слово
# переписывали под инструмент. `--add` на пробел словаря правилами запрещён (#15860 п.8), поэтому
# лечение — в самом инструменте: словоформа принимается, если её основа есть в словаре.
#
# Главная граница здесь — не «ловим», а «не теряем»: та же уступка не должна пропускать класс
# редукции гласных, ради которого проверка существует. Окончания -ы/-и в список намеренно не входят.
#
# Runs outside any repository, with a throwaway XDG_CONFIG_HOME.
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

# No dictionary — the tool says so itself with code 2; that is a skip, not a failure.
printf 'Расчёт маржой закрыт.\n' > "$WORK/probe.md"
# Код берётся через `||`, а не `$?` после `if !`: под `set -e` упавший вызов внутри `then` обрывает
# скрипт до проверки статуса, и SKIP (77) остаётся мёртвой веткой.
status=0
"$TOOL" "$WORK/probe.md" >/dev/null 2>&1 || status=$?
if [[ $status -eq 2 ]]; then
    echo "SKIP: нет словаря hunspell ru_RU"
    exit 77
fi

# 1. Творительный падеж со словарной основой — не находка.
printf 'Расчёт маржой закрыт, перепроверю после прогона.\n' > "$WORK/ok.md"
if ! out="$("$TOOL" "$WORK/ok.md" 2>&1)"; then
    fail "верная словоформа уехала в находки: $out"
fi

# 2. Класс редукции гласных остаётся красным, каждое слово названо в отчёте.
corrupted='нузен открито которий деньгы напровление велечину скрыпт сесии стот документо сервисо системо таблицо'
printf '%s\n' "$corrupted" > "$WORK/bad.md"
if out="$("$TOOL" "$WORK/bad.md" 2>&1)"; then
    fail "редукция гласных и «слово + гласная» прошли молча: $out"
fi
for word in $corrupted; do
    grep -q "SPELLING  $word" <<<"$out" || fail "«$word» не названо находкой: $out"
done

# 3. Обычная опечатка с верной основой и чужим окончанием тоже остаётся находкой: уступка про
#    словарную основу, а не про любую замену окончания.
printf 'Договор директорово подписан.\n' > "$WORK/typo.md"
if out="$("$TOOL" "$WORK/typo.md" 2>&1)"; then
    fail "опечатка в окончании прошла молча: $out"
fi

echo "OK: словоформа со словарной основой принята, редукция гласных и опечатки остались находками."

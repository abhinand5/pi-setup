#!/usr/bin/env bash
# ru-spellcheck: probe — the checker still sees known-bad words, and its silence on a correct-but-wrong
# word is measured rather than assumed (#15864 п.4).
#
# Why: in session #15809 a solution fragment said «натальной проверки» instead of «нативной». The checker
# exited 0, and the typo was caught by a reviewer, not by the gate AGENTS.md tells agents to rely on before
# publishing Russian prose. The word is not a corruption — hunspell knows «натальный» (relating to birth) —
# so the dictionary can never catch it; what the test can do is prove the *other* class still works and
# pin the silence so nobody assumes the gate covers this case.
#
# Cases:
#   1. five known-bad words (vowel reduction) are findings — the gate that was trusted actually works;
#   2. «натальной» alone passes the dictionary — the measured silence, with the reason in the message;
#   3. a project `.ru-spellcheck-deny` entry makes it a DENY finding — the mechanism a project uses when
#      it wants a correct-but-wrong word caught anyway (msb-lk does exactly that);
#   4. the same entry does not ban the legitimate «натальный» — deny entries are exact word forms.
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
: > "$XDG_CONFIG_HOME/ru-spellcheck/deny.txt"

# --- 1. The dictionary class still works ------------------------------------------------------------
# Each word on its own file: a single failure has to name which word the checker stopped seeing.
bad_words=(сесии велечину скрыпт которий нузен)
for word in "${bad_words[@]}"; do
    file="$WORK/$word.md"
    printf 'Пункт: %s в тексте.\n' "$word" > "$file"
    if out="$("$TOOL" "$file" 2>&1)"; then
        fail "проверка перестала видеть плохое слово «$word»: $out"
    fi
    case "$out" in
        *"SPELLING  $word"*) ;;
        *) fail "слово «$word» не названо в находках SPELLING: $out" ;;
    esac
done

# --- 2. A correct-but-wrong word: the measured silence -----------------------------------------------
# «натальной» — верное слово (натальный = относящийся к рождению), поэтому словарь молчит: это не
# искажение, а подмена одного верного слова другим. Если проверка вдруг начнёт его ловить, тест краснеет
# намеренно: тогда строку 3 можно убрать из проектов, а комментарий здесь — переписать.
typo="$WORK/typo.md"
printf 'Решение: натальной проверки не будет.\n' > "$typo"
if out="$("$TOOL" "$typo" 2>&1)"; then
    : # ожидаемое поведение: словарь это слово знает
else
    case "$out" in
        *натальной*) fail "проверка стала ловить «натальной» — обновите этот тест и уберите deny-запись из проектов: $out" ;;
        *) fail "неожиданная находка на «натальной»: $out" ;;
    esac
fi

# --- 3. The project deny list makes it a finding ------------------------------------------------------
repo="$WORK/repo"
mkdir -p "$repo"
git -C "$repo" init -q   # проектные списки ищутся до git-корня, без .git их нет вовсе
printf '# слова, которые проверка обязана находить всегда\nнатальной\n' > "$repo/.ru-spellcheck-deny"

# Файл проверяется там, где лежит: deny-список проекта ищется вверх от проверяемого файла, поэтому
# кладём копию внутрь «репозитория» (#15717 п.4).
cp "$typo" "$repo/typo.md"
if "$TOOL" "$repo/typo.md" > "$WORK/deny.out" 2>&1; then
    fail "deny-запись не сработала: «натальной» принято как верное: $(cat "$WORK/deny.out")"
fi
case "$(cat "$WORK/deny.out")" in
    *DENY*натальной*) ;;
    *) fail "нет находки DENY для слова из проектного deny-списка: $(cat "$WORK/deny.out")" ;;
esac

# --- 4. The deny entry is exact: the legitimate word stays clean --------------------------------------
legit="$repo/legit.md"
printf 'Натальный период — термин из медицины.\n' > "$legit"
if ! out="$("$TOOL" "$legit" 2>&1)"; then
    fail "deny-запись «натальной» запретила верное «натальный»: $out"
fi

echo "OK: плохие слова ловятся, молчание на «натальной» измерено, deny-запись работает и не бьёт по верному слову"

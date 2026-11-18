#!/usr/bin/env bash
# ru-spellcheck: the --homoglyph-only gate refuses a long input instead of reporting it clean
# (#15799 п.2).
#
# The gate sees only script mixing. A hand-off document passed it with 55 vowel-reduction errors
# (сесии, велечину, скрыпт) and was green, because that class needs the dictionary. So a long input
# now exits 3 with a hint to run the full check; short prose (a chat message, a Redmine note) still
# passes with one command, and `--allow-long` is the deliberate bypass.
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

# 57 lines, one reduction error per line: the shape of the document that slipped through.
long="$WORK/hand-off.md"
: > "$long"
for i in $(seq 1 57); do
    printf 'Пункт %s: сесии в тексте, строка про велечину.\n' "$i" >> "$long"
done
lines="$(wc -l < "$long")"
[[ "$lines" -gt 40 ]] || fail "фикстура короче порога: $lines строк"

# Short prose keeps the one-command gate.
short="$WORK/note.md"
printf 'Заметка из трёх строк.\nОшибок нет.\nВот так.\n' > "$short"
"$TOOL" --homoglyph-only "$short" >/dev/null 2>&1 || fail "короткий текст обязан проходить гейт"

# Long input: refused, not reported clean — and the hint names the full run.
set +e
out="$("$TOOL" --homoglyph-only "$long" 2>&1)"
status=$?
set -e
[[ "$status" -eq 3 ]] || fail "длинный вход на гейте: код $status, ожидался 3"
grep -q 'полным прогоном' <<<"$out" || fail "подсказка про полный прогон не напечатана: $out"

# The same threshold applies to stdin, so a piped document is not a way around it.
set +e
printf '%s' "$(cat "$long")" | "$TOOL" --homoglyph-only - >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 3 ]] || fail "длинный stdin на гейте: код $status, ожидался 3"

# The deliberate bypass still checks the class the gate can see.
"$TOOL" --homoglyph-only --allow-long "$long" >/dev/null 2>&1 || fail "--allow-long обязан пропускать чистый текст"
printf '%s\n' "$(head -1 "$long") лоkalной" > "$WORK/homoglyph.md"
cat "$long" >> "$WORK/homoglyph.md"
set +e
"$TOOL" --homoglyph-only --allow-long "$WORK/homoglyph.md" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "гомоглиф на длинном входе с --allow-long: код $status, ожидался 1"

# The full run sees the reduction class; it needs the dictionary, hence the skip.
set +e
"$TOOL" "$long" >/dev/null 2>&1
status=$?
set -e
case "$status" in
    1) : ;;
    2) echo "SKIP: нет словаря hunspell ru_RU"; exit 77 ;;
    *) fail "полный прогон на длинном тексте: код $status, ожидался 1" ;;
esac

echo "OK: гейт отказывает длинному входу (код 3), короткий проходит, --allow-long обходит осознанно"

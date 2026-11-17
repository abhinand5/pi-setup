#!/usr/bin/env bash
# ru-spellcheck: the project allowlist (.ru-spellcheck-allow) and `--add` (#15717 п.4).
#
# Project jargon used to land in the personal allowlist ($XDG_CONFIG_HOME/ru-spellcheck/allow.txt):
# every agent re-learned the same words, the CI never saw them, and the personal file grew with
# vocabulary that only one repository uses. Here: the repository file is read on top of the
# personal one, it is found from nested files, and `--add` writes the committed file.
#
# Runs on a throwaway git repository with a throwaway XDG_CONFIG_HOME, so the real allowlist is
# never touched. Exit 0 — all checks passed; 1 — a check failed; 77 — skipped (no hunspell ru_RU).
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
mkdir -p "$repo/sub"
git -C "$repo" init -q

# A word no Russian dictionary has: the check must fail without the project allowlist.
word="крокозябра"
printf '%s\n' "$word" > "$repo/.ru-spellcheck-allow"
printf 'Крокозябра в тексте.\n' > "$repo/sub/note.md"

if ! "$TOOL" "$repo/sub/note.md" >/dev/null 2>&1; then
    status=$?
    [[ $status -eq 2 ]] && { echo "SKIP: нет словаря hunspell ru_RU"; exit 77; }
fi
"$TOOL" "$repo/sub/note.md" >/dev/null || fail "слово из .ru-spellcheck-allow не принято"

mv "$repo/.ru-spellcheck-allow" "$WORK/allow.bak"
if "$TOOL" "$repo/sub/note.md" >/dev/null 2>&1; then
    fail "без .ru-spellcheck-allow проверка обязана падать"
fi
mv "$WORK/allow.bak" "$repo/.ru-spellcheck-allow"

# The hard error class does not depend on dictionaries at all.
printf 'лоkalной\n' > "$repo/homoglyph.md"
"$TOOL" --homoglyph-only "$repo/homoglyph.md" >/dev/null 2>&1 && fail "гомоглиф обязан ловиться"
rm "$repo/homoglyph.md"

# `--add` inside a repository writes the committed file, not the personal one.
(cd "$repo" && "$TOOL" --add новослово >/dev/null) || fail "--add упал"
grep -qx 'новослово' "$repo/.ru-spellcheck-allow" || fail "--add не дописал .ru-spellcheck-allow"
grep -qx 'новослово' "$XDG_CONFIG_HOME/ru-spellcheck/allow.txt" && fail "--add не должен трогать личный словарь"

# `--add-personal` keeps the old behaviour for words that are not project vocabulary.
(cd "$repo" && "$TOOL" --add-personal личноеслово >/dev/null) || fail "--add-personal упал"
grep -qx 'личноеслово' "$XDG_CONFIG_HOME/ru-spellcheck/allow.txt" || fail "--add-personal не дописал личный словарь"
grep -qx 'личноеслово' "$repo/.ru-spellcheck-allow" && fail "--add-personal не должен трогать репозиторный словарь"

# Outside a repository there is no project file: `--add` falls back to the personal one.
outside="$WORK/outside"
mkdir -p "$outside"
(cd "$outside" && "$TOOL" --add внешнееслово >/dev/null) || fail "--add вне репозитория упал"
grep -qx 'внешнееслово' "$XDG_CONFIG_HOME/ru-spellcheck/allow.txt" || fail "--add вне репозитория не дописал личный словарь"

echo "OK: проект .ru-spellcheck-allow читается поверх личного, --add пишет в него"

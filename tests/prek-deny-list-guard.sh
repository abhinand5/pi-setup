#!/usr/bin/env bash
# prek-хук deny-list-guard: правка config/ru-spellcheck/deny.txt не проходит коммитом (#15820).
#
# Повод: `path-guard` сторожит только `write`/`edit`, поэтому deny-список можно было переписать
# через `bash` в той же сессии. Список уезжает на другие машины только коммитом, значит гейт стоит
# на коммите: хук читает индекс и отказывает, пока владелец машины не пройдёт обходом.
#
# Проверяется на одноразовом репозитории с настоящим `prek install`: сценарии — правка deny
# блокируется, `SKIP=deny-list-guard` проходит, обычная правка проходит, env-обход проходит,
# `--all-files` без правки не срабатывает.
#
# Exit 0 — всё сошлось; 1 — проверка упала; 77 — пропуск (нет prek).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v prek >/dev/null || { echo "SKIP: нет prek"; exit 77; }
[[ -f "$ROOT/prek.toml" ]] || fail "нет prek.toml"
[[ -x "$ROOT/scripts/prek/deny-list-guard.sh" ]] || fail "нет скрипта хука"

repo="$WORK/repo"
mkdir -p "$repo/config/ru-spellcheck" "$repo/scripts/prek"
cp "$ROOT/prek.toml" "$repo/prek.toml"
cp "$ROOT/scripts/prek/deny-list-guard.sh" "$repo/scripts/prek/"
cp "$ROOT/config/ru-spellcheck/deny.txt" "$repo/config/ru-spellcheck/deny.txt"
printf 'base\n' > "$repo/README.md"

git -C "$repo" init -q -b main
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m base
(cd "$repo" && prek install >/dev/null 2>&1) || fail "prek install не прошёл"

commit() { # $1 — сообщение; вывод prek не нужен, проверяется код возврата
    git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m "$1" >/dev/null 2>&1
}

# 1. Правка deny блокируется.
printf 'пробноеслово\n' >> "$repo/config/ru-spellcheck/deny.txt"
git -C "$repo" add config/ru-spellcheck/deny.txt
if commit "add deny word"; then
    fail "коммит с правкой deny-списка прошёл"
fi
# В отказе должно быть сказано, как действовать осознанно: гейт без обхода — тупик.
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -m "add deny word" > "$WORK/deny.log" 2>&1 || true
grep -q "SKIP=deny-list-guard" "$WORK/deny.log" || fail "в отказе нет пути обхода: $(cat "$WORK/deny.log")"

# 2. Штатный обход prek проходит: базовые хуки остаются, «No hooks found» не мешает.
SKIP=deny-list-guard git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m "deny (owner)" \
    >/dev/null 2>&1 || fail "SKIP=deny-list-guard не пропустил правку"
git -C "$repo" log --oneline -1 | grep -q "deny (owner)" || fail "коммит с SKIP не появился"

# 3. Обычная правка проходит без обходов.
printf 'x\n' >> "$repo/README.md"
git -C "$repo" add README.md
commit "readme" || fail "обычный коммит заблокирован хуком"

# 4. Осознанный обход переменной (для ручных вызовов и обёрток).
printf 'ещёслово\n' >> "$repo/config/ru-spellcheck/deny.txt"
git -C "$repo" add config/ru-spellcheck/deny.txt
PI_ALLOW_DENY_LIST_CHANGE=1 git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m "deny (env)" \
    >/dev/null 2>&1 || fail "PI_ALLOW_DENY_LIST_CHANGE=1 не пропустил правку"

# 5. `--all-files` без правки deny не должен срабатывать: путь в аргументах есть, индекса нет.
(cd "$repo" && prek run --all-files >/dev/null 2>&1) || fail "prek run --all-files сработал без правки deny"

echo "OK: правка deny блокируется коммитом, SKIP и env-обход проходят, обычные коммиты не задеты"

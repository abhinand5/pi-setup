#!/usr/bin/env bash
# Что `--restore` делает с файлами политики. 20.11.2026 AGENTS.md утверждал, что restore не
# перезаписывает ни `AGENTS.md`, ни `docs/delegation-models.md`, ни `docs/session-logs.md` — вывод был
# сделан по комментарию в install.sh, а не по трём местам вызова. На деле агентский AGENTS.md остаётся
# живой копии (install_config_if_absent), а две доки перезаписываются всегда (copy_path). Ошибка уехала
# в config/AGENTS.md и в живую ~/.pi/agent/AGENTS.md: её читает каждая сессия.
#
# Проверяется: (1) без --copy-config живой AGENTS.md не тронут, а docs/* перезаписаны; (2) пропуск
# назван в конце прогона блоком «Не восстановлено из репозитория», а не только строкой в середине
# журнала; (3) с --copy-config AGENTS.md забирает версию репозитория.
#
# Работает на временном HOME: живая копия этой машины не трогается.
# Exit 0 — всё сошлось; 1 — проверка упала.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Клон, а не cp -a: в клоне install.sh берёт содержимое из себя, а не из дерева под ревью, поэтому
# install.sh и sync.sh копируются поверх (tests/README.md).
clone="$WORK/clone"
git clone -q --no-hardlinks "$ROOT" "$clone"
cp "$ROOT"/install.sh "$ROOT"/sync.sh "$clone"/
git -C "$clone" config user.email "restore-policy@example.invalid"
git -C "$clone" config user.name "restore policy test"
mkdir -p "$clone/scripts/lib"
cp "$ROOT"/scripts/lib/two-copy-guard.sh "$clone/scripts/lib/"

home="$WORK/home"
pi_home="$home/.pi/agent"
bin="$home/.local/bin"
mkdir -p "$pi_home/docs" "$home/.config/ru-spellcheck" "$bin"
cp "$clone/config/settings.example.json" "$pi_home/settings.json"
cp "$clone/config/ru-spellcheck/allow.txt" "$home/.config/ru-spellcheck/allow.txt"
cp "$clone/config/ru-spellcheck/deny.txt" "$home/.config/ru-spellcheck/deny.txt"

# Живая копия несёт собственную правку в каждом из трёх файлов политики.
printf 'live-only AGENTS line\n' >> "$pi_home/docs/delegation-models.md"
printf 'live-only session-logs line\n' >> "$pi_home/docs/session-logs.md"
printf 'live-only agent policy line\n' >> "$pi_home/AGENTS.md"
cp "$pi_home/AGENTS.md" "$WORK/agents-before.md"

run_restore() { # run_restore <лог> [доп. флаг]
  local log="$1" extra="${2:-}"
  # shellcheck disable=SC2086
  env HOME="$home" PI_HOME="$pi_home" BIN_DIR="$bin" XDG_CONFIG_HOME="$home/.config" \
    bash "$clone/install.sh" --restore --no-backup --force $extra >"$log" 2>&1 || {
    sed -n '1,40p' "$log" >&2
    fail "restore завершился ошибкой (см. выше)"
  }
}

# (1) Без --copy-config: AGENTS.md не тронут, доки перезаписаны.
log1="$WORK/restore.log"
run_restore "$log1"
cmp -s "$WORK/agents-before.md" "$pi_home/AGENTS.md" \
  || fail "restore без --copy-config переписал живой AGENTS.md"
cmp -s "$clone/config/delegation-models.md" "$pi_home/docs/delegation-models.md" \
  || fail "docs/delegation-models.md не перезаписан, хотя restore перезаписывает его всегда"
cmp -s "$clone/config/session-logs.md" "$pi_home/docs/session-logs.md" \
  || fail "docs/session-logs.md не перезаписан, хотя restore перезаписывает его всегда"

# (2) Пропуск назван в конце прогона: последние строки — сводка, а не только «Done.».
tail -n 12 "$log1" | grep -q "Не восстановлено из репозитория" \
  || fail "в конце прогона нет блока «Не восстановлено из репозитория»"
tail -n 12 "$log1" | grep -q "AGENTS.md" \
  || fail "в сводке не назван пропущенный AGENTS.md"

# (3) С --copy-config живой AGENTS.md забирает версию репозитория.
log2="$WORK/restore-copy-config.log"
run_restore "$log2" "--copy-config"
cmp -s "$clone/config/AGENTS.md" "$pi_home/AGENTS.md" \
  || fail "restore --copy-config не забрал config/AGENTS.md"

echo "OK: restore оставляет живой AGENTS.md, перезаписывает docs/* и называет пропуск в сводке"

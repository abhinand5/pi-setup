#!/usr/bin/env bash
# two-copy guard: файл живёт в двух копиях (~/.pi/agent и репозиторий pi-setup), и обе стороны
# правят его. Раньше sync.sh и install.sh --restore перезаписывали цель целиком, поэтому побеждал
# последний запуск: 19.11.2026 так расщепился абзац в skills/redmine-cli/SKILL.md — 33 872 B против
# 34 084 B, потеря прошла молча (#15838 п.7).
#
# Проверяется: (1) restore отказывает, когда у живой копии есть свои правки, и называет файл;
# (2) --force перезаписывает; (3) restore идёт, когда живая копия просто устарела (равна HEAD);
# (4) sync --dry-run печатает реальное расхождение с числом строк, а не множество путей;
# (5) sync отказывает, когда копия репозитория грязная; (6) PI_SETUP_TWO_COPY_GUARD=0 снимает гейт.
#
# Работает на временном HOME: живая копия этой машины не трогается.
# Exit 0 — всё сошлось; 1 — проверка упала.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Клон, а не cp -a: у воркдерева .git — файл с абсолютным путём, и коммит из копии уехал бы в ветку
# воркдерева (tests/README.md, «Testing a script that writes to $HOME»).
clone="$WORK/clone"
git clone -q --no-hardlinks "$ROOT" "$clone"
cp "$ROOT"/install.sh "$ROOT"/sync.sh "$clone"/
# Идентичность — в самом клоне: тест подменяет HOME, и глобальный ~/.gitconfig (свой или CI-шный)
# ему не виден, а sync.sh в шаге (6) коммитит.
git -C "$clone" config user.email "two-copy-guard@example.invalid"
git -C "$clone" config user.name "two-copy guard test"
mkdir -p "$clone/scripts/lib"
cp "$ROOT"/scripts/lib/two-copy-guard.sh "$clone/scripts/lib/"

home="$WORK/home"
pi_home="$home/.pi/agent"
mkdir -p "$pi_home/skills/redmine-cli" "$home/.config/ru-spellcheck" "$home/.local/bin"
# Живая копия = ровно то, что лежит в HEAD: тогда restore — это восстановление, а не потеря.
cp "$clone/skills/redmine-cli/SKILL.md" "$pi_home/skills/redmine-cli/SKILL.md"
# settings.json нужен sync.sh на входе (валидация живого конфига), а не только restore.
cp "$clone/config/settings.example.json" "$pi_home/settings.json"
printf 'живая\n' > "$home/.config/ru-spellcheck/allow.txt"
cp "$clone/config/ru-spellcheck/allow.txt" "$home/.config/ru-spellcheck/allow.txt"

run_install() {
  env HOME="$home" PI_HOME="$pi_home" BIN_DIR="$home/.local/bin" \
    XDG_CONFIG_HOME="$home/.config" bash "$clone/install.sh" --restore --no-backup "$@"
}

# (1) Своя правка в живой копии — restore обязан отказать и назвать файл.
printf 'правка только в живой копии\n' > "$pi_home/skills/redmine-cli/SKILL.md"
err="$WORK/install.err"
if run_install 2>"$err" >/dev/null; then
  fail "restore перезаписал живую копию с собственными правками"
fi
grep -q "two-copy guard" "$err" || fail "отказ не назвал сторож: $(cat "$err")"
grep -q "skills/redmine-cli/SKILL.md" "$err" || fail "отказ не назвал расходящийся файл: $(cat "$err")"

# (2) --force — осознанная перезапись.
run_install --force >/dev/null 2>&1 || fail "--force не снял отказ"
cmp -s "$clone/skills/redmine-cli/SKILL.md" "$pi_home/skills/redmine-cli/SKILL.md" \
  || fail "--force не перезаписал живую копию"

# (3) Живая копия равна HEAD (устарела), копия репозитория уехала вперёд — restore пишет без вопросов:
# терять в живой копии нечего, там ровно закоммиченное состояние.
git -C "$clone" checkout -q -- skills config
git -C "$clone" show HEAD:skills/redmine-cli/SKILL.md > "$pi_home/skills/redmine-cli/SKILL.md"
printf 'правка в копии репозитория\n' >> "$clone/skills/redmine-cli/SKILL.md"
run_install >/dev/null 2>&1 || fail "restore отказал, когда живая копия равна HEAD"
cmp -s "$clone/skills/redmine-cli/SKILL.md" "$pi_home/skills/redmine-cli/SKILL.md" \
  || fail "restore не обновил устаревшую живую копию"
git -C "$clone" checkout -q -- skills

# (4) sync --dry-run: реальное расхождение, а не множество путей.
printf 'живая правка\n' >> "$pi_home/skills/redmine-cli/SKILL.md"
out="$(env HOME="$home" PI_HOME="$pi_home" XDG_CONFIG_HOME="$home/.config" bash "$clone/sync.sh" --dry-run)"
case "$out" in
  *"skills/redmine-cli/SKILL.md  (+"*" строк"*) ;;
  *) fail "dry-run не показал файл и число разошедшихся строк: $out" ;;
esac
case "$out" in
  *"config/settings.example.json, config/mcp.example.json"*) fail "dry-run печатает множество путей: $out" ;;
  *) ;;
esac

# (5) Копия репозитория грязная — sync отказывает, пока не --force.
printf 'правка в копии репозитория\n' >> "$clone/skills/redmine-cli/SKILL.md"
err="$WORK/sync.err"
if env HOME="$home" PI_HOME="$pi_home" XDG_CONFIG_HOME="$home/.config" \
  bash "$clone/sync.sh" --no-push 2>"$err" >/dev/null; then
  fail "sync перезаписал копию репозитория с собственными правками"
fi
grep -q "two-copy guard" "$err" || fail "sync-отказ не назвал сторож: $(cat "$err")"

# (6) Гейт снимается осознанно.
env HOME="$home" PI_HOME="$pi_home" XDG_CONFIG_HOME="$home/.config" \
  PI_SETUP_TWO_COPY_GUARD=0 bash "$clone/sync.sh" --no-push --all-skills >"$WORK/sync6.out" 2>&1 \
  || fail "PI_SETUP_TWO_COPY_GUARD=0 не снял гейт: $(cat "$WORK/sync6.out")"

echo "OK: сторож двух копий отказывает на обе стороны, --force и PI_SETUP_TWO_COPY_GUARD=0 работают, dry-run считает строки"

#!/usr/bin/env bash
# Симлинки ~/.local/bin из связанного воркдерева: install_bin_helpers ставил симлинк на файл по пути $ROOT,
# а $ROOT связанного воркдерева исчезает после мержа — симлинк остаётся битым. 20.11.2026 restore,
# запущенный из ~/p/pi-setup-wt/redmine-subtree-prompts, планировал `ln -s
# /home/denis/p/pi-setup-wt/redmine-subtree-prompts/bin/rg ~/.local/bin/rg`; поймано до запуска на
# `--dry-run`.
#
# Проверяется: (1) restore из связанного воркдерева ставит симлинки в основное дерево, а не в
# воркдерево; (2) симлинки живые (файл, на который они указывают, существует); (3) restore из
# основного дерева ставит симлинки как прежде — на себя; (4) хелпер, которого в основном дереве нет,
# симлинком не обзаводится, и об этом сказано.
#
# Работает на временном HOME: живая копия этой машины не трогается.
# Exit 0 — всё сошлось; 1 — проверка упала.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Клон, а не cp -a: у воркдерева .git — файл с абсолютным путём (tests/README.md).
clone="$WORK/clone"
git clone -q --no-hardlinks "$ROOT" "$clone"
cp "$ROOT"/install.sh "$ROOT"/sync.sh "$clone"/
git -C "$clone" config user.email "restore-worktree@example.invalid"
git -C "$clone" config user.name "restore worktree test"
mkdir -p "$clone/scripts/lib"
cp "$ROOT"/scripts/lib/two-copy-guard.sh "$clone/scripts/lib/"

# Связанное воркдерево того же репозитория — ровно тот случай, ради которого правка.
wt="$WORK/wt"
git -C "$clone" worktree add -q "$wt" -b test/worktree-symlinks
cp "$ROOT"/install.sh "$wt"/

home="$WORK/home"
pi_home="$home/.pi/agent"
bin="$home/.local/bin"
mkdir -p "$pi_home/skills/redmine-cli" "$home/.config/ru-spellcheck" "$bin"
cp "$clone/skills/redmine-cli/SKILL.md" "$pi_home/skills/redmine-cli/SKILL.md"
cp "$clone/config/settings.example.json" "$pi_home/settings.json"
cp "$clone/config/ru-spellcheck/allow.txt" "$home/.config/ru-spellcheck/allow.txt"
cp "$clone/config/ru-spellcheck/deny.txt" "$home/.config/ru-spellcheck/deny.txt"

# (1)+(2) Restore из воркдерева: симлинки в основное дерево и живые.
out="$WORK/from-wt.log"
env HOME="$home" PI_HOME="$pi_home" BIN_DIR="$bin" XDG_CONFIG_HOME="$home/.config" \
  bash "$wt/install.sh" --restore --no-backup >"$out" 2>&1 || {
  sed -n '1,40p' "$out" >&2
  fail "restore из воркдерева завершился ошибкой"
}

check_link() { # check_link <имя> <ожидаемый префикс>
  local name="$1" want="$2" target
  target="$(readlink "$bin/$name" || true)"
  [[ -n "$target" ]] || fail "симлинка $name нет"
  [[ "$target" == "$want"* ]] || fail "$name -> $target, ожидался путь под $want"
  [[ -e "$target" ]] || fail "$name -> $target — битый симлинк"
}

for helper in "$clone"/bin/*; do
  name="$(basename "$helper")"
  [[ "$name" == "pi" ]] && continue
  # (4) Хелпера нет в основном дереве — симлинк ставить не на что, и об этом должно быть сказано.
  check_link "$name" "$clone/bin/"
done

grep -q "связанное воркдерево" "$out" || fail "restore из воркдерева не сказал, куда ставит симлинки"
if grep -q "$wt/bin/" "$out"; then
  fail "в плане restore остались пути внутрь воркдерева ($wt/bin/…)"
fi

# (3) Restore из основного дерева ставит симлинки на себя, как прежде.
bin2="$WORK/bin-main"
mkdir -p "$bin2"
out2="$WORK/from-main.log"
env HOME="$home" PI_HOME="$pi_home" BIN_DIR="$bin2" XDG_CONFIG_HOME="$home/.config" \
  bash "$clone/install.sh" --restore --no-backup --force >"$out2" 2>&1 || {
  sed -n '1,40p' "$out2" >&2
  fail "restore из основного дерева завершился ошибкой"
}
target="$(readlink "$bin2/rg" || true)"
[[ "$target" == "$clone/bin/rg" ]] || fail "основное дерево: rg -> $target, ожидался $clone/bin/rg"

# (4) Хелпер только в воркдереве — предупреждение, линка нет.
printf '#!/usr/bin/env bash\necho tmp\n' > "$wt/bin/pi-worktree-only-check"
chmod +x "$wt/bin/pi-worktree-only-check"
out3="$WORK/from-wt-new-helper.log"
env HOME="$home" PI_HOME="$pi_home" BIN_DIR="$bin" XDG_CONFIG_HOME="$home/.config" \
  bash "$wt/install.sh" --restore --no-backup --force >"$out3" 2>&1 || {
  sed -n '1,40p' "$out3" >&2
  fail "restore из воркдерева с новым хелпером завершился ошибкой"
}
[[ -e "$bin/pi-worktree-only-check" ]] && fail "у хелпера, которого нет в основном дереве, всё равно появился симлинк"
grep -q "pi-worktree-only-check" "$out3" || fail "про непокрытый хелпер не сказано"

echo "OK: симлинки ~/.local/bin из воркдерева указывают в основное дерево"

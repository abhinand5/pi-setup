#!/usr/bin/env bash
# Заметки `--restore` о смерженных воркдеревьях. `git worktree list` показывает каталог и ветку, но не
# говорит, есть ли в дереве неслитое: 21.11.2026 два таких дерева стоили четырёх вызовов (status,
# merge-base, cherry, ls-remote), чтобы доказать, что там нечего терять. Обычный мерж и squash
# выглядят по-разному: у squash нет коммита-предка, и `merge-base --is-ancestor` называет ветку
# неотмерженной, поэтому классификация идёт через оба.
#
# Проверяется: (1) дерево с fast-forward мержем названо; (2) дерево с squash-мержем названо, хотя
# предка в базе нет; (3) дерево с незакоммиченными правками названо с оговоркой, а не как «можно
# убрать»; (4) неслитая ветка не названа вовсе.
#
# Работает на временном HOME и в клоне: живая копия и этот репозиторий не трогаются.
# Exit 0 — всё сошлось; 1 — проверка упала.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

clone="$WORK/clone"
git clone -q --no-hardlinks "$ROOT" "$clone"
git -C "$clone" config user.email "worktree-notes@example.invalid"
git -C "$clone" config user.name "worktree notes test"

# База сравнения — сам клон: origin/main указывает сюда, поэтому «смержено» проверяется локально.
git -C "$clone" update-ref refs/remotes/origin/main "$(git -C "$clone" rev-parse HEAD)"

# (1) fast-forward
git -C "$clone" worktree add -q "$WORK/wt-ff" -b feat/ff
printf 'a\n' > "$WORK/wt-ff/a.txt"
git -C "$WORK/wt-ff" add -A && git -C "$WORK/wt-ff" commit -qm ff
git -C "$clone" merge -q --ff-only feat/ff

# (2) squash: патч в базе, коммита-предка нет
git -C "$clone" worktree add -q "$WORK/wt-sq" -b feat/sq
printf 'b\n' > "$WORK/wt-sq/b.txt"
git -C "$WORK/wt-sq" add -A && git -C "$WORK/wt-sq" commit -qm sq
git -C "$clone" merge -q --squash feat/sq >/dev/null
git -C "$clone" commit -qm "squash of sq"

# (3) смержено, но с незакоммиченными правками
git -C "$clone" worktree add -q "$WORK/wt-dirty" -b feat/dirty
printf 'dirty\n' > "$WORK/wt-dirty/c.txt"

# (4) неслитая ветка — молчать
git -C "$clone" worktree add -q "$WORK/wt-new" -b feat/new
printf 'd\n' > "$WORK/wt-new/d.txt"
git -C "$WORK/wt-new" add -A && git -C "$WORK/wt-new" commit -qm new

git -C "$clone" update-ref refs/remotes/origin/main "$(git -C "$clone" rev-parse HEAD)"

home="$WORK/home"
mkdir -p "$home/.pi/agent" "$home/.local/bin"
out="$WORK/restore.log"
env HOME="$home" PI_HOME="$home/.pi/agent" BIN_DIR="$home/.local/bin" XDG_CONFIG_HOME="$home/.config" \
  bash "$clone/install.sh" --restore --no-backup --force >"$out" 2>&1 || {
  sed -n '1,40p' "$out" >&2
  fail "restore завершился ошибкой"
}

grep -q "wt-ff.*можно убрать" "$out" \
  || fail "воркдерево с fast-forward мержем не названо"
grep -q "wt-sq.*squash-мерж.*можно убрать" "$out" \
  || fail "воркдерево с squash-мержем не названо (merge-base его не видит)"
grep -q "wt-dirty.*незакоммиченные правки" "$out" \
  || fail "воркдерево с незакоммиченными правками не названо с оговоркой"
if grep -q "wt-new" "$out"; then
  fail "неслитая ветка названа как смерженная"
fi

echo "OK: restore называет смерженные воркдеревья и отличает squash от неслитого"

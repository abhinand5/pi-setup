#!/usr/bin/env bash
# Exercise the home/ dotfile wiring in install.sh and uninstall.sh against throwaway
# $HOME directories. No Docker and no network: every case runs the real installer with
# HOME and BIN_DIR redirected, so what is asserted is the shipped script, not a mock.
#
#   ./tests/home-dotfiles.sh
#
# Why these cases exist: the tmux config is the first file this repo writes outside
# ~/.pi/agent, and three of its properties are load-bearing —
#   1. a plain install never overwrites a hand-edited ~/.tmux.conf,
#   2. --copy-config only overwrites after keeping the previous copy,
#   3. --revert restores it, or deletes what the install created.
# A regression in any of them silently loses a machine's tmux config.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

pass() {
  echo "ok: $*"
}

# install_into <home> [extra install args...]
install_into() {
  local home="$1"
  shift
  env HOME="$home" BIN_DIR="$home/.local/bin" "$ROOT/install.sh" "$@" >"$home/.install.log" 2>&1 \
    || { cat "$home/.install.log" >&2; fail "install failed ($*)"; return 1; }
}

new_home() {
  local home
  home="$(mktemp -d)"
  mkdir -p "$home/.pi/agent"
  printf '%s\n' "$home"
}

latest_backup() {
  find "$1/.pi/agent/backups" -maxdepth 1 -mindepth 1 -type d -name 'pi-setup-*' | LC_ALL=C sort | tail -1
}

# 1. plain install reports the difference and leaves the live file alone.
home="$(new_home)"
printf 'hand written\n' >"$home/.tmux.conf"
install_into "$home"
if cmp -s "$home/.tmux.conf" <(printf 'hand written\n'); then
  pass "plain install leaves a hand-edited ~/.tmux.conf alone"
else
  fail "plain install overwrote ~/.tmux.conf"
fi
if grep -q 'differs from the repo copy' "$home/.install.log"; then
  pass "plain install reports the difference"
else
  fail "plain install did not report the difference"
fi

# 2. --copy-config overwrites but keeps a .bak of the previous file.
install_into "$home" --copy-config
if cmp -s "$home/.tmux.conf" "$ROOT/home/.tmux.conf"; then
  pass "--copy-config installs the repo dotfile"
else
  fail "--copy-config did not install the repo dotfile"
fi
if compgen -G "$home/.tmux.conf.bak-*" >/dev/null; then
  pass "--copy-config keeps a .bak of the overwritten file"
else
  fail "--copy-config overwrote without a .bak"
fi

# 3. a second --copy-config run is idempotent and adds no second .bak.
baks_before="$(compgen -G "$home/.tmux.conf.bak-*" | wc -l)"
install_into "$home" --copy-config
baks_after="$(compgen -G "$home/.tmux.conf.bak-*" | wc -l)"
if [[ "$baks_before" == "$baks_after" ]]; then
  pass "repeated --copy-config does not accumulate backups"
else
  fail "repeated --copy-config added another backup"
fi

# 4. --backup --copy-config records the previous file, and --revert restores it.
home="$(new_home)"
printf 'hand written\n' >"$home/.tmux.conf"
install_into "$home" --copy-config --backup
backup="$(latest_backup "$home")"
[[ -f "$backup/home-manifest.txt" ]] || fail "backup has no home-manifest.txt"
[[ -f "$backup/home/.tmux.conf" ]] || fail "backup has no copy of the previous .tmux.conf"
env HOME="$home" BIN_DIR="$home/.local/bin" "$ROOT/install.sh" --revert "$backup" >"$home/.revert.log" 2>&1 \
  || { cat "$home/.revert.log" >&2; fail "revert failed"; }
if cmp -s "$home/.tmux.conf" <(printf 'hand written\n'); then
  pass "--revert restores the previous ~/.tmux.conf"
else
  fail "--revert did not restore the previous ~/.tmux.conf"
fi

# 5. --backup --copy-config on a clean HOME: revert removes what install created.
home="$(new_home)"
install_into "$home" --copy-config --backup
backup="$(latest_backup "$home")"
[[ -f "$home/.tmux.conf" ]] || fail "install created no ~/.tmux.conf to revert"
env HOME="$home" BIN_DIR="$home/.local/bin" "$ROOT/install.sh" --revert "$backup" >"$home/.revert.log" 2>&1 \
  || { cat "$home/.revert.log" >&2; fail "revert failed"; }
if [[ -f "$home/.tmux.conf" ]]; then
  fail "--revert left a ~/.tmux.conf that the backup recorded as absent"
else
  pass "--revert removes a ~/.tmux.conf the install created"
fi

# 6. --backup without --copy-config must not record a dotfile it never wrote: a later
#    --revert would otherwise delete a file the install did not touch.
home="$(new_home)"
printf 'hand written\n' >"$home/.tmux.conf"
install_into "$home" --backup
backup="$(latest_backup "$home")"
if [[ -f "$backup/home-manifest.txt" ]]; then
  fail "--backup without --copy-config recorded home/ dotfiles it does not write"
else
  pass "--backup without --copy-config records no dotfiles"
fi

# 7. uninstall keeps a hand-edited file and removes an unmodified one.
home="$(new_home)"
install_into "$home" --copy-config
printf '# local edit\n' >>"$home/.tmux.conf"
env HOME="$home" BIN_DIR="$home/.local/bin" "$ROOT/uninstall.sh" >"$home/.uninstall.log" 2>&1 || true
if [[ -f "$home/.tmux.conf" ]]; then
  pass "uninstall keeps a modified ~/.tmux.conf"
else
  fail "uninstall deleted a modified ~/.tmux.conf"
fi

home="$(new_home)"
install_into "$home" --copy-config
env HOME="$home" BIN_DIR="$home/.local/bin" "$ROOT/uninstall.sh" >"$home/.uninstall.log" 2>&1 || true
if [[ -f "$home/.tmux.conf" ]]; then
  fail "uninstall left an unmodified ~/.tmux.conf behind"
else
  pass "uninstall removes an unmodified ~/.tmux.conf"
fi

# 8. --copy-config --dry-run must not claim a backup it did not make.
home="$(new_home)"
printf 'hand written\n' >"$home/.tmux.conf"
install_into "$home" --copy-config --dry-run
if [[ ! -e "$home/.tmux.conf.bak-$(date +%Y%m%dT%H%M%S)" ]] && grep -q 'would back up the previous' "$home/.install.log"; then
  pass "dry run reports a future backup without writing one"
else
  fail "dry run wrote a backup or claimed a completed one"
fi
if cmp -s "$home/.tmux.conf" <(printf 'hand written\n'); then
  pass "dry run leaves the live dotfile untouched"
else
  fail "dry run rewrote the live dotfile"
fi

# 9. A ~/.tmux.conf symlinked into the repo is already the repo copy: install must not try
#    to `cp` it onto itself ("are the same file" aborts the run).
home="$(new_home)"
ln -s "$ROOT/home/.tmux.conf" "$home/.tmux.conf"
install_into "$home" --copy-config
if [[ -L "$home/.tmux.conf" ]]; then
  pass "--copy-config survives a ~/.tmux.conf symlinked into the repo"
else
  fail "--copy-config replaced a symlinked ~/.tmux.conf"
fi

# 10. sync.sh: an untracked dotfile sitting in home/ must not be captured or committed, and
#    a tracked one must be. This is the case that regression-proofs the shell-history-style
#    mistake: `git add home` stages the directory, not the tracked files, so a hand-dropped
#    ~/.netrc would ride into the commit and get pushed.
if command -v git >/dev/null 2>&1; then
  clone="$(mktemp -d)/clone"
  if git clone -q --no-hardlinks "$ROOT" "$clone" 2>/dev/null; then
    # sync.sh commits inside the clone, and a CI runner has no global git identity (empty GECOS):
    # the first run after `home/` dotfiles landed died with "empty ident name" - "sync.sh failed
    # in the clone". Set the identity locally in the throwaway clone; the machine's global config
    # is not part of this test.
    git -C "$clone" config user.email test@example.invalid
    git -C "$clone" config user.name test

    # The test runs against the working tree, which may carry uncommitted changes to the
    # very scripts under test; copy them over the clone so the assertion tests this code.
    cp "$ROOT/sync.sh" "$ROOT/install.sh" "$clone/"
    git -C "$clone" -c user.email=test@example.invalid -c user.name=test commit -qam "under test" || true

    home="$(new_home)"
    env HOME="$home" BIN_DIR="$home/.local/bin" "$clone/install.sh" --restore --copy-config >"$home/.seed.log" 2>&1 \
      || { cat "$home/.seed.log" >&2; fail "clone could not seed a Pi home"; }
    printf 'machine secret\n' >"$clone/home/.netrc"
    printf '# live edit\n' >>"$home/.tmux.conf"
    env HOME="$home" "$clone/sync.sh" --no-skills --no-push "capture test" >"$home/.sync.log" 2>&1 \
      || { tail -20 "$home/.sync.log" >&2; fail "sync.sh failed in the clone"; }

    if git -C "$clone" show --name-only --format= HEAD | grep -qx 'home/.netrc'; then
      fail "sync.sh committed an untracked home/ dotfile"
    else
      pass "sync.sh does not commit an untracked home/ dotfile"
    fi
    if [[ "$(tail -1 "$clone/home/.tmux.conf")" == "# live edit" ]]; then
      pass "sync.sh captures a tracked home/ dotfile back into the repo"
    else
      fail "sync.sh did not capture the tracked home/ dotfile"
    fi
  else
    echo "skipped: sync.sh case needs a clonable git checkout" >&2
  fi
else
  echo "skipped: sync.sh case needs git" >&2
fi

if [[ "$failures" -gt 0 ]]; then
  echo "$failures case(s) failed" >&2
  exit 1
fi
echo "all home/ dotfile cases passed"

#!/usr/bin/env bash
# Shared guard for files that live in two copies: `~/.pi/agent` (live) and this repo (pi-setup).
#
# `sync.sh` (live -> repo) and `install.sh --restore` (repo -> live) both overwrite the target
# wholesale, so the last run wins. On 2026-11-19 that split a paragraph of `skills/redmine-cli/SKILL.md`
# between the two copies: 33 872 B against 34 084 B, and nothing said a word (#15838 п.7).
#
# The guard asks one question per pair: does the side that is about to be overwritten carry changes of
# its own? That side never equals HEAD (or is untracked), while the two copies differ — so the write
# would destroy work that git cannot give back. Everything else is the normal direction of the tool:
# sync publishes live edits, install restores from the repo.
#
# Sourced by `sync.sh` and `install.sh`; both define `ROOT` before sourcing. Overrides:
#   FORCE=1                   overwrite anyway (`--force`), and say so in the output
#   PI_SETUP_TWO_COPY_GUARD=0 turn the guard off for one run (scripts and tests that write on purpose)
#
# Files that are meant to differ — `*.example.json`, the settings seed — are never passed in here.
# shellcheck shell=bash

DG_ITEMS=()    # "live|repo" pairs that differ between the two copies
DG_REFUSED=()  # the pairs whose target side also moved — writing them would lose work

dg_enabled() {
  [[ "${PI_SETUP_TWO_COPY_GUARD:-1}" == "0" ]] && return 1
  return 0
}

# dg_compare <live> <repo> [target]: remember a pair that differs. `target` is the copy the caller is
# about to overwrite — `repo` for sync.sh, `live` for install.sh — and is the one checked against HEAD.
# Silent when the files are equal or one side is absent: a file that exists on one side only is not a
# divergence, there is nothing to lose yet.
dg_compare() {
  local live="$1" repo="$2" target="${3:-repo}" rel
  dg_enabled || return 0
  [[ -f "$live" && -f "$repo" ]] || return 0
  cmp -s "$live" "$repo" && return 0
  DG_ITEMS+=("$live|$repo")

  rel="${repo#"$ROOT"/}"
  # `report` — пара только показывается в отчёте: писать её и так безопасно (install.sh кладёт
  # рядом .bak-копию, как и раньше), но расхождение должно быть видно (#15836 п.2).
  [[ "$target" == "report" ]] && return 0
  if [[ "$target" == "live" ]]; then
    # install: replacing the live copy is safe while its content is a version the repo had at some
    # point — that is what a stale live copy is after the repo moved on. Content the repo never held
    # is a local edit, and overwriting it would lose work.
    dg_known_in_history "$rel" "$live" && return 0
  else
    # sync: replacing the repo copy is safe only while it carries no uncommitted change.
    git -C "$ROOT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 \
      && git -C "$ROOT" diff --quiet HEAD -- "$rel" 2>/dev/null && return 0
  fi
  DG_REFUSED+=("$live|$repo")
}

# dg_matches_head <rel-in-repo> <file>: is this file byte-identical to its committed version?
dg_matches_head() {
  local tmp
  tmp="$(mktemp)"
  if git -C "$ROOT" show "HEAD:$1" >"$tmp" 2>/dev/null && cmp -s "$2" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# dg_known_in_history <rel-in-repo> <file>: did the repo ever hold this exact content at this path?
dg_known_in_history() {
  local want hits
  want="$(git -C "$ROOT" hash-object -- "$2" 2>/dev/null)" || return 1
  [[ -n "$want" ]] || return 1
  # `grep -q` стоит ПОСЛЕ конвейера, а не в нём: он выходит на первом совпадении, апстрим получает
  # SIGPIPE, и под `set -o pipefail` (оба скрипта) конвейер возвращает провал на верном ответе.
  hits="$(git -C "$ROOT" log -n 30 --format=%H -- "$1" 2>/dev/null \
    | sed "s|\$|:$1|" \
    | git -C "$ROOT" cat-file --batch-check='%(objectname)' 2>/dev/null)" || hits=""
  [[ -n "$hits" ]] && printf '%s\n' "$hits" | grep -qx "$want"
}

# dg_compare_tree <live_dir> <repo_dir> [target]: the same for every file present on both sides.
dg_compare_tree() {
  local live="$1" repo="$2" target="${3:-repo}" rel
  dg_enabled || return 0
  [[ -d "$live" && -d "$repo" ]] || return 0
  while IFS= read -r rel; do
    dg_compare "$live/$rel" "$repo/$rel" "$target"
  # `find | sed`, а не `find -printf`: -printf есть только в GNU find, а на BSD/macOS он падает
  # внутри подстановки процесса молча — сторож тогда не сравнил бы ни одного файла (#15838 п.7).
  done < <(cd "$repo" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
}

# dg_standard_pairs [target] [mode]: every file this repo keeps in two copies. `mode` is what the run
# is going to write — `restore` (skills/themes/extensions + docs), `copy-config` (AGENTS.md, dotfiles),
# `all`, or `sync` for the live -> repo direction. A pair the run would not touch is not compared:
# refusing `--restore` over a machine-local AGENTS.md it deliberately preserves is a false alarm.
dg_standard_pairs() {
  local target="${1:-repo}" mode="${2:-all}" live="${PI_HOME:-$HOME/.pi/agent}"
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  if [[ "$mode" == "restore" || "$mode" == "all" || "$mode" == "sync" ]]; then
    dg_compare "$live/docs/delegation-models.md" "$ROOT/config/delegation-models.md" "$target"
    dg_compare "$live/docs/session-logs.md" "$ROOT/config/session-logs.md" "$target"
    dg_compare_tree "$live/skills" "$ROOT/skills" "$target"
    dg_compare_tree "$live/themes" "$ROOT/themes" "$target"
    dg_compare_tree "$live/extensions" "$ROOT/extensions" "$target"
  fi
  if [[ "$mode" == "copy-config" || "$mode" == "all" || "$mode" == "sync" ]]; then
    dg_compare "$live/AGENTS.md" "$ROOT/config/AGENTS.md" "$target"
    # dotfiles restore keeps a .bak рядом, поэтому здесь сторож только показывает расхождение.
    dg_compare_tree "$HOME" "$ROOT/home" "$([[ "$target" == "live" ]] && echo report || echo "$target")"
  fi
  # allow.txt течёт в одну сторону: `--add-personal` пишет в живую копию, и `sync.sh` забирает её в
  # репозиторий. install её не перезаписывает вовсе (только сеет, когда живой нет) — поэтому
  # сравнивать её при установке нечего, иначе живой словарь с личными словами валил бы каждый restore.
  # deny.txt — политика репозитория: install перезаписывает её всегда, sync не копирует вовсе.
  [[ "$mode" == "sync" ]] \
    && dg_compare "$cfg/ru-spellcheck/allow.txt" "$ROOT/config/ru-spellcheck/allow.txt" "$target"
  return 0
}

# dg_report <mode> [refusal-text]: one `diff --stat` per diverged pair (a dry run is read as a report),
# then refuse — unless dry-run or --force — when a target side moved.
dg_report() {
  local mode="$1" hint="${2:-}" item live repo rel
  dg_enabled || return 0
  # `${ARRAY[@]+x}` вместо `((${#ARRAY[@]}))`: на bash 3.2 (штатный macOS) пустой массив под
  # `set -u` иначе валит скрипт с "unbound variable".
  [[ -n "${DG_ITEMS[@]+x}" ]] || return 0
  echo "two-copy guard: живая копия расходится с репозиторием:"
  local adds dels
  for item in "${DG_ITEMS[@]}"; do
    live="${item%%|*}"
    repo="${item#*|}"
    rel="${repo#"$ROOT"/}"
    adds="?"; dels="?"
    while read -r a d _; do adds="$a"; dels="$d"; done \
      < <(git -C "$ROOT" diff --numstat --no-index -- "$repo" "$live" 2>/dev/null || true)
    echo "  $rel  (+$adds −$dels строк; живая: ${live#"$HOME"/})"
  done
  echo "  полный дифф: git -C $ROOT diff --no-index -- <копия-репозитория> <живая-копия>"

  [[ -n "${DG_REFUSED[@]+x}" ]] || return 0
  {
    echo "two-copy guard: у цели есть собственные правки — молча перезаписать нельзя:"
    for item in "${DG_REFUSED[@]}"; do
      repo="${item#*|}"
      echo "  ${repo#"$ROOT"/}  (живая: ${item%%|*})"
    done
  } >&2
  if [[ "$mode" == "dry-run" ]]; then
    echo "two-copy guard: без --force такая запись была бы отказом" >&2
    return 0
  fi
  if [[ "${FORCE:-0}" == "1" ]]; then
    echo "two-copy guard: перезапись по --force" >&2
    return 0
  fi
  printf '%s\n' "${hint:-two-copy guard: перенесите правку в одну сторону и запустите снова, либо перезапишите осознанно: --force}" >&2
  exit 1
}

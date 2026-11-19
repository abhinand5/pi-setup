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
  if [[ "$target" == "live" ]]; then
    # install: replacing the live copy is safe only while live is still the committed version.
    dg_matches_head "$rel" "$live" && return 0
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

# dg_compare_tree <live_dir> <repo_dir> [target]: the same for every file present on both sides.
dg_compare_tree() {
  local live="$1" repo="$2" target="${3:-repo}" rel
  dg_enabled || return 0
  [[ -d "$live" && -d "$repo" ]] || return 0
  while IFS= read -r rel; do
    dg_compare "$live/$rel" "$repo/$rel" "$target"
  done < <(cd "$repo" && find . -type f -printf '%P\n' | sort)
}

# dg_standard_pairs [target]: every file this repo keeps in two copies.
dg_standard_pairs() {
  local target="${1:-repo}" live="${PI_HOME:-$HOME/.pi/agent}"
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  dg_compare "$live/AGENTS.md" "$ROOT/config/AGENTS.md" "$target"
  dg_compare "$live/docs/delegation-models.md" "$ROOT/config/delegation-models.md" "$target"
  dg_compare "$live/docs/session-logs.md" "$ROOT/config/session-logs.md" "$target"
  dg_compare "$cfg/ru-spellcheck/allow.txt" "$ROOT/config/ru-spellcheck/allow.txt" "$target"
  dg_compare "$cfg/ru-spellcheck/deny.txt" "$ROOT/config/ru-spellcheck/deny.txt" "$target"
  dg_compare_tree "$live/skills" "$ROOT/skills" "$target"
  dg_compare_tree "$live/themes" "$ROOT/themes" "$target"
  dg_compare_tree "$live/extensions" "$ROOT/extensions" "$target"
  dg_compare_tree "$HOME" "$ROOT/home" "$target"
}

# dg_report <mode> [refusal-text]: one `diff --stat` per diverged pair (a dry run is read as a report),
# then refuse — unless dry-run or --force — when a target side moved.
dg_report() {
  local mode="$1" hint="${2:-}" item live repo rel
  dg_enabled || return 0
  ((${#DG_ITEMS[@]})) || return 0
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

  ((${#DG_REFUSED[@]})) || return 0
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

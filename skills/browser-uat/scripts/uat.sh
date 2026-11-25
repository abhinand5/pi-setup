#!/usr/bin/env bash
# uat.sh — environment management for browser UAT through the Playwright MCP
# server. It does not drive the browser; the model does that with
# mcp__playwright__* tools. This script owns everything around those calls:
# preconditions, the virtual display, MCP config, and artifact hygiene.
#
#   uat.sh doctor                 check every precondition, with fixes
#   uat.sh config install         point ~/.pi/agent/mcp.json at the Xvfb wrapper
#   uat.sh config show            print the effective playwright config
#   uat.sh display start|stop|status   standalone Xvfb for manual debugging
#   uat.sh artifacts [list|clean|path] screenshots, snapshots, logs
#   uat.sh report                 print a UAT report template
#
# Run `uat.sh <command> --help` for details.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WRAPPER="$SCRIPT_DIR/playwright-mcp-xvfb.sh"
PI_HOME="${PI_HOME:-$HOME/.pi/agent}"
MCP_JSON="$PI_HOME/mcp.json"
# UAT_PLAYWRIGHT_CONFIG is the wrapper's documented override; doctor reads the same file,
# otherwise a user who moved the base config gets a report about the wrong one (#15799 п.1).
BASE_CONFIG="${UAT_PLAYWRIGHT_CONFIG:-$PI_HOME/playwright-mcp.json}"
ARTIFACTS="${UAT_ARTIFACTS:-${TMPDIR:-/tmp}/browser-uat}"
SCREEN="${UAT_SCREEN:-1920x1080x24}"

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_BAD=""; C_OFF=""
fi
ok()   { printf '  %s✓%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$C_BAD" "$C_OFF" "$*"; }
hint() { printf '      %s\n' "$*"; }

die() { printf 'uat: %s\n' "$*" >&2; exit 1; }

# The live wrapper path, as it should appear in mcp.json. Prefer the installed
# copy under $PI_HOME so the entry survives moving the repo checkout. Emit the
# "~/..." form when the path is under $HOME: Pi expands a leading ~/ in
# `command`, and sync.sh copies mcp.json into the portable checked-in example.
live_wrapper() {
  local installed="$PI_HOME/skills/browser-uat/scripts/playwright-mcp-xvfb.sh"
  if [[ ! -x "$installed" ]]; then
    die "wrapper not installed at $installed — run ./install.sh --restore (or --copy-config) first"
  fi
  local path="$installed"
  if [[ "$path" == "$HOME"/* ]]; then
    printf '~/%s\n' "${path#"$HOME"/}"
  else
    printf '%s\n' "$path"
  fi
}

# ---------------------------------------------------------------------------
cmd_doctor() {
  local skip_mcp=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-mcp) skip_mcp=1; shift ;;
      -h|--help)
        cat <<'EOF'
usage: uat.sh doctor [--no-mcp]

Checks npx, a browser, jq, Xvfb, the mcp.json playwright entry, the base
config, the wrapper, and the artifact directory. Prints the fix for anything
missing and exits non-zero on blocking problems.

  --no-mcp   skip the `pi mcp list` connection check (it takes a few seconds)
EOF
        exit 0 ;;
      *) die "doctor: unknown flag $1" ;;
    esac
  done

  local failures=0
  printf 'browser-uat doctor\n'

  printf '\nRuntime\n'
  if command -v npx >/dev/null 2>&1; then
    ok "npx $(npx --version 2>/dev/null)"
  else
    bad "npx not found — the MCP server cannot start"
    hint "install Node.js 20+, then restart pi"
    failures=$((failures + 1))
  fi

  local browser=""
  local c
  for c in google-chrome google-chrome-stable chromium chromium-browser; do
    if command -v "$c" >/dev/null 2>&1; then browser="$c"; break; fi
  done
  if [[ -z "$browser" ]]; then
    # shellcheck disable=SC2086
    browser="$(compgen -G "$HOME/.cache/ms-playwright/chromium-*" | head -1 || true)"
  fi
  if [[ -n "$browser" ]]; then
    ok "browser: $browser"
  else
    bad "no Chrome/Chromium found"
    hint "npx playwright install chromium"
    failures=$((failures + 1))
  fi

  if command -v jq >/dev/null 2>&1; then
    ok "jq $(jq --version 2>/dev/null)"
  else
    warn "jq not found — the wrapper cannot derive an Xvfb config; it will pass yours through"
    hint "sudo apt install jq"
  fi

  printf '\nVirtual display\n'
  if command -v Xvfb >/dev/null 2>&1; then
    ok "Xvfb $(Xvfb -help 2>&1 | head -1 | sed 's/^Xvfb //')"
  else
    warn "Xvfb not installed — the wrapper falls back to headless"
    hint "sudo apt install xvfb   # keeps the browser off your desktop"
  fi
  if [[ -n "${DISPLAY:-}" ]]; then
    ok "your desktop DISPLAY=$DISPLAY (the browser will not use it)"
  else
    ok "no desktop DISPLAY (irrelevant: the wrapper starts its own)"
  fi

  printf '\nMCP configuration\n'
  if [[ -f "$MCP_JSON" ]]; then
    local cmd
    if command -v jq >/dev/null 2>&1; then
      cmd="$(jq -r '.mcpServers.playwright.command // empty' "$MCP_JSON" 2>/dev/null || true)"
    elif grep -q 'playwright-mcp-xvfb.sh' "$MCP_JSON" 2>/dev/null; then
      cmd="playwright-mcp-xvfb.sh"
    else
      cmd=""
    fi
    if [[ -z "$cmd" ]]; then
      bad "no mcpServers.playwright entry in $MCP_JSON"
      hint "uat.sh config install"
      failures=$((failures + 1))
    elif [[ "$cmd" == *playwright-mcp-xvfb.sh ]]; then
      ok "playwright entry uses the Xvfb wrapper"
    else
      warn "playwright entry does not use the wrapper: $cmd"
      hint "the browser will open on your desktop and steal focus"
      hint "uat.sh config install"
    fi
  else
    bad "$MCP_JSON not found"
    hint "uat.sh config install"
    failures=$((failures + 1))
  fi

  if [[ -f "$BASE_CONFIG" ]]; then
    ok "base config: $BASE_CONFIG"
  else
    warn "no base config at $BASE_CONFIG — built-in defaults will be used"
    hint "uat.sh config install"
  fi

  if [[ -x "$WRAPPER" ]]; then
    ok "wrapper executable: $WRAPPER"
  else
    bad "wrapper missing or not executable: $WRAPPER"
    hint "chmod +x $WRAPPER"
    failures=$((failures + 1))
  fi

  printf '\nArtifacts\n'
  if mkdir -p "$ARTIFACTS" 2>/dev/null && [[ -w "$ARTIFACTS" ]]; then
    ok "$ARTIFACTS"
  else
    bad "cannot write $ARTIFACTS"
    hint "set UAT_ARTIFACTS to a writable directory"
    failures=$((failures + 1))
  fi

  if [[ "$skip_mcp" == "0" ]] && command -v pi >/dev/null 2>&1; then
    printf '\nServer connection\n'
    local out
    if command -v timeout >/dev/null 2>&1; then
      out="$(timeout 90 pi mcp list 2>&1 || true)"
    else
      out="$(pi mcp list 2>&1 || true)"
    fi
    if grep -q '^playwright: connected' <<<"$out"; then
      ok "$(grep '^playwright: connected' <<<"$out")"
    else
      warn "playwright is not connected in this shell"
      hint "run: pi mcp list   (a running session needs mcp({ connect: \"playwright\" }) or /reload after config changes)"
    fi
  fi

  printf '\n'
  if [[ "$failures" -gt 0 ]]; then
    printf 'doctor: %d blocking problem(s)\n' "$failures"
    return 1
  fi
  printf 'doctor: ready for browser UAT\n'
}

# ---------------------------------------------------------------------------
cmd_config() {
  local sub="${1:-show}"
  shift || true
  case "$sub" in
    show)
      printf 'mcp.json entry:\n'
      if [[ -f "$MCP_JSON" ]]; then
        jq '.mcpServers.playwright // "missing"' "$MCP_JSON"
      else
        printf '  (no %s)\n' "$MCP_JSON"
      fi
      printf '\nbase config (%s):\n' "$BASE_CONFIG"
      if [[ -f "$BASE_CONFIG" ]]; then cat "$BASE_CONFIG"; else printf '  (missing)\n'; fi
      ;;
    install)
      local dry=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run) dry=1; shift ;;
          -h|--help)
            cat <<'EOF'
usage: uat.sh config install [--dry-run]

Points ~/.pi/agent/mcp.json at the Xvfb wrapper and writes a base
~/.pi/agent/playwright-mcp.json if none exists. Backs up mcp.json first.
Run /reload (or restart pi) afterwards.
EOF
            exit 0 ;;
          *) die "config install: unknown flag $1" ;;
        esac
      done
      command -v jq >/dev/null 2>&1 || die "config install needs jq"

      local wrapper; wrapper="$(live_wrapper)"
      local wrapper_path="${wrapper/#\~/$HOME}"
      [[ -x "$wrapper_path" ]] || die "wrapper not executable: $wrapper_path"

      mkdir -p "$PI_HOME"
      local tmp; tmp="$(mktemp)"
      local clean_args='
        def clean_args:
          (if type == "array" then . else [] end)
          | reduce .[] as $a (
              {out: [], skip: false};
              if .skip then .skip = false
              elif $a == "--config" then .skip = true
              elif ($a | test("^--config=")) then .
              elif ($a == "-y" or $a == "--yes" or $a == "-n") then .
              elif ($a | test("^@playwright/mcp")) then .
              else .out += [$a]
              end
            )
          | .out
          | (if length == 0 then ["--isolated"] else . end)
          | (if index("--isolated") then . else ["--isolated"] + . end);
      '
      if [[ -f "$MCP_JSON" ]]; then
        jq --arg cmd "$wrapper" "$clean_args"'
          .mcpServers = (.mcpServers // {})
          | .mcpServers.playwright = {
              command: $cmd,
              args: (.mcpServers.playwright.args | clean_args),
              description: "Drive a real Chromium browser on a private Xvfb display: navigate, click, type, snapshot pages, screenshots, console/network"
            }
        ' "$MCP_JSON" >"$tmp" || { rm -f "$tmp"; die "could not parse $MCP_JSON"; }
      else
        jq -n --arg cmd "$wrapper" "$clean_args"'{
          mcpServers: {
            playwright: {
              command: $cmd,
              args: (["--isolated"] | clean_args),
              description: "Drive a real Chromium browser on a private Xvfb display: navigate, click, type, snapshot pages, screenshots, console/network"
            }
          }
        }' >"$tmp"
      fi

      if [[ "$dry" == "1" ]]; then
        printf 'would write %s:\n' "$MCP_JSON"
        cat "$tmp"
        rm -f "$tmp"
        return 0
      fi

      if [[ -f "$MCP_JSON" ]]; then
        local backup="$MCP_JSON.bak.$(date +%Y%m%d-%H%M%S)"
        cp "$MCP_JSON" "$backup"
        printf 'backed up %s -> %s\n' "$MCP_JSON" "$backup"
      fi
      mv "$tmp" "$MCP_JSON"
      printf 'wrote %s (playwright -> %s)\n' "$MCP_JSON" "$wrapper"

      if [[ ! -f "$BASE_CONFIG" ]]; then
        local src="$SKILL_DIR/../../config/playwright-mcp.json"
        if [[ -f "$src" ]]; then
          cp "$src" "$BASE_CONFIG"
        else
          cat >"$BASE_CONFIG" <<'EOF'
{
  "browser": {
    "launchOptions": { "args": ["--start-maximized", "--ozone-platform=x11"] },
    "contextOptions": { "viewport": null }
  }
}
EOF
        fi
        printf 'wrote %s\n' "$BASE_CONFIG"
      else
        printf 'kept existing %s\n' "$BASE_CONFIG"
      fi

      printf '\nNext: restart the server — mcp({ connect: "playwright" }) (fallback: /reload in pi), then: uat.sh doctor\n'
      ;;
    *) die "config: unknown subcommand '$sub' (show|install)" ;;
  esac
}

# ---------------------------------------------------------------------------
display_pidfile() { printf '%s/display.pid\n' "$ARTIFACTS"; }
display_numfile() { printf '%s/display.num\n' "$ARTIFACTS"; }

display_running() {
  local pf; pf="$(display_pidfile)"
  [[ -f "$pf" ]] || return 1
  local pid; pid="$(cat "$pf" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if ! pid_is_xvfb "$pid"; then
    # Stale pidfile pointing at an unrelated process: never signal it.
    rm -f "$pf" "$(display_numfile)"
    return 1
  fi
  return 0
}

pid_is_xvfb() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  if [[ -r "/proc/$pid/cmdline" ]]; then
    local argv0
    argv0="$(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | head -1)"
    [[ "$(basename -- "$argv0")" == "Xvfb" ]]
  else
    [[ "$(ps -p "$pid" -o comm= 2>/dev/null | tr -d '[:space:]')" == "Xvfb" ]]
  fi
}

cmd_display() {
  local sub="${1:-status}"
  shift || true
  case "$sub" in
    start)
      local disp="" screen="$SCREEN"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --display) disp="${2:?}"; shift 2 ;;
          --screen) screen="${2:?}"; shift 2 ;;
          -h|--help)
            cat <<'EOF'
usage: uat.sh display start [--display :N] [--screen WxHxD]

Starts a standalone Xvfb for manual debugging (e.g. running a headed browser
by hand with DISPLAY=:N). The MCP server does not need this: its wrapper starts
and stops its own display. Stop it with `uat.sh display stop`.
EOF
            exit 0 ;;
          *) die "display start: unknown flag $1" ;;
        esac
      done
      command -v Xvfb >/dev/null 2>&1 || die "Xvfb not installed: sudo apt install xvfb"
      if [[ -n "$disp" && "$disp" != :* ]]; then
        die "display start: --display must look like :N (got '$disp')"
      fi
      if display_running; then
        printf 'already running on %s (pid %s)\n' "$(cat "$(display_numfile)")" "$(cat "$(display_pidfile)")"
        return 0
      fi
      mkdir -p "$ARTIFACTS"
      if [[ -z "$disp" ]]; then
        local n
        for n in $(seq 99 120); do
          if [[ ! -e "/tmp/.X11-unix/X$n" && ! -e "/tmp/.X$n-lock" ]]; then disp=":$n"; break; fi
        done
        [[ -n "$disp" ]] || die "no free display in :99-:120"
      fi
      Xvfb "$disp" -screen 0 "$screen" -nolisten tcp -noreset \
        >"$ARTIFACTS/xvfb.log" 2>&1 &
      local pid=$!
      local i
      for i in $(seq 1 100); do
        [[ -e "/tmp/.X11-unix/X${disp#:}" ]] && break
        kill -0 "$pid" 2>/dev/null || die "Xvfb died; see $ARTIFACTS/xvfb.log"
        sleep 0.1
      done
      if [[ ! -e "/tmp/.X11-unix/X${disp#:}" ]]; then
        kill "$pid" 2>/dev/null || true
        die "Xvfb did not create /tmp/.X11-unix/X${disp#:}; see $ARTIFACTS/xvfb.log"
      fi
      printf '%s\n' "$pid" >"$(display_pidfile)"
      printf '%s\n' "$disp" >"$(display_numfile)"
      printf 'Xvfb %s %s (pid %s)\n' "$disp" "$screen" "$pid"
      printf 'use it with: DISPLAY=%s <command>\n' "$disp"
      ;;
    stop)
      if ! display_running; then
        printf 'not running\n'
        rm -f "$(display_pidfile)" "$(display_numfile)"
        return 0
      fi
      local pid; pid="$(cat "$(display_pidfile)")"
      kill "$pid" 2>/dev/null || true
      local i
      for i in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      if pid_is_xvfb "$pid"; then
        kill -9 "$pid" 2>/dev/null || true
      fi
      rm -f "$(display_pidfile)" "$(display_numfile)"
      printf 'stopped (pid %s)\n' "$pid"
      ;;
    status)
      if display_running; then
        printf 'running: %s (pid %s)\n' "$(cat "$(display_numfile)")" "$(cat "$(display_pidfile)")"
      else
        printf 'not running\n'
      fi
      ;;
    *) die "display: unknown subcommand '$sub' (start|stop|status)" ;;
  esac
}

# ---------------------------------------------------------------------------
cmd_artifacts() {
  local sub="${1:-list}"
  case "$sub" in
    path) printf '%s\n' "$ARTIFACTS" ;;
    list)
      [[ -d "$ARTIFACTS" ]] || { printf 'no artifacts yet (%s)\n' "$ARTIFACTS"; return 0; }
      printf '%s\n' "$ARTIFACTS"
      find "$ARTIFACTS" -maxdepth 1 -type f | sort | while IFS= read -r f; do
        printf '  %-40s %8s bytes\n' "$(basename "$f")" "$(wc -c <"$f" | tr -d ' ')"
      done
      ;;
    clean)
      [[ -d "$ARTIFACTS" ]] || { printf 'nothing to clean\n'; return 0; }
      local resolved; resolved="$(cd "$ARTIFACTS" && pwd -P)"
      local home_phys; home_phys="$(cd "$HOME" 2>/dev/null && pwd -P || printf '%s' "$HOME")"
      local stripped="${resolved#/}"
      local comps
      comps="$(printf '%s' "$stripped" | tr -cd '/' | wc -c)"
      comps=$((comps + 1))
      if [[ "$resolved" == "/" || "$resolved" == "$HOME" || "$resolved" == "$home_phys" || "$comps" -lt 2 ]]; then
        die "artifacts clean: refusing to delete $resolved (set UAT_ARTIFACTS to a dedicated directory)"
      fi
      find "$resolved" -mindepth 1 -maxdepth 1 ! -name 'display.pid' ! -name 'display.num' -exec rm -rf {} + 2>/dev/null || true
      printf 'cleaned %s\n' "$resolved"
      ;;
    *) die "artifacts: unknown subcommand '$sub' (list|clean|path)" ;;
  esac
}

# ---------------------------------------------------------------------------
cmd_report() {
  cat <<'EOF'
# UAT report — <feature / branch>

Target: <url>   Browser: Chromium on Xvfb   Date: <date>

## Inventory

| # | Control / flow | Expected state change | Result | Evidence |
|---|----------------|-----------------------|--------|----------|
| 1 |                |                       |        |          |
| 2 |                |                       |        |          |

## Off-happy-path

| # | Scenario | Expected | Result | Evidence |
|---|----------|----------|--------|----------|
| 1 | empty input | | | |
| 2 | wrong credentials | | | |
| 3 | double submit | | | |

## Console / network

- console errors:
- failed requests:

## Verdict

<pass / fail per item, with the screenshot or snapshot that proves it>
EOF
}

# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
uat.sh — environment management for browser UAT (Playwright MCP)

  doctor                     check preconditions; prints fixes
  config show                print the effective playwright config
  config install [--dry-run] point ~/.pi/agent/mcp.json at the Xvfb wrapper
  display start|stop|status  standalone Xvfb for manual debugging
  artifacts list|clean|path  screenshots, snapshots, logs
  report                     print a UAT report template

The browser itself is driven with mcp__playwright__* tools, not from here.
Artifacts default to $TMPDIR/browser-uat (override with UAT_ARTIFACTS).
EOF
}

case "${1:-help}" in
  doctor) shift; cmd_doctor "$@" ;;
  config) shift; cmd_config "$@" ;;
  display) shift; cmd_display "$@" ;;
  artifacts) shift; cmd_artifacts "$@" ;;
  report) shift; cmd_report "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; die "unknown command '$1'" ;;
esac

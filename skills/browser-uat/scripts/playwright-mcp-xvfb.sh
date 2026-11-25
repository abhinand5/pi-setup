#!/usr/bin/env bash
# Launch the Playwright MCP server on a private Xvfb display.
#
# This is the `command` in ~/.pi/agent/mcp.json. It exists so the browser never
# touches the user's real desktop: no window stealing focus, no fullscreen
# takeover, no maximized window on top of the editor. Everything the browser
# draws goes to a throwaway X server that dies with the MCP server.
#
# stdout is the MCP stdio channel. Never write anything but the server's own
# protocol output there; all diagnostics go to stderr.
#
# Environment:
#   UAT_HEADLESS=1        skip Xvfb, run the browser headless
#   UAT_SCREEN=WxHxD      Xvfb screen geometry (default 1920x1080x24)
#   UAT_ARTIFACTS=DIR     screenshots/snapshots/logs (default $TMPDIR/browser-uat)
#   UAT_IDLE_TIMEOUT=MS   close an idle browser (default 900000 = 15 min)
#   UAT_MCP_PKG=SPEC      server package (default @playwright/mcp@0.0.84)
#   UAT_STORAGE_STATE=P   saved login written by a project login command
#                         (default $PI_HOME/uat-auth/current.json);
#                         passed to the server as PLAYWRIGHT_MCP_STORAGE_STATE
#   UAT_PLAYWRIGHT_CONFIG base config (default ~/.pi/agent/playwright-mcp.json)
#
# Any arguments are passed through to @playwright/mcp, except --config, which
# this script owns (it derives an Xvfb-specific config from the base one).
set -euo pipefail

log() { printf 'browser-uat: %s\n' "$*" >&2; }

PI_HOME="${PI_HOME:-$HOME/.pi/agent}"
SCREEN="${UAT_SCREEN:-1920x1080x24}"
ARTIFACTS="${UAT_ARTIFACTS:-${TMPDIR:-/tmp}/browser-uat}"
IDLE_TIMEOUT="${UAT_IDLE_TIMEOUT:-900000}"
MCP_PKG="${UAT_MCP_PKG:-@playwright/mcp@0.0.84}"
BASE_CONFIG="${UAT_PLAYWRIGHT_CONFIG:-$PI_HOME/playwright-mcp.json}"

mkdir -p "$ARTIFACTS"
XVFB_LOG="$ARTIFACTS/xvfb.log.$$"

# --- split our own flags from the pass-through args -------------------------
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      BASE_CONFIG="${2:?--config needs a path}"
      shift 2
      ;;
    --config=*)
      BASE_CONFIG="${1#--config=}"
      shift
      ;;
    *)
      PASSTHROUGH+=("$1")
      shift
      ;;
  esac
done

# --- display lifecycle ------------------------------------------------------
XVFB_PID=""
DISPLAY_NUM=""
NUMFILE=""
DERIVED_CONFIG=""

cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$XVFB_PID" ]] && kill -0 "$XVFB_PID" 2>/dev/null; then
    kill "$XVFB_PID" 2>/dev/null || true
    wait "$XVFB_PID" 2>/dev/null || true
  fi
  if [[ -n "$NUMFILE" ]]; then rm -f "$NUMFILE"; fi
  if [[ -n "$DERIVED_CONFIG" ]]; then rm -f "$DERIVED_CONFIG"; fi
  # Keep the Xvfb log on failure for post-mortems; drop it on a clean exit.
  if [[ "$rc" -eq 0 ]]; then rm -f "$XVFB_LOG"; fi
  exit "$rc"
}
trap cleanup EXIT INT TERM HUP

# Let Xvfb pick the display number itself (-displayfd) instead of scanning for a
# free one: two sessions starting at once cannot race for the same display.
start_xvfb() {
  NUMFILE="$ARTIFACTS/.displaynum.$$"
  : >"$NUMFILE"
  # -noreset keeps the server alive between browser restarts; -nolisten tcp
  # keeps it off the network. Output goes to a log, never to stdout.
  Xvfb -displayfd 3 -screen 0 "$SCREEN" -nolisten tcp -noreset \
    >"$XVFB_LOG" 2>&1 3>"$NUMFILE" &
  XVFB_PID=$!
  local i num=""
  for i in $(seq 1 100); do
    num="$(tr -d '[:space:]' <"$NUMFILE" 2>/dev/null || true)"
    [[ -n "$num" ]] && break
    if ! kill -0 "$XVFB_PID" 2>/dev/null; then
      log "Xvfb died; see $XVFB_LOG"
      rm -f "$NUMFILE"
      return 1
    fi
    sleep 0.1
  done
  rm -f "$NUMFILE"
  NUMFILE=""
  if [[ -z "$num" ]]; then
    log "Xvfb did not report a display within 10s"
    return 1
  fi
  DISPLAY_NUM=":$num"
  return 0
}

# --- config: derive an Xvfb variant from the user's base config -------------
# Without a window manager, --start-maximized is a no-op, so the window would
# open at Chromium's default size. --window-size is honoured without a WM.
derive_config() {
  local base="$1" out="$2" w h
  w="${SCREEN%%x*}"
  h="${SCREEN#*x}"; h="${h%%x*}"
  if [[ ! -f "$base" ]]; then
    log "no base config at $base; using built-in defaults"
    printf '{"browser":{"launchOptions":{"args":["--window-size=%s,%s"]},"contextOptions":{"viewport":null}}}\n' \
      "$w" "$h" >"$out"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log "jq not found; passing the base config through unchanged"
    printf '%s\n' "$base"
    return 0
  fi
  jq --arg size "$w,$h" '
    .browser = (.browser // {})
    | .browser.launchOptions = (.browser.launchOptions // {})
    | .browser.launchOptions.args =
        ((.browser.launchOptions.args // [])
         | map(select(. != "--start-maximized"))
         + ["--window-size=\($size)"])
    | .browser.contextOptions = (.browser.contextOptions // {})
    | .browser.contextOptions.viewport = null
  ' "$base" >"$out" 2>"$out.err" || {
    log "could not derive config from $base; using it unchanged"
    cat "$out.err" >&2 2>/dev/null || true
    rm -f "$out" "$out.err"
    printf '%s\n' "$base"
    return 0
  }
  rm -f "$out.err"
  printf '%s\n' "$out"
}

# --- saved login (written by the project's login command) -------------------
# The server runs with --isolated (see mcp.json), so the profile lives in memory
# and a saved storage state is the only way an authenticated session survives a
# server restart. This wrapper only reads it — the login procedure belongs to the
# project skill (msb-lk: .pi/skills/test-farm-uat/scripts/uat.sh login), and
# UAT_STORAGE_STATE points the server at another profile.
if [[ -z "${PLAYWRIGHT_MCP_STORAGE_STATE:-}" ]]; then
  # current.json is the profile written by the last login; it lives outside
  # skills/ so a restore does not delete it.
  STATE_FILE="${UAT_STORAGE_STATE:-$PI_HOME/uat-auth/current.json}"
  if [[ -f "$STATE_FILE" ]]; then
    export PLAYWRIGHT_MCP_STORAGE_STATE="$STATE_FILE"
    log "saved login: $STATE_FILE"
  fi
fi

ARGS=(--output-dir "$ARTIFACTS" --idle-timeout "$IDLE_TIMEOUT" --file-paths absolute)

if [[ "${UAT_HEADLESS:-0}" == "1" ]]; then
  log "UAT_HEADLESS=1: running headless"
  ARGS+=(--headless)
  if [[ -f "$BASE_CONFIG" ]]; then ARGS+=(--config "$BASE_CONFIG"); fi
elif ! command -v Xvfb >/dev/null 2>&1; then
  log "Xvfb not installed: falling back to headless (install: sudo apt install xvfb)"
  ARGS+=(--headless)
  if [[ -f "$BASE_CONFIG" ]]; then ARGS+=(--config "$BASE_CONFIG"); fi
else
  if ! start_xvfb; then
    log "falling back to headless"
    ARGS+=(--headless)
    if [[ -f "$BASE_CONFIG" ]]; then ARGS+=(--config "$BASE_CONFIG"); fi
  else
    export DISPLAY="$DISPLAY_NUM"
    unset WAYLAND_DISPLAY
    log "Xvfb $DISPLAY_NUM ${SCREEN} (pid $XVFB_PID), artifacts in $ARTIFACTS"
    cfg="$(derive_config "$BASE_CONFIG" "$ARTIFACTS/playwright-mcp.xvfb.$$.json")"
    if [[ "$cfg" == "$ARTIFACTS/playwright-mcp.xvfb.$$.json" ]]; then DERIVED_CONFIG="$cfg"; fi
    ARGS+=(--config "$cfg")
  fi
fi

# --- run the server ---------------------------------------------------------
# Foreground on purpose: a backgrounded command in a non-interactive shell gets
# stdin from /dev/null, which silently breaks the MCP stdio channel. The EXIT
# trap above is what stops Xvfb when the server goes away.
npx -y "$MCP_PKG" "${ARGS[@]}" "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"

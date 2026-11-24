#!/usr/bin/env bash
# uat.sh login: a stand that sends a logged-in session to "/" is not a failed login (#16027 п.2).
#
# Why: on the farm the browser lands on "/" after a successful submit, while the script judged the
# login by the URL alone and printed «вход не прошёл — страница /, ожидался путь /admin» with three
# cookies already written. The state file is written only on success, so the MCP browser then came
# up as a guest — two login runs and an MCP restart in that session.
#
# Three layers here, all with a stub `playwright` (no network at all):
#   * farm: landed on "/", the probe of --success answers 200 → login passes;
#   * landed: the browser itself lands under --success → passes without a probe;
#   * probe-guest: landed on "/", the probe is redirected into /login → the real failure is named.
#
# Removing the probe keeps the first layer red, so the test measures the fix and not the log line.
#
# Exit 0 — all checks passed; 1 — a check failed.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/browser-uat/scripts" && pwd)"
LOGIN="$SCRIPTS/uat-login.mjs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$LOGIN" ]] || fail "нет $LOGIN"
command -v node >/dev/null || fail "нужен node"

# HOME is faked: `npm root -g` writes a log into $HOME/.npm on every launch.
mkdir -p "$WORK/home"

# The stub Playwright package: a login form that ends where the scenario says, and an API request
# context that answers like the stand. Everything the script touches is recorded, so the assertions
# can tell "the probe decided" from "the URL decided".
mkdir -p "$WORK/fake-pw/playwright"
cat > "$WORK/fake-pw/playwright/index.js" <<'EOF'
const fs = require('node:fs');

const scenario = process.env.STUB_SCENARIO || 'farm';
const callsFile = process.env.STUB_CALLS;
const record = (entry) => {
  if (callsFile) fs.appendFileSync(callsFile, JSON.stringify(entry) + '\n');
};

const SIGN_IN = 'http://localhost/admin/login/sign-in';
const LANDING = {
  farm: 'http://localhost/',
  landed: 'http://localhost/admin/schedule/update?id=24568',
  'probe-guest': 'http://localhost/',
  'probe-forbidden': 'http://localhost/',
  'probe-broken': 'http://localhost/',
  'probe-error': 'http://localhost/',
  'no-cookies': 'http://localhost/',
};

module.exports = {
  chromium: {
    launch: async () => {
      let current = SIGN_IN;
      const page = {
        setDefaultTimeout() {},
        async goto(url) { current = url; },
        async fill(selector, value) { record({ fill: selector, value }); },
        async click(selector) {
          record({ click: selector });
          current = LANDING[scenario] || LANDING.farm;
        },
        // The script passes its own predicate: the stub only answers "did we land there".
        async waitForURL(predicate) {
          if (predicate(new URL(current))) return;
          throw new Error('stub: timeout waiting for the URL');
        },
        url() { return current; },
        async title() { return 'Вход в кабинет'; },
      };
      const context = {
        newPage: async () => page,
        storageState: async () => ({
          cookies: scenario === 'no-cookies'
            ? []
            : [{ name: 'PHPSESSID' }, { name: 'csrf' }, { name: 'hint' }],
        }),
        request: {
          async get(url, options) {
            record({ get: url, options });
            if (scenario === 'probe-error') throw new Error('net::ERR_TUNNEL_CONNECTION_FAILED');
            if (scenario === 'probe-forbidden') return { status: () => 403, headers: () => ({}) };
            if (scenario === 'probe-broken') return { status: () => 404, headers: () => ({}) };
            if (scenario === 'probe-guest') {
              return { status: () => 302, headers: () => ({ location: 'http://localhost/admin/login/index' }) };
            }
            return { status: () => 200, headers: () => ({}) };
          },
        },
        close: async () => {},
      };
      return { newContext: async () => context, close: async () => {} };
    },
  },
};
EOF

# run <scenario> [extra env assignments...] — one full login against the stub; sets OUT, RC,
# STATE, CALLS for the assertions.
run() {
  local scenario="$1" rc=0
  shift
  STATE="$WORK/state-$scenario.json"
  CALLS="$WORK/calls-$scenario.log"
  : > "$CALLS"
  rm -f "$STATE"
  OUT="$(env HOME="$WORK/home" UAT_PLAYWRIGHT_ROOT="$WORK/fake-pw" STUB_SCENARIO="$scenario" \
    STUB_CALLS="$CALLS" UAT_LOGIN_URL='http://localhost/admin/login/sign-in' \
    UAT_LOGIN_PHONE='+79990000000' UAT_LOGIN_CODE='1234' UAT_LOGIN_STATE="$STATE" \
    "$@" node "$LOGIN" 2>&1)" || rc=$?
  RC="$rc"
}

# --- farm: landed on "/", the probe of --success says the session is alive -------------------
run farm
[[ "$RC" == "0" ]] || fail "ферма: вход не засчитан при живой сессии (код $RC): $OUT"
[[ -s "$STATE" ]] || fail "ферма: файл состояния не записан при успешном входе: $OUT"
grep -q 'подтверждён запросом /admin' <<<"$OUT" || fail "ферма: подтверждение запросом не названо: $OUT"
grep -q '"get":"http://localhost/admin"' "$CALLS" || fail "ферма: запрос к /admin не сделан: $(cat "$CALLS")"
# No redirect following: a guest is told apart by the 302 itself, and following it would land on
# the login page with a 200 and look like a live session.
grep -q '"maxRedirects":0' "$CALLS" || fail "ферма: запрос пошёл по редиректам: $(cat "$CALLS")"
grep -q 'вход не прошёл' <<<"$OUT" && fail "ферма: живая сессия названа отказом: $OUT"

# --- landed: the browser itself lands under --success, no probe needed ----------------------
run landed
[[ "$RC" == "0" ]] || fail "адрес под --success: вход не засчитан (код $RC): $OUT"
[[ -s "$STATE" ]] || fail "адрес под --success: файл состояния не записан: $OUT"
grep -q '"get"' "$CALLS" && fail "адрес под --success: лишний запрос-проверка: $(cat "$CALLS")"

# --- probe-guest: landed on "/", the probe is redirected into /login ------------------------
run probe-guest
[[ "$RC" == "1" ]] || fail "гость: отказ не назван (код $RC): $OUT"
[[ -e "$STATE" ]] && fail "гость: файл состояния записан без сессии: $OUT"
grep -q 'вход не прошёл' <<<"$OUT" || fail "гость: отказ не назван словами: $OUT"
grep -q '302' <<<"$OUT" || fail "гость: ответ проверки не назван: $OUT"

# --- login area as --success: the page answers 200 to a guest, so it must not confirm a login --
run farm UAT_LOGIN_SUCCESS='/admin/login/index'
[[ "$RC" == "1" ]] || fail "--success в области входа: гость назван вошедшим (код $RC): $OUT"
[[ -e "$STATE" ]] && fail "--success в области входа: файл состояния записан: $OUT"
grep -q '"get"' "$CALLS" && fail "--success в области входа: запрос к странице входа всё-таки сделан: $(cat "$CALLS")"
grep -q 'проверка не выполнялась' <<<"$OUT" || fail "--success в области входа: проверка названа выполненной: $OUT"
grep -q 'ведёт в область входа' <<<"$OUT" && fail "--success в области входа: рассказан невыполненный запрос: $OUT"

# --- probe-broken: the path or the stand is wrong, the login is not ------------------------
run probe-broken
[[ "$RC" == "1" ]] || fail "404: отказ не назван (код $RC): $OUT"
[[ -e "$STATE" ]] && fail "404: файл состояния записан: $OUT"
grep -q 'ответил 404' <<<"$OUT" || fail "404: ответ стенда не назван: $OUT"
grep -q 'вход не прошёл' <<<"$OUT" && fail "404: ошибка пути названа отказом входа: $OUT"

# --- no-cookies: no session, so no probe at all --------------------------------------------
run no-cookies
[[ "$RC" == "1" ]] || fail "нет cookie: отказ не назван (код $RC): $OUT"
[[ -e "$STATE" ]] && fail "нет cookie: файл состояния записан: $OUT"
grep -q 'проверка запросом не выполнялась' <<<"$OUT" || fail "нет cookie: выдуман невыполненный запрос: $OUT"
grep -q '"get"' "$CALLS" && fail "нет cookie: запрос сделан без сессии: $(cat "$CALLS")"

# --- probe-forbidden: session exists, this user has no access to --success ------------------
run probe-forbidden
[[ "$RC" == "1" ]] || fail "403: отказ не назван (код $RC): $OUT"
[[ -e "$STATE" ]] && fail "403: файл состояния записан без доступа: $OUT"
grep -q 'доступа к /admin нет' <<<"$OUT" || fail "403: нет доступа не назван отдельно: $OUT"
grep -q 'вход не прошёл' <<<"$OUT" && fail "403: живая сессия названа отказом входа: $OUT"

# --- probe-error: the stand never answered the probe ---------------------------------------
run probe-error
[[ "$RC" == "1" ]] || fail "сеть: провал не назван (код $RC): $OUT"
[[ -e "$STATE" ]] && fail "сеть: файл состояния записан без проверки: $OUT"
grep -q 'состояние не проверено' <<<"$OUT" || fail "сеть: проверка не названа непроведённой: $OUT"
grep -q 'вход не прошёл' <<<"$OUT" && fail "сеть: неотвеченный запрос назван отказом входа: $OUT"

# --- --success / is refused: it degenerates both checks and would write a guest state ------
run farm UAT_LOGIN_SUCCESS='/'
[[ "$RC" == "2" ]] || fail "--success /: вырожденный флаг не отклонён (код $RC): $OUT"
[[ -e "$STATE" ]] && fail "--success /: файл состояния записан: $OUT"
grep -q 'не годится' <<<"$OUT" || fail "--success /: отказ не назван: $OUT"

echo "OK: uat-login считает вход по состоянию сессии, а не по адресу (#16027 п.2)"

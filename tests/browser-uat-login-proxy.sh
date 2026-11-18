#!/usr/bin/env bash
# uat.sh login: the proxy comes from the same base config the MCP browser reads, and the loopback
# host is rewritten to localhost (#15799 п.1).
#
# Why: a bare chromium.launch() goes direct while the MCP browser uses
# ~/.pi/agent/playwright-mcp.json, so with HTTP_PROXY exported in the session the login timed out
# on 127.0.0.1 — three runs out of three. And the saved storage state is domain-scoped, so a login
# made on 127.0.0.1 is a guest in a browser that opens localhost.
#
# Two layers here:
#   * --dry-run checks what the command resolves and prints (no browser at all);
#   * a stub `playwright` module records the options chromium.launch() actually received, so the
#     proxy is checked where it matters, not only in the log line. Without that layer, deleting the
#     env pass-through or the `proxy:` field keeps every assertion green.
#
# Exit 0 — all checks passed; 1 — a check failed.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills/browser-uat/scripts" && pwd)"
UAT="$SCRIPTS/uat.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -x "$UAT" ]] || fail "нет $UAT"
command -v jq >/dev/null || fail "нужен jq (login читает им base config)"

export PI_HOME="$WORK/pi-home"
mkdir -p "$PI_HOME"
cat > "$PI_HOME/playwright-mcp.json" <<'EOF'
{
  "browser": {
    "contextOptions": {
      "viewport": null,
      "proxy": {
        "server": "http://127.0.0.1:10808",
        "bypass": "localhost,127.0.0.1"
      }
    }
  }
}
EOF

env_file="$WORK/.env"
printf 'ADMIN_PHONE_NUMBER=+79990000000\nADMIN_PHONE_CODE=1234\n' > "$env_file"

# The stub Playwright package: records launch options, then fails like an unreachable page.
mkdir -p "$WORK/fake-pw/playwright"
cat > "$WORK/fake-pw/playwright/index.js" <<'EOF'
const fs = require('node:fs');
module.exports = {
  chromium: {
    launch: async (options) => {
      fs.writeFileSync(process.env.STUB_OUT, JSON.stringify(options));
      const page = { setDefaultTimeout() {}, goto: async () => { throw new Error('stub: no network'); } };
      const context = { newPage: async () => page, close: async () => {}, storageState: async () => ({ cookies: [] }) };
      return { newContext: async () => context, close: async () => {} };
    },
  },
};
EOF

# A wrapper override or a session URL would make the test read the developer's real values.
# HOME is faked too: `npm root -g` writes a log into $HOME/.npm on every launch.
mkdir -p "$WORK/home"
run() { env -u UAT_LOGIN_URL -u UAT_LOGIN_ENV -u UAT_PLAYWRIGHT_CONFIG HOME="$WORK/home" "$@" 2>&1; }

# --- what the command resolves and prints (--dry-run) -----------------------
out="$(run bash "$UAT" login --url http://127.0.0.1/admin/login/sign-in --env "$env_file" --profile local --dry-run)" \
    || fail "dry run упал: $out"
grep -q 'host 127.0.0.1 → localhost' <<<"$out" || fail "хост не переписан: $out"
grep -q 'url http://localhost/admin/login/sign-in' <<<"$out" || fail "URL не переписан на localhost: $out"
grep -q 'proxy http://127.0.0.1:10808 (bypass: localhost,127.0.0.1)' <<<"$out" \
    || fail "прокси не взят из base config: $out"

# The port survives the rewrite: only the host is replaced.
out="$(run bash "$UAT" login --url http://127.0.0.1:8080/admin/login/sign-in --env "$env_file" --dry-run)" \
    || fail "dry run с портом упал: $out"
grep -q 'url http://localhost:8080/admin/login/sign-in' <<<"$out" || fail "порт потерян при подмене хоста: $out"

# --keep-host leaves the URL alone and says nothing about a rewrite.
out="$(run bash "$UAT" login --url http://127.0.0.1/admin/login/sign-in --env "$env_file" --keep-host --dry-run)" \
    || fail "dry run с --keep-host упал: $out"
grep -q 'url http://127.0.0.1/admin/login/sign-in' <<<"$out" || fail "--keep-host переписал хост: $out"
grep -q 'host 127.0.0.1 → localhost' <<<"$out" && fail "--keep-host не должен печатать подмену: $out"

# --proxy-server overrides the server, the bypass list still comes from the config.
out="$(run bash "$UAT" login --url http://localhost/admin/login/sign-in --env "$env_file" \
    --proxy-server http://proxy.example:3128 --dry-run)" || fail "dry run с --proxy-server упал: $out"
grep -q 'proxy http://proxy.example:3128 (bypass: localhost,127.0.0.1)' <<<"$out" \
    || fail "--proxy-server не переопределил прокси: $out"

# --no-proxy goes direct even though the config names one.
out="$(run bash "$UAT" login --url http://localhost/admin/login/sign-in --env "$env_file" --no-proxy --dry-run)" \
    || fail "dry run с --no-proxy упал: $out"
grep -q 'proxy none' <<<"$out" || fail "--no-proxy не выключил прокси: $out"

# No base config at all: direct connection, no failure.
mv "$PI_HOME/playwright-mcp.json" "$WORK/playwright-mcp.json"
out="$(run bash "$UAT" login --url http://localhost/admin/login/sign-in --env "$env_file" --dry-run)" \
    || fail "dry run без base config упал: $out"
grep -q 'proxy none' <<<"$out" || fail "без base config прокси обязан быть пустым: $out"
mv "$WORK/playwright-mcp.json" "$PI_HOME/playwright-mcp.json"

# The wrapper's own override (UAT_PLAYWRIGHT_CONFIG) moves the base config for login as well:
# reading a different file than the wrapper is how the two routes diverge again.
cat > "$WORK/alt-config.json" <<'EOF'
{"browser": {"contextOptions": {"proxy": {"server": "http://alt-proxy:9999", "bypass": "localhost"}}}}
EOF
out="$(run UAT_PLAYWRIGHT_CONFIG="$WORK/alt-config.json" \
    bash "$UAT" login --url http://localhost/admin/login/sign-in --env "$env_file" --dry-run)" \
    || fail "dry run с UAT_PLAYWRIGHT_CONFIG упал: $out"
grep -q 'proxy http://alt-proxy:9999 (bypass: localhost)' <<<"$out" \
    || fail "UAT_PLAYWRIGHT_CONFIG проигнорирован: $out"

# Without jq the proxy cannot be read from the config, and silence there is the original defect:
# the wrapper passes the config through anyway, so the MCP browser would take the proxy alone.
mkdir -p "$WORK/bin-nojq"
for tool in dirname sed grep cut tr head cp chmod mkdir node cat sort tail wc; do
    ln -sf "$(command -v "$tool")" "$WORK/bin-nojq/$tool"
done
out="$(env -u UAT_LOGIN_URL -u UAT_LOGIN_ENV -u UAT_PLAYWRIGHT_CONFIG HOME="$WORK/home" \
    PATH="$WORK/bin-nojq" /bin/bash "$UAT" login --url http://localhost/admin/login/sign-in \
    --env "$env_file" --dry-run 2>&1)" || fail "dry run без jq упал: $out"
grep -q 'jq не найден' <<<"$out" || fail "отсутствие jq не названо: $out"

# With --proxy-server the route is known, so the jq warning would be a lie.
out="$(env -u UAT_LOGIN_URL -u UAT_LOGIN_ENV -u UAT_PLAYWRIGHT_CONFIG HOME="$WORK/home" \
    PATH="$WORK/bin-nojq" /bin/bash "$UAT" login --url http://localhost/admin/login/sign-in \
    --env "$env_file" --proxy-server http://proxy.example:3128 --dry-run 2>&1)" \
    || fail "dry run без jq с --proxy-server упал: $out"
grep -q 'jq не найден' <<<"$out" && fail "предупреждение про jq при заданном --proxy-server: $out"
grep -q 'proxy http://proxy.example:3128' <<<"$out" || fail "--proxy-server потерян без jq: $out"

# The proxy URL may carry credentials: they must not reach the transcript.
cat > "$PI_HOME/playwright-mcp.json" <<'EOF'
{"browser": {"contextOptions": {"proxy": {"server": "http://uat-user:uat-secret@proxy.example:3128"}}}}
EOF
out="$(run bash "$UAT" login --url http://localhost/admin/login/sign-in --env "$env_file" --dry-run)" \
    || fail "dry run с userinfo в прокси упал: $out"
grep -q 'uat-secret' <<<"$out" && fail "пароль прокси попал в вывод: $out"
grep -qF 'proxy http://***@proxy.example:3128' <<<"$out" || fail "прокси не замаскирован: $out"
# Userinfo without a password is still userinfo.
cat > "$PI_HOME/playwright-mcp.json" <<'EOF'
{"browser": {"contextOptions": {"proxy": {"server": "http://uat-user@proxy.example:3128"}}}}
EOF
out="$(run bash "$UAT" login --url http://localhost/admin/login/sign-in --env "$env_file" --dry-run)" \
    || fail "dry run с логином без пароля упал: $out"
grep -q 'uat-user' <<<"$out" && fail "логин прокси попал в вывод: $out"
cat > "$PI_HOME/playwright-mcp.json" <<'EOF'
{
  "browser": {
    "contextOptions": {
      "viewport": null,
      "proxy": {
        "server": "http://127.0.0.1:10808",
        "bypass": "localhost,127.0.0.1"
      }
    }
  }
}
EOF

# --- what chromium.launch() actually receives (stub Playwright) -------------
launch_opts() {
    local out_file="$WORK/launch.json" rc=0
    : > "$out_file"
    STUB_OUT="$out_file" UAT_PLAYWRIGHT_ROOT="$WORK/fake-pw" \
        run bash "$UAT" login --env "$env_file" --profile local --url http://localhost/admin/login/sign-in "$@" \
        >/dev/null 2>&1 || rc=$?
    [[ -s "$out_file" ]] || fail "заглушка Playwright не получила launch (код $rc)"
    cat "$out_file"
}

opts="$(launch_opts)"
jq -e '.proxy.server == "http://127.0.0.1:10808"' <<<"$opts" >/dev/null \
    || fail "прокси не дошёл до chromium.launch: $opts"
jq -e '.proxy.bypass == "localhost,127.0.0.1"' <<<"$opts" >/dev/null \
    || fail "bypass не дошёл до chromium.launch: $opts"
jq -e '.headless == true' <<<"$opts" >/dev/null || fail "headless потерян: $opts"

opts="$(launch_opts --no-proxy)"
jq -e '.proxy == null' <<<"$opts" >/dev/null || fail "--no-proxy всё равно передал прокси: $opts"
jq -e '.args | index("--no-proxy-server")' <<<"$opts" >/dev/null \
    || fail "--no-proxy обязан ставить --no-proxy-server, иначе Chromium возьмёт прокси из окружения: $opts"

opts="$(launch_opts --proxy-server http://proxy.example:3128)"
jq -e '.proxy.server == "http://proxy.example:3128"' <<<"$opts" >/dev/null \
    || fail "--proxy-server не дошёл до chromium.launch: $opts"

# --- usage errors ----------------------------------------------------------
set +e
out="$(run bash "$UAT" login --url http://localhost/admin/login/sign-in --env "$WORK/absent.env" --dry-run)"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "отсутствующий .env обязан падать"
grep -q 'no credentials file' <<<"$out" || fail "сообщение про .env не напечатано: $out"

echo "OK: прокси из base config доходит до chromium.launch, --no-proxy ставит --no-proxy-server, хост 127.0.0.1 → localhost, --keep-host работает, userinfo замаскирован"

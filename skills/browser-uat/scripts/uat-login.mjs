#!/usr/bin/env node
// uat-login.mjs — server-side login for browser UAT (#15647).
//
// Why this exists: the browser tools take field values only as arguments, i.e.
// into the chat transcript, while test credentials must not go there. So the
// login is performed here, out of band: this script reads the values from the
// environment, drives the project's sign-in form, and saves a Playwright storage
// state file. The MCP server then starts with PLAYWRIGHT_MCP_STORAGE_STATE set
// to that file and the agent opens an already-authenticated session.
//
// Values are read from the environment, never from argv: argv is visible in
// `ps` for other users on the machine.
//
// Environment:
//   UAT_LOGIN_URL             sign-in page URL (required)
//   UAT_LOGIN_PHONE           phone value (required)
//   UAT_LOGIN_CODE            one-time code (required)
//   UAT_LOGIN_STATE           output storage state path (required)
//   UAT_LOGIN_PHONE_FIELD     selector, default [name="LoginForm[username]"]
//   UAT_LOGIN_CODE_FIELD      selector, default [name="LoginForm[code]"]
//   UAT_LOGIN_SEND_SELECTOR   button that requests the code (optional; the form
//                             may render the code field only after it is clicked)
//   UAT_LOGIN_SUBMIT_SELECTOR submit button, default button[type=submit]
//   UAT_LOGIN_SUCCESS         path only an authenticated session sees, default /admin.
//                             The login passes if the browser landed under it, or if a
//                             request to it with the new cookies is answered — a stand may
//                             send a logged-in session to "/" instead (#16027 п.2)
//   UAT_LOGIN_TIMEOUT         step timeout in ms, default 20000
//   UAT_LOGIN_PROXY_SERVER    proxy for the login browser (optional)
//   UAT_LOGIN_PROXY_BYPASS    proxy bypass list, comma-separated (optional)
//   UAT_LOGIN_NO_PROXY        1 — start the browser with --no-proxy-server, so the
//                             session's HTTP_PROXY is not used even for the loopback
//   UAT_PLAYWRIGHT_ROOT       directory containing the `playwright` package
//                             (default: `npm root -g`)
//
// Exit codes: 0 ok, 1 login failed, 2 usage/environment error.
// Nothing secret is printed: no phone, no code, no cookies.

import { execSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

const env = process.env;
const url = env.UAT_LOGIN_URL || '';
const phone = env.UAT_LOGIN_PHONE || '';
const code = env.UAT_LOGIN_CODE || '';
const statePath = env.UAT_LOGIN_STATE || '';
const phoneField = env.UAT_LOGIN_PHONE_FIELD || '[name="LoginForm[username]"]';
const codeField = env.UAT_LOGIN_CODE_FIELD || '[name="LoginForm[code]"]';
const sendSelector = env.UAT_LOGIN_SEND_SELECTOR || '';
const submitSelector = env.UAT_LOGIN_SUBMIT_SELECTOR || 'button[type=submit]';
const success = env.UAT_LOGIN_SUCCESS || '/admin';
// The MCP browser reaches the stand through the proxy in the base config, while this script
// starts a browser of its own — so the login can end up on a different route, which is what made
// page.goto time out in #15799 п.1. Passing the same proxy keeps one route; --no-proxy-server is
// the only way to guarantee a direct one, because otherwise Chromium may take a proxy from the
// system settings.
const proxyServer = env.UAT_LOGIN_PROXY_SERVER || '';
const proxyBypass = env.UAT_LOGIN_PROXY_BYPASS || '';
// Chromium has no "direct" switch of its own: --no-proxy-server is the only way to pin the
// direct route, so it is passed explicitly instead of relying on the environment.
const noProxy = env.UAT_LOGIN_NO_PROXY === '1';
const timeout = Number(env.UAT_LOGIN_TIMEOUT || 20000);

// "Under --success" is not enough on its own: with the default /admin the login
// page itself is /admin/login/index, so a rejected code would look like a
// successful login. The predicate therefore also excludes the login area.
function loggedIn(current) {
  const path = current.pathname;
  return path.startsWith(success) && !path.includes('/login');
}

// The landed URL alone says "login failed" about a working session: on the farm the browser ends up
// on "/" after a successful submit, not under /admin (#16027 п.2 — three cookies written and
// "вход не прошёл — страница /, ожидался путь /admin"). So when the URL does not land under
// --success, the app itself is asked: a request to --success with the cookies just obtained should
// be answered outside the login area. A guest is redirected there to the sign-in page (any path
// with /login), an authenticated session is not.
//
// `kind` keeps the outcomes apart, because "вход не прошёл" about a live session with no backend
// access, or about a probe that never reached the stand, sends the reader hunting the wrong thing:
//   session     — authenticated session, access to --success granted
//   guest       — redirected into the login area, or a 401: the login itself did not take
//   login-area  — --success itself points into the login area; no request is made
//   forbidden   — 403: session exists, but this user has no access to --success
//   broken      — 404/5xx: the path is wrong or the stand is sick, not the login
//   unchecked   — the probe did not reach the stand (network, proxy)
async function probeSuccess(context) {
  try {
    const probeUrl = new URL(success, url).toString();
    // The same asymmetry the URL predicate already rejects: /admin/login/index answers 200 to a
    // guest, so a --success pointing into the login area would "confirm" a failed login.
    if (/\/login/.test(new URL(probeUrl).pathname)) return { ok: false, kind: 'login-area' };
    const response = await context.request.get(probeUrl, {
      maxRedirects: 0,
      failOnStatusCode: false,
      timeout: Math.max(timeout, 15000),
    });
    const status = response.status();
    const location = response.headers().location || '';
    if (status === 401) return { ok: false, status, kind: 'guest' };
    if (status === 403) return { ok: false, status, kind: 'forbidden' };
    if (status >= 400) return { ok: false, status, kind: 'broken' };
    if (status < 200) return { ok: false, status, kind: 'broken' };
    if (/\/login/.test(location)) return { ok: false, status, kind: 'guest' };
    return { ok: true, status, kind: 'session' };
  } catch (error) {
    return { ok: false, status: 'ошибка запроса: ' + String(error).split('\n')[0], kind: 'unchecked' };
  }
}

function usage(message) {
  console.error(`uat-login: ${message}`);
  console.error('uat-login: нужны UAT_LOGIN_URL, UAT_LOGIN_PHONE, UAT_LOGIN_CODE, UAT_LOGIN_STATE');
  process.exit(2);
}

if (!url || !phone || !code || !statePath) usage('не заданы обязательные переменные окружения');

// A root --success degenerates both checks: startsWith('/') is always true, and the public "/"
// answers 200 to a guest too — so a rejected login would be written as a success and overwrite a
// working session in current.json (#16027 п.2).
if (success === '/') {
  console.error('uat-login: --success «/» не годится: и проверка по адресу, и проверка запросом вырождаются —');
  console.error('uat-login: публичный / отвечает 200 и гостю, поэтому отклонённый вход запишется как успешный.');
  console.error('uat-login: оставь дефолтный /admin — вход подтверждается запросом к нему с полученными cookie.');
  process.exit(2);
}

function loadPlaywright() {
  const root = env.UAT_PLAYWRIGHT_ROOT || '';
  const candidates = [];
  if (root) candidates.push(resolve(root, 'playwright'));
  try {
    candidates.push(execSync('npm root -g', { encoding: 'utf8' }).trim() + '/playwright');
  } catch {
    /* npm may be absent: fall through to the plain require below */
  }
  candidates.push('playwright');
  for (const candidate of candidates) {
    try {
      return require(candidate);
    } catch {
      /* try the next one */
    }
  }
  console.error('uat-login: пакет playwright не найден — поставь его (npm i -g playwright) или задай UAT_PLAYWRIGHT_ROOT');
  process.exit(2);
}

const { chromium } = loadPlaywright();

// The phone field is masked and expects the national number without the leading
// 7 (the mask adds +7 itself), so a value stored as "+7 (999) 123-45-67" or
// "79991234567" is normalised here. Digits only, last 10.
function normalisePhone(value) {
  const digits = value.replace(/\D+/g, '');
  return digits.length > 10 ? digits.slice(-10) : digits;
}

const stateFile = resolve(statePath);
const stateDir = dirname(stateFile);

let browser;
try {
  browser = await chromium.launch({
    headless: true,
    ...(noProxy ? { args: ['--no-proxy-server'] } : {}),
    ...(proxyServer && !noProxy
      ? { proxy: proxyBypass ? { server: proxyServer, bypass: proxyBypass } : { server: proxyServer } }
      : {}),
  });
} catch (error) {
  console.error('uat-login: не удалось запустить Chromium — поставь браузер: npx playwright install chromium');
  console.error('uat-login: ' + String(error).split('\n')[0]);
  process.exit(2);
}

try {
  const context = await browser.newContext({ viewport: { width: 1920, height: 1080 } });
  const page = await context.newPage();
  page.setDefaultTimeout(timeout);

  console.log('uat-login: открываю форму входа');
  await page.goto(url, { waitUntil: 'domcontentloaded' });

  console.log('uat-login: ввожу телефон');
  await page.fill(phoneField, normalisePhone(phone));

  if (sendSelector) {
    console.log('uat-login: запрашиваю код');
    await page.click(sendSelector);
    await page.waitForSelector(codeField, { state: 'visible' });
  }

  console.log('uat-login: ввожу код');
  await page.fill(codeField, code);

  console.log('uat-login: отправляю форму');
  // The URL under --success is the fast path and nothing more: when the browser lands elsewhere (the
  // farm ends on "/"), the outcome is decided by probeSuccess() below.
  await page.click(submitSelector);
  const landedUnderSuccess = await page
    .waitForURL(loggedIn, { timeout: Math.max(timeout, 30000) })
    .then(() => true)
    .catch(() => false);

  const state = await context.storageState();
  const cookies = state.cookies?.length ?? 0;
  const landed = new URL(page.url());
  // Fast path — the browser landed on an authenticated page. Otherwise the probe decides: it is
  // the stand, not the URL, that says whether the session is alive.
  const probe = landedUnderSuccess
    ? { ok: true, status: 'не понадобился' }
    : cookies > 0
      ? await probeSuccess(context)
      : { ok: false, status: 'нет cookie' };
  const confirmed = landedUnderSuccess || probe.ok;

  if (!confirmed || cookies === 0) {
    const title = await page.title().catch(() => '');
    if (cookies === 0) {
      // Nothing to probe with: the form did not leave a session behind, so no request is made at
      // all and saying otherwise would invent evidence.
      console.error(
        `uat-login: вход не прошёл — страница ${landed.pathname} («${title}»), cookie не записано; проверка запросом не выполнялась`
      );
      console.error('uat-login: проверь значения в .env, срок действия кода и селекторы формы');
    } else if (probe.kind === 'unchecked') {
      // The stand never answered the probe: this is not a verdict on the login, and calling it
      // "вход не прошёл" would send the reader to the form instead of the route.
      console.error(`uat-login: состояние не проверено — ${success}: ${probe.status}`);
      console.error('uat-login: файл состояния не записан. Проверь доступ к стенду и UAT_LOGIN_PROXY_SERVER,');
      console.error('uat-login: либо подтверди вход в браузере вручную — страница ' + landed.pathname);
    } else if (probe.kind === 'forbidden') {
      console.error(
        `uat-login: вход есть, но доступа к ${success} нет — ${probe.status} (сессия живая: cookie ${cookies})`
      );
      console.error(`uat-login: проверь права пользователя на ${success} или укажи другой --success`);
    } else if (probe.kind === 'broken') {
      console.error(
        `uat-login: ${success} ответил ${probe.status} — вход тут ни при чём, проверь путь --success и состояние стенда (cookie ${cookies})`
      );
    } else if (probe.kind === 'login-area') {
      console.error(
        `uat-login: --success ${success} указывает в область входа, проверка не выполнялась (cookie ${cookies})`
      );
      console.error('uat-login: укажи путь, доступный только авторизованной сессии');
    } else {
      console.error(
        `uat-login: вход не прошёл — страница ${landed.pathname} («${title}»), запрос ${success} ведёт в область входа (${probe.status}), cookie ${cookies}`
      );
      console.error('uat-login: проверь значения в .env, срок действия кода и селекторы формы');
    }
    process.exitCode = 1;
  } else {
    // Write-then-rename: a /reload in the middle of the write must not read half
    // a JSON file.
    const dirExisted = existsSync(stateDir);
    mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    // Only tighten a directory we created: chmod on someone else's (e.g. /tmp)
    // fails with EPERM and would fail a login that already succeeded.
    if (!dirExisted) chmodSync(stateDir, 0o700);
    const tmp = join(stateDir, `.${process.pid}.tmp`);
    writeFileSync(tmp, JSON.stringify(state, null, 2), { mode: 0o600 });
    chmodSync(tmp, 0o600);
    renameSync(tmp, stateFile);

    if (!landedUnderSuccess) {
      console.log(`uat-login: адрес после входа — ${landed.pathname}, вход подтверждён запросом ${success}`);
    }
    console.log(`uat-login: готово — вход выполнен, ${cookies} cookie сохранено в ${stateFile}`);
    console.log('uat-login: перезапусти MCP-сервер (/reload в pi), чтобы он подхватил состояние входа');
  }
  await context.close();
} catch (error) {
  console.error('uat-login: ' + String(error).split('\n')[0]);
  // The measured failure of #15799 п.1: a session proxy with no proxy on the browser times out on
  // the loopback. Name it instead of leaving a bare TimeoutError.
  if (!proxyServer && !noProxy && (env.HTTP_PROXY || env.HTTPS_PROXY || env.http_proxy || env.https_proxy)) {
    console.error(
      'uat-login: в окружении выставлен прокси, а браузер пошёл без него — задай прокси из'
        + ' playwright-mcp.json (uat.sh login берёт его сам) или UAT_LOGIN_PROXY_SERVER'
    );
  }
  process.exitCode = 1;
} finally {
  // close() runs even on the error path: a bare process.exit() here would leave
  // a Chromium child behind.
  await browser.close();
}

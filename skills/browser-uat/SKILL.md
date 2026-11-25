---
name: browser-uat
description: "Drive a real browser through the Playwright MCP server (`mcp__playwright__*`) to do user acceptance testing, reproduce UI bugs, or verify a web app end to end. Use whenever the user says UAT, smoke test the UI, click through the app, check the page in a browser, take a screenshot of the running app, verify a form/login/flow works, or asks whether something looks or behaves right in a real browser. Also use before declaring a UI change verified."
---

# Browser UAT (Playwright MCP)

Interactive browser work driven by the `playwright` MCP server. This is UAT and
debugging, not test authoring: for CI-style Playwright specs, write a test file
instead.

The browser runs on a **private Xvfb display**, so it never appears on the
user's desktop and never steals window focus. Screenshots are the only way to
see it. Environment management lives in a script; do not hand-edit MCP config or
launch Xvfb yourself.

## Start here

```bash
~/.pi/agent/skills/browser-uat/scripts/uat.sh doctor
```

`doctor` checks npx, a browser, Xvfb, the MCP entry, and the artifact directory,
and prints the exact fix for anything missing. Run it once per session before
blaming a tool call. `uat.sh help` lists the other subcommands.

If `mcp__playwright__*` tools are absent, the server is not connected: run
`mcp({ connect: "playwright" })` first — it starts the server and refreshes the
tool list without the user. `pi mcp list` shows the configured servers, and
`/reload` (a new session works too) is the manual fallback when the gateway
cannot connect.

## Logging in (server-side)

The browser tools take field values only as arguments — that is, into the
conversation. Test credentials must not go there, so the login is done out of
band, by a script, and the agent only opens the already-authenticated session:

```bash
~/.pi/agent/skills/browser-uat/scripts/uat.sh login \
  --url http://localhost/admin/login/sign-in \
  --env ~/work/project/.env \
  --send-selector .js_send_code \
  --profile my-project
```

What it does: reads the phone and the one-time code from the project `.env`
(variables `ADMIN_PHONE_NUMBER` / `ADMIN_PHONE_CODE` by default, override with
`--phone-var` / `--code-var`), fills the sign-in form in a headless Chromium, and
writes the browser state to `~/.pi/agent/uat-auth/<profile>.json` (mode 600) and
points `~/.pi/agent/uat-auth/current.json` at it — that is the file the server
loads, so any `--profile` works without extra environment. The directory lives
outside `skills/` on purpose: a restore wipes `skills/` and a sync copies that
tree into the repo checkout. The values travel through the environment, never
argv — argv is visible in `ps`.

How the login is judged: `--success` (default `/admin`) is a path only an
authenticated session sees, but the address after the submit is **not** required to
land there. On the farm a successful login ends on `/`, not on `/admin` (a guest is
redirected from `/admin` to `/admin/login/index`), and judging by the URL alone printed
«вход не прошёл — страница /, ожидался путь /admin» about a live session with three
cookies (#16027 п.2). So when the browser does not land under `--success`, the script
asks the app itself: a request to `--success` with the cookies just obtained must be
answered outside the login area — a guest is redirected to a sign-in path containing
`/login`, an authenticated session is not.

The state file is written only after that check passes, and the failures are named
differently on purpose, because «вход не прошёл» about a live session sends the reader
to the form instead of the real cause: `guest` (login did not take — redirected into
`/login`, or 401), `forbidden` (403 — the session is live, this user just has no access
to `--success`), `broken` (404/5xx — wrong path or sick stand), `unchecked` (the probe
never reached the stand — network or proxy, with `UAT_LOGIN_PROXY_SERVER` as the hint),
and «cookie не записано» when the form left no session at all (then no probe is made).

`--success /` is refused with exit 2: `startsWith('/')` is always true and the public
root answers 200 to a guest, so a rejected login would be written as a success and
overwrite a working session in `current.json`. A `--success` that points into the login
area (`/admin/login/index` answers 200 to a guest too) is never confirmed by the probe.

Assumption worth knowing: the probe accepts any 2xx/3xx answered outside `/login` as
proof of a session. That holds where a guest is redirected to a path containing `/login`
(msb-lk: `/admin` → `/admin/login/index`, cabinet → `/site/login`); a stand that sends a
guest elsewhere, or an SPA route that answers 200 to anyone, would confirm a guest — pick
`--success` accordingly.

After that the MCP server picks the state up on its next start: the Xvfb wrapper
exports `PLAYWRIGHT_MCP_STORAGE_STATE` when the file exists, and `--isolated`
still keeps the profile in memory. So the server has to be (re)started once
after the login — and the agent can do that itself, without asking the user:

```
mcp({ connect: "playwright" })
```

The MCP gateway starts the server again, it reads
`~/.pi/agent/uat-auth/current.json` on start, and the next `browser_navigate`
lands on an authenticated page. `/reload` in pi does the same thing by hand and
remains the fallback for a session where the gateway is not available or the
tool list itself is missing (see “Start here”); it needs the user, so it is not
the default answer. `--profile` picks the file, `UAT_STORAGE_STATE` points the
server at another one; `--dry-run` checks the paths without starting a browser.
The login runs Playwright's own Chromium, not the system Chrome that
`uat.sh doctor` looks for — if it is missing, the script says so and
`npx playwright install chromium` fixes it.

Project-specific details (form selectors, where the dev one-time code comes
from) belong to the project skill — this section owns only the mechanism.

## Workflow

1. **Write the QA inventory before touching the browser.** From the user's
   request, the implemented changes, and the claims you intend to make, list
   every user-visible control and the state change it should cause. Add at least
   two off-happy-path scenarios (empty input, wrong credentials, back button,
   double submit). This list is what you sign off against — not "I clicked
   around". `uat.sh report` prints a matching template.
2. **Navigate**, then **snapshot**. `browser_snapshot` gives the accessibility
   tree with element refs; it is the source of truth for acting. Screenshots are
   for humans and visual checks, never for locating elements.
3. **Act** with `browser_click` / `browser_type` / `browser_fill_form` /
   `browser_select_option` / `browser_press_key`, using refs from the latest
   snapshot. Snapshot again after anything that changes the DOM — stale refs
   fail.
4. **Verify each inventory item** against observable state: URL, visible text,
   network response (`browser_network_requests`), console errors
   (`browser_console_messages`, level `error`). A silent console error fails a
   check even if the UI looks right.
5. **Capture evidence** with `browser_take_screenshot` for anything visual or
   subjective.
6. **Close** with `browser_close` when finished, and report pass/fail per
   inventory item with the evidence.

## Tool map

| Intent | Tool |
| --- | --- |
| Open a URL | `browser_navigate`, `browser_navigate_back` |
| Read the page | `browser_snapshot` (act from this), `browser_find` (text/URL search) |
| Interact | `browser_click`, `browser_type`, `browser_fill_form`, `browser_select_option`, `browser_hover`, `browser_drag`, `browser_press_key`, `browser_drop` |
| Wait for state | `browser_wait_for` (text, selector, or network idle) |
| Inspect behavior | `browser_console_messages`, `browser_network_requests`, `browser_network_request` |
| Assert programmatically | `browser_evaluate` |
| Visual evidence | `browser_take_screenshot` |
| Dialogs / uploads | `browser_handle_dialog`, `browser_file_upload` |
| Viewport / device | `browser_resize`, `browser_emulate_media` |
| Tabs | `browser_tabs` |
| Escape hatch | `browser_run_code_unsafe` (raw Playwright; use sparingly) |

## Canonical call forms

The field names are not the ones you would guess: a wrong name is a validation
error, not a warning, and three calls were burned in one UAT on `ref` vs `target`
and `query` vs `text` (#15611 п.9). Copy these shapes.

| Call | Required fields | Optional |
| --- | --- | --- |
| `browser_click` | `target` (ref from the latest snapshot, or a unique selector) | `element`, `button`, `doubleClick`, `modifiers` |
| `browser_type` | `target`, `text` | `element`, `submit`, `slowly` |
| `browser_find` | `text` **or** `regex` (never both) | `maxResults`, `filename` |
| `browser_take_screenshot` | `scale` (`"css"` or `"device"`) | `target`, `element`, `type`, `filename`, `fullPage` |
| `browser_evaluate` | `function` | `target`, `element`, `filename` |
| `browser_wait_for` | — (all optional) | `text`, `textGone`, `time` |
| `browser_navigate` | `url` | — |
| `browser_resize` | `width`, `height` | — |
| `browser_press_key` | `key` | — |
| `browser_select_option` | `target`, `values` | `element` |
| `browser_console_messages` | `level` | `all`, `filename` |
| `browser_network_requests` | `static` | `filter`, `all`, `filename` |

There is no `ref`, no `query`, no `selector` field: the element handle is always
`target`, and page search is always `text`/`regex`. `element` is only the
human-readable label used in the permission prompt. When a call is rejected for
an unknown field, run `describeTool`/`mcp describe` on that tool instead of
retrying with another guess.

## Reading values with `browser_evaluate`

Return the projection, not the page. An `innerText`/`textContent` of a container
took a 305 KB answer (truncated by the response limit) in a single UAT, and the
number it was after was still read from the database afterwards (#15970).

```js
// Only the fields the check needs — one object per row, never the container text.
() => [...document.querySelectorAll('[data-param-id]')]
  .map(el => ({ id: el.dataset.paramId, text: el.textContent.trim() }))
```

```js
// A single value: selector from the project skill, plus a stable id in the answer.
() => {
  const el = document.querySelector('[data-param-id="1501"]');
  return { id: '1501', text: el ? el.textContent.trim() : null };
}
```

Rules that follow:

- **A number has one source of truth, and it is rarely the DOM.** If the project
  has a query or a parity tool for it, read the number there; `browser_evaluate`
  confirms what the form *shows*, it does not produce report values.
- **Never return `innerText` / `innerHTML` of a container** to "look at the block":
  the answer is unbounded and gets truncated, so the fact you needed may be the
  part that was cut.
- **`$$`-style sweeps over `button, a, input` return hundreds of nodes.** Project
  to `{id, text}` and cap the list, or select by text/`data-*` instead.

## Project reporting contracts

This skill owns *mechanics*: launching, interacting, waiting, capturing, rescuing a
hung step. A project skill owns its *reporting contract*: which screenshots a
report needs, what they must be named, where they are published.

When a project skill demands specific evidence file names (for example attaching
screenshots to a tracker under `<ID>-NN-<case>-<slug>.png`):

1. Take the screenshot **without** `filename` — it lands in `$TMPDIR/browser-uat`
   with an absolute path in the tool result.
2. Copy it to the project's evidence directory under the required name.
3. Publish from there.

Never satisfy a naming requirement by writing `filename` into the repository.
Evidence is a build artifact, not source.

If a project skill restates mechanics from this one (launch, screenshot method,
waiting strategy), the restatement is stale by construction — follow this skill
and report the duplication.

## Gotchas

- **`browser_take_screenshot` fails without `scale`**, even though its schema
  annotation claims a `css` default — see *Canonical call forms*.
- **Omit `filename` on screenshots.** Auto-named files land in the artifact
  directory (`$TMPDIR/browser-uat`, absolute paths in the tool result). An
  explicit filename resolves against the session cwd and litters the repo.
- **The display is 1920×1080**, so full-page screenshots are wide. Call
  `browser_resize(1280, 800)` **before a series of screenshots**, not only when
  iterating: a screenshot is returned as an attachment in context, so frame size
  is the price of the session, not cosmetics. Measured in #16048: screenshots at
  the default viewport weigh 246–335 KB against ~120 KB at 1280×800 with the same
  information, and 17 screenshot calls produced 1.9 MB of the session's 2.3 MB
  output (#16076). Interface labels stay readable at 1280×800; take element
  screenshots when they do not.
- **`--isolated` means no persisted profile, not "no login".** Every server
  restart starts with a fresh in-memory profile, and the saved storage state from
  `uat.sh login` is loaded into it — so the session survives a restart without
  typing credentials into the chat. Without a saved state the browser starts
  logged out; do not log in "as part of the flow" with `browser_type` (the values
  would land in the conversation) — run `uat.sh login` first.
- **The browser self-closes after 15 minutes idle.** The next tool call relaunches
  it, which loses tabs and session state — re-navigate rather than assuming the
  page is still there.
- **`hasFocus`/`visibilityState` are real signals** in `browser_evaluate`; use
  them before blaming the app for a lazy-load or autoplay problem.
- **Snapshots go stale** after navigation, form submit, or modal open. Re-snapshot
  rather than retrying a click on a dead ref.
- **Nothing is visible on the user's screen.** If the user asks to watch, they
  need a screenshot; there is no window to look at.
- **`file:` URLs are blocked** — `browser_navigate` to `file:///…` fails with
  «Access to "file:" protocol is blocked». Serve the directory instead:
  `python3 -m http.server 8765` in the document's folder, open
  `http://127.0.0.1:8765/<page>.html`, and kill the server when the check is done.

## Do not

- Do not use `browser_run_code_unsafe` to bypass a failing interaction — fix the
  locator or the wait instead.
- Do not declare UAT passed without running the inventory; a single happy-path
  click is not a test.
- Do not hand-edit the playwright entry to change the display or launch it by
  hand — use `uat.sh config install` for the entry and `uat.sh display start` for
  a manual display; never run Xvfb directly.
- Do not leave the browser open across unrelated tasks, and do not leave
  artifacts in a repo.
- Do not restate this skill's mechanics inside a project skill — point to it
  instead. Two owners for one procedure means the copy that gets read is the one
  that rotted.

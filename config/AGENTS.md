# Delegation model policy

Pi knows more model ids than this machine can reach. A listing from `pstack_adapter models`,
`subagent({ action: "list" })`, or any catalog is **not** proof that the provider serves a model.
An OpenRouter workspace guardrail ("model cap") serves exactly 14 model ids, and a fan-out that
picks anything else loses the run with `404 ... 0 endpoints out of 14 ... guardrail restrictions`.

## Allowed

**Before delegating or starting a pstack workflow, read `~/.pi/agent/docs/delegation-models.md`:**
the 14 allowed ids, their prices, the cache-read ranking and the provider-routing note. Only ids
from that table are policy — a model in the local catalog is not evidence the cap serves it.

## Blocked

- Everything else, including `deepseek/deepseek-v4-pro` and `-pro-0813`. The pro tier sits outside
  the cap: it returns 404 from the guardrail, not from the model. This is what broke the project
  reviewer once already.
- `google/*`, any `gemini-*` id; `openai/*`, any `gpt-*`, `o3`, `o4` id; `anthropic/*`.
- Every `routerai/...` id, including the ones whose name matches an allowed id. The cap covers
  OpenRouter only, so routerai models are outside the policy even when they answer.

Never delegate to a blocked model, never retry one after it fails, and never offer one as an
option. Anything outside the table needs the user's explicit approval first.

## Enforcement

One hard gate, in user config; do not weaken it without the user asking.

- `~/.pi/agent/settings.json` — `subagents.modelScope` is `enforce: true, strict: true` with the 14
  ids as the allow list, so any launch naming a model outside the cap is rejected before the child
  starts, whoever started it (pstack skill, workflow, or a bare `subagent` call). The repo example
  ships the same list with `strict: false`, so a machine whose cap differs still launches instead of
  refusing every call.
- `subagents.defaultModel` is `openrouter/z-ai/glm-5.3-flash` and every bundled agent has an
  explicit `agentOverrides.<name>.model`, so a call that names no model lands on a capped model
  instead of the parent's. `inherit` passes only while the parent session model is itself inside
  the cap, which is the intended behaviour, not an exemption.
- `reviewer`, `oracle`, and `evidence-auditor` all default to `deepseek-v4.1-flash-1017` at
  thinking `medium`, and additionally carry a per-agent allow list of `glm-5.3-flash`,
  `deepseek-v4.1-flash-1017`, and `glm-5.3`, so a review cannot escalate to `glm-5.2`; naming
  `glm-5.3` explicitly is still allowed for a review that has to be argued at full strength.
- `~/.pi/agent/pi-pstack-adapter.json` pins every pstack role and panel to a capped model (see the
  `Model roles` table of `pstack_adapter status`). `glm-5.3` is assigned only to `judgment`,
  `strongest-judgment`, and one seat of `arena-cross-judge-pool`; every runner, reviewer, and
  `hillclimb` role runs `glm-5.3-flash`. The file carries no `modelFilter`: that filter also
  blocked every delegation that named no model, which broke `code-review` and any skill that lets
  a child inherit, so it was removed on purpose. `modelScope` is the gate.
- The table in `~/.pi/agent/docs/delegation-models.md` is a dated observation, not a standing
  fact. Re-verify it with `pi-models-check` (one `max_tokens: 1` request per id, exit 1 on 404)
  before trusting it after a provider or guardrail change. A 404 there is the cap, not local config.

## Rules

- Never pass a Cursor model slug: `claude-opus-5-5-xhigh`, `grok-4.7-xhigh-fast`, `composer-*`,
  `cursor-grok-*`. They do not exist in this installation. Upstream pstack bodies named them; the
  local `patches/pi-pstack-models.sh` rewrites them to role references.
- In pstack skills, pass `pstack:<role>` and let the adapter resolve the model and thinking. Never
  pass a panel role (`arena-runners`, `arena-cross-judge-pool`, `architect-runners`,
  `interrogate-reviewers`) as a model; expand the panel into its seats.
- An ad-hoc fan-out that wants model diversity picks from the allowed list only. Do not reach into
  a provider catalog for a "different family". The families available here are `glm`, `deepseek`,
  `minimax`, and `ling`.
- **One expensive seat per workflow, and it sits at the decision, not in the fan-out.** A panel
  spends money per seat per run; the judge spends it once. Keep `glm-5.3` on the judge and run the
  seats on `glm-5.3-flash` plus a second family. Adding a third runner seat to "keep diversity"
  raises the bill — it never lowers it.
- **A one-off fan-out can cost more than a week of normal work.** On 2026-11-13, 76 calls to
  `claude-opus-5` / `claude-sonnet-5` / `gpt-5.6-sol` inside 16 minutes were $6.08 — 27% of the
  week's $22.73, at $0.05-0.16 per call. Those ids are blocked now; the replacement for such a
  comparison is `glm-5.3` + `minimax-m3`, not a search for a stronger family.
- A model that answers `curl` may still be outside the cap; only the table in
  `~/.pi/agent/docs/delegation-models.md` is policy.
- When a delegation fails on its model, report the failure and name the model or role. Do not
  silently substitute another model.

# GitHub: авторство артефактов

`GITHUB_TOKEN` в окружении — ключ разработчика для composer, не личная учётная запись. `gh` на
этой машине обёрнут: `~/.local/bin/gh` (в `PATH` раньше `/usr/bin/gh`) снимает переменную и
работает от `denis-trofimov`, поэтому обычный `gh …` безопасен. Служебный аккаунт — только
осознанно: `GH_AS_DEV=1 gh …`. Обёртка обойдена (`/usr/bin/gh`, чужой PATH) — снимать явно:
`env -u GITHUB_TOKEN gh …`.

- Авторство не угадывается: не ясно, от чьего имени публикуется артефакт, — спросить. Дефолт —
  `denis-trofimov`.
- `gh pr` / `gh issue` / `gh api` — только с явным репозиторием: `cd` в него или `-R owner/repo`,
  иначе `gh` молча работает с тем репозиторием, где оказался `cwd`.
- `author` / `mergedBy` / `mergedAt` подтверждают учётную запись, а не человека: кто именно
  смержил — из истории сессии. Автор PR не меняется: ошибочный PR закрыть с пояснением и
  пересоздать от личной учётки (ветка и коммиты те же).
- Перед публикацией — `gh auth status` → `denis-trofimov`; токены не печатать в чат, логи и файлы.

# Прокси и внутренние хосты

В сессии выставлены `HTTP_PROXY`/`HTTPS_PROXY` (xray, `127.0.0.1:10808`), а внутренние хосты
(`*.msb-leasing.ru`, `192.168.*`, `10.*`, `msb-stream-*`) должны идти напрямую. Сначала — прямой
вызов; упал с TLS/таймаутом — `msb-net <команда>` (снимает прокси и ставит `NO_PROXY`).
`export NO_PROXY=… && unset HTTP_PROXY …` руками перед каждым вызовом не повторять.

# Мерж и релиз

Репозитории с `.github/workflows/release-please.yml` (`msb-calculator-api`) — перед мержем PR
скилл `release-please`: один мерж — один релиз.

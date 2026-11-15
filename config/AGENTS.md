# Delegation model policy

Pi knows more model ids than this machine can reach. A listing from `pstack_adapter models`,
`subagent({ action: "list" })`, or any catalog is **not** proof that the provider serves a model.
An OpenRouter workspace guardrail ("model cap") serves exactly 14 model ids, and a fan-out that
picks anything else loses the run with `404 ... 0 endpoints out of 14 ... guardrail restrictions`.

## Allowed

Only these ids, all on `openrouter/`. Verified live on 2026-11-15; the cap is provider-side, so a
model in the local catalog is not evidence it works.

| id | in / out $ per Mtok | role |
| --- | --- | --- |
| `deepseek/deepseek-v4.1-flash-1017` | 0.006 / 0.50 | bulk code, cross-check reviewer |
| `deepseek/deepseek-v4.1-flash` | 0.006 / 0.50 | same model, unversioned |
| `deepseek/deepseek-v4-flash-vision-exp` | 0.216 / 0.647 | vision experiments |
| `z-ai/glm-5.3` | 0.070 / 1.40 | judgment, strongest-judgment, primary reviewer |
| `z-ai/glm-5.3-flash` | 0.029 / 0.092 | default bulk model for every subagent |
| `z-ai/glm-5.2` | 0.006 / 6.80 | allowed, but the most expensive output in the cap |
| `z-ai/glm-5.1` | 0.899 / 2.82 | allowed, not assigned |
| `z-ai/glm-5` | 0.60 / 1.92 | allowed, not assigned |
| `z-ai/glm-4.7-flash` | 0.061 / 0.40 | allowed, not assigned |
| `minimax/minimax-m3` | 0.23 / 0.96 | third family for arena cross-judging |
| `minimax/minimax-m3.1-flash` | 0.05 / 0.20 | allowed, not assigned |
| `inclusionai/ling-3.1-flash` | 0.075 / 0.225 | allowed, not assigned |
| `inclusionai/ling-3.0-flash` | 0.021 / 0.063 | allowed, not assigned |
| `inclusionai/ling-3.0-flash-vl` | 0.06 / 0.18 | vision fallback |

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
  starts, whoever started it (pstack skill, workflow, or a bare `subagent` call).
- `subagents.defaultModel` is `openrouter/z-ai/glm-5.3-flash` and every bundled agent has an
  explicit `agentOverrides.<name>.model`, so a call that names no model lands on a capped model
  instead of the parent's. `inherit` passes only while the parent session model is itself inside
  the cap, which is the intended behaviour, not an exemption.
- `reviewer`, `oracle`, and `evidence-auditor` additionally carry a per-agent allow list capped at
  `glm-5.3` and `deepseek-v4.1-flash-1017`, so a review cannot escalate to `glm-5.2`.
- `~/.pi/agent/pi-pstack-adapter.json` pins every pstack role and panel to a capped model (see the
  `Model roles` table of `pstack_adapter status`). It carries no `modelFilter`: that filter also
  blocked every delegation that named no model, which broke `code-review` and any skill that lets
  a child inherit, so it was removed on purpose. `modelScope` is the gate.
- The table above is a dated observation, not a standing fact. Re-verify it with `pi-models-check`
  (one `max_tokens: 1` request per id, exit 1 on 404) before trusting it after a provider or
  guardrail change. A 404 there is the cap, not local config.

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
- A model that answers `curl` may still be outside the cap; only the table above is policy.
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

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
  the cap, which is the intended behaviour, not an exemption. For `reviewer` the override is
  `deepseek-v4.1-flash-1017`, and it is the only deepseek variant its allow list accepts: naming
  `openrouter/deepseek/deepseek-v4.1-flash` (no `-1017`) passes the cap and fails the gate.
- `reviewer`, `oracle`, and `evidence-auditor` all default to `deepseek-v4.1-flash-1017`, and
  additionally carry a per-agent allow list, so a review cannot escalate to `glm-5.2`. Thinking:
  `reviewer` and `oracle` at `high`, `evidence-auditor` at `off` (matching a claim against a fetched
  excerpt is lookup, not dialogue, and `off` is a level deepseek-1017 actually has). `reviewer` may
  name only `glm-5.3-flash` and `deepseek-v4.1-flash-1017`: no full-strength escalation on a review
  seat. `oracle` and `evidence-auditor` also allow `glm-5.3` for a review that has to be argued at
  full strength.
- **`medium` does not exist on most allowed models, and Pi clamps it UP first, never down.**
  `deepseek-v4.1-flash-1017` and `deepseek-v4-flash-vision-exp` expose `off/low/high/max`;
  `glm-5.3` and `glm-5.3-flash` expose only `low/high/max` (no `off` — there the floor is 2048
  tokens, not zero); `z-ai/glm-5.2` exposes only `off/high/xhigh`, so even `low` becomes `high`.
  `clampThinkingLevel` (pi-ai `dist/models.js`) scans upward from the requested level and falls back
  down only when nothing above it exists, so a `medium` override on those ids silently buys the
  16384-token `high` budget instead of 8192, and nothing surfaces it. Levels per seat must be levels
  the model actually has: `medium` is real only on `minimax-m3`, `minimax-m3.1-flash`, `ling-3.*`,
  `glm-4.7-flash`, `glm-5`, and `glm-5.1`. For the six ids with no `thinkingLevelMap` the catalog
  proves only that nothing clamps: Pi forwards the raw level unchecked. An `off` pin holds only
  while the seat stays on a model that maps it — `evidence-auditor` may also name `glm-5.3-flash`,
  where `off` becomes `low`. Verify by running the configured pairs through `clampThinkingLevel`,
  not by reading the number you wrote.
- `~/.pi/agent/pi-pstack-adapter.json` pins every pstack role and panel to a capped model (see the
  `Model roles` table of `pstack_adapter status`). `glm-5.3` is assigned only to `judgment`,
  `strongest-judgment`, and one seat of `arena-cross-judge-pool`; the six runner roles (`feature`,
  `refactoring`, `bug-fix`, `perf-issue`, `hillclimb`, `general`) run `glm-5.3-flash` at thinking
  `low`, while the panel runner seats (`arena-runners`, `architect-runners`,
  `interrogate-reviewers`) keep `high` because a panel is a comparison, not a pass.
  `strongest-judgment` asks `xhigh`, which `glm-5.3` cannot serve, so it clamps up to `max`: that
  one is deliberate and is the only clamp the config keeps. The file carries no `modelFilter`: that
  filter also blocked every delegation that named no model, which broke `code-review` and any skill
  that lets a child inherit, so it was removed on purpose. `modelScope` is the gate.
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

# Глобальные скиллы и агенты: источник — pi-setup

Глобальные скиллы, агенты и этот файл версионируются в `~/p/pi-setup` (`skills/`, `config/AGENTS.md`,
`extensions/`, `themes/`), доставка — PR в `denis-trofimov/pi-setup` (`main` защищён, мерж только
через PR). `~/.pi/agent` — рабочая копия: `./sync.sh` снимает её изменения в репозиторий,
`./install.sh --restore` раскладывает репозиторий обратно. Правка, сделанная только в `~/.pi/agent`,
на другой машине не появится, пока не попадёт в pi-setup.

**Правку pi-setup делают в отдельном воркдереве.** `~/p/pi-setup` — общий чекаут: ветку в нём не
переключают, потому что вторая сессия переключит её под работающей первой. Работа — воркдерево от
`origin/main`, `main` защищён и мержится только через PR:

```bash
cd ~/p/pi-setup && git fetch -q origin
git worktree add -q ../pi-setup-wt/<задача>-<слаг> -b <тип>/<задача>-<слаг> origin/main
```

Ветка — от `origin/main`, а не от текущей в общем чекауте: иначе в PR уезжает чужой коммит, если
общий чекаут стоял на чужой ветке (#15742 п.2). После мержа воркдерево убирают
(`git worktree remove ../pi-setup-wt/<имя>`), общий чекаут остаётся там, где стоял.

Воркдерево, ветку которого уже влили в базу, от живого по `git worktree list` не отличить.
`--restore` такие называет сам (`note: воркдерево … — можно убрать`); вручную —
`git merge-base --is-ancestor <tip> origin/main` для обычного слияния и `git cherry -v origin/main
<ветка>` для squash: у второго предка нет, и без `-` в первой колонке («изменение уже в базе»)
дерево выглядит не влитым.

`./install.sh --restore` из воркдерева раскладывает на живую машину контент ветки (скиллы, агенты,
расширения); симлинки `~/.local/bin/*` при этом ведут в основное дерево, а не в воркдерево
(`bin_link_root()`). Осознанный просмотр ветки на живой машине — так и задумано; после него вернуть
состояние: `./install.sh --restore` из `~/p/pi-setup`.

Файлы политики restore обрабатывает по-разному: `docs/delegation-models.md` и `docs/session-logs.md`
перезаписываются всегда (устаревшая таблица моделей теряет запуски делегирования), а `AGENTS.md`
остаётся живой копии — она несёт собственные правки машины. Пропуск виден строкой `AGENTS.md differs
from the repo copy … leaving it` и повторяется в конце прогона блоком «Не восстановлено из
репозитория»; сам код возврата о содержимом `AGENTS.md` не говорит ничего. Забирает правку
`--copy-config`, он же перезаписывает dotfiles из `home/` и словарь ru-spellcheck, поэтому когда
разошёлся только `AGENTS.md` — дешевле его `diff` с `config/` и копия одного файла.

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
- **Тело PR — через `gh api`, а не `gh pr edit`.** На этом сервере `gh pr edit <n> --body-file …` падает на
  `GraphQL: Projects (classic) is being deprecated in favor of the new Projects experience` с кодом 1, и
  тело не меняется; повторная разведка того же обхода стоила двух лишних вызовов (#15834 п.4). Рабочий
  путь — REST:

  ```bash
  python3 -c 'import json,sys; print(json.dumps({"body": open(sys.argv[1]).read()}))' body.md > /tmp/body.json
  gh api -X PATCH repos/<owner>/<repo>/pulls/<n> --input /tmp/body.json
  ```

  `--add-label` / `--remove-label` в `gh pr edit` работают — падает именно правка тела.
- Перед публикацией — `gh auth status` → `denis-trofimov`; токены не печатать в чат, логи и файлы.

# Прокси и внутренние хосты

В сессии выставлены `HTTP_PROXY`/`HTTPS_PROXY` (xray, `127.0.0.1:10808`), а внутренние хосты
(`*.msb-leasing.ru`, `192.168.*`, `10.*`, `msb-stream-*`) должны идти напрямую. Сначала — прямой
вызов; упал с TLS/таймаутом — `msb-net <команда>` (снимает прокси и ставит `NO_PROXY`).
`export NO_PROXY=… && unset HTTP_PROXY …` руками перед каждым вызовом не повторять.

# Логи сессий

Вопросы «какая сессия взяла задачу», «что она успела» и «сколько это стоило» отвечаются готовыми
однострочниками из `~/.pi/agent/docs/session-logs.md`. Не писать под каждый из них новый скрипт: в ретро
по #15716 четыре python-скрипта писались заново, и соседние ретро (#15742, #15749) повторяли те же.

# Исходник пакета: `vendor`, а не соседний чекаут

Код, который **реально считается**, у PHP-пакета — установленный `vendor/<vendor>/<пакет>/` в
репозитории-потребителе, либо `git show <тег>:<путь>` (тег — из `vendor/composer/installed.json`).
Соседний чекаут пакета — рабочая копия, часто чужая задача на своей ветке: 19.11.2026 чекаут
`msb-calculator-api` стоял на `fix/15676-insurance-year-reset`, на 17 коммитов позади `origin/main`, и
поиск по нему дал вывод «правило окна в пакете не реализовано вовсе» — при том что в `vendor`
`isFullReleaseWindow()` есть (#15830 п.1).

- читаешь `src/` чекаута как «текущий код» — сначала `git -C <чекаут> status -sb` и `git log --oneline -1`:
  ветка не та — правда всё равно в `vendor`;
- чекаут годится как «что будет в следующем релизе», и только на актуальном `origin/main`;
- разница между чекаутом и `vendor` видна по `composer.lock` и `installed.json`, а не по номеру
  версии в `composer.json` чекаута.

# Русский текст: проверка перед публикацией

Русская проза у flash-тиров сыпется двумя классами ошибок: латинские гомоглифы внутри
кириллицы (`лоkalной`, `восстанóвленное`, `обéих`, `преflight`) и редукция гласных (`нузен`,
`открито`, `которий`, `напровление`). Модель этого не замечает, поэтому перед публикацией
русского текста (заметка в Redmine, ТК/ОР, отчёт UAT, TL;DR в чат) — детерминированная вычитка:

- короткий текст (заметка, сообщение, тело коммита — примерно до 40 строк):
  `ru-spellcheck --homoglyph-only файл.md` (или `… | ru-spellcheck --homoglyph-only -`) — гейт,
  ноль ложных срабатываний, exit 1 при находке;
- длинный текст (документ передачи, README, описание задачи): полный `ru-spellcheck файл.md` — словарь
  `ru_RU` плюс личный и проектный, находки разбирать руками. Гейт на длинном входе сам выходит с кодом
  3 и просит полный прогон: редукция гласных (`сесии`, `велечину`, `скрыпт`) без словаря не видна, и
  зелёный `--homoglyph-only` на 57-строчном документе с 55 ошибками — это не «чисто», а «не смотрели»
  (#15799 п.2). `--allow-long` — осознанный обход, а не привычка;
- полный прогон шумит на проектном жаргоне и на пробелах словаря (множественное число твёрдых основ:
  `сервисы`, `сервисам`); жаргон узаконивается в `.ru-spellcheck-allow`, пробелы словаря — нет;
- находки править в тексте, а не пересказывать моделью: повторный прогон той же модели даёт те же
  ошибки. Новое узаконенное слово — `ru-spellcheck --add СЛОВО` (стем-совпадение, `скилл`
  покрывает `скиллов/скиллу`). Из репозитория `--add` пишет в его собственный словарь
  `.ru-spellcheck-allow` в корне — тот едет в коммит вместе с правкой и работает у всех агентов и в
  CI; личный `~/.config/ru-spellcheck/allow.txt` — только `--add-personal`. Словарь проекта читается
  поверх личного, искать его больше нигде не нужно: инструмент сам идёт от проверяемого файла вверх
  до корня репозитория (#15717 п.4).
- **Deny-список — не твой.** `~/.config/ru-spellcheck/deny.txt` (и проектный `.ru-spellcheck-deny`)
  называет лексику, которую агент придумал и не должен узаконивать: `воркtree`, `инлайн`, `харнесс`,
  `резолв`. Слово оттуда — находка **всегда**, даже если оно написано верно, лежит в allow или в
  baseline, и `--add` на нём отказывает: правят текст, а не список. Файл принадлежит человеку, и
  `path-guard` не даёт агенту его записать (`PI_PATH_GUARD_ALLOW_DENY_LIST=1` — осознанный обход), а
  коммит с этой правкой в самом pi-setup блокирует prek-хук `deny-list-guard` (`SKIP=deny-list-guard` —
  осознанный обход, причина — в сообщении коммита): `path-guard` видит только `write`/`edit`, а `bash`
  его не пересекает.
  Правило пришло из #15820: `ассерты`, `апрувы` и `резолвы` попадали в allow как «верные слова» именно
  потому, что список рос изнутри сессии.
- Проверять **до** публикации: после отправки в Redmine правка уже не бесплатна.

# Мерж и релиз

Репозитории с `.github/workflows/release-please.yml` (`msb-calculator-api`) — перед мержем PR
скилл `release-please`: один мерж — один релиз.

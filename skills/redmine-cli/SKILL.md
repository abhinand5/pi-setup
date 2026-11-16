---
name: redmine-cli
description: >-
  Drive Redmine via the `redmine` CLI (aarondpn/redmine-cli) against
  https://redmine.msb-leasing.ru for msb-lk work. Use when the user mentions Redmine,
  redmine-cli, ticket, issue, задача, тикет, time entry, wiki, tags/теги
  (redmineup_tags / tag_list), Textile/описание, Internal error / 500 на
  странице issue, or asks to list/create/update/close/search issues, log time,
  or fetch attachments from Redmine (including #11301 / schedule form QA).
---

# Redmine CLI (msb-lk → redmine.msb-leasing.ru)

Project skill for **msb-lk**. Binary: `~/.local/bin/redmine` (v2.x). Server: `https://redmine.msb-leasing.ru`.

Do **not** invent subcommands or flags — run `redmine <cmd> --help`. Upstream patterns: [aarondpn/redmine-cli SKILL](https://github.com/aarondpn/redmine-cli/blob/main/skills/redmine-cli/SKILL.md).

## Auth (local)

Credentials live in env (not `~/.redmine-cli.yaml`):

- `REDMINE_SERVER`, `REDMINE_API_KEY`, `REDMINE_AUTH_METHOD=apikey`
- Defined in `~/.profile` and `~/.bashrc`

**Non-interactive agent shells** do not load `~/.bashrc` (early `return`). Before any `redmine` call:

```bash
eval "$(grep -E '^export REDMINE_' "$HOME/.profile")"
# fallback if only in bashrc:
# eval "$(grep -E '^export REDMINE_' "$HOME/.bashrc")"
```

Smoke check: `redmine --version` (флаг верхнего уровня, **не** подкоманда `redmine version` — её нет) и `redmine my-account get -o json` (expect 200 / user object).

**Never** print, log, or paste `REDMINE_API_KEY` or `api_key` from JSON responses. Redact if quoting output.

If `redmine` is missing:

```bash
VER=v2.11.0   # pin a release tag — do not use main
curl -fsSL "https://raw.githubusercontent.com/aarondpn/redmine-cli/${VER}/install.sh" \
  -o /tmp/redmine-install.sh
# skim the script, then:
bash /tmp/redmine-install.sh
```

## Critical rules

- Parse programmatically with **`-o json`** (stdout only); use `jq`, not ad-hoc regex/Python.
- Default list limit is 100; use **`--limit 0`** for all rows.
- Name flags (`--project`, `--tracker`, `--status`, `--priority`, `--assignee`, …) resolve by name; **`--assignee me`** = current user.
- `issues list` defaults to **open**; use `--status closed`, `--status "*"`, or a status name.
- `issues update` sends **only** flags you pass.
- Dates: `--due-date`, `--from`, `--to` accept literal `today`.
- Versions: prefer `redmine versions list --open` before assigning.
- **Не угадывай флаги.** У `comment`, `update` и `close` разные схемы (см. [Verified flags](#verified-flags-cli-v2110)); один неверный флаг = ошибка `unknown flag` и потерянный вызов. Если флаг отвалился — `redmine <cmd> --help`, поправь себя и (если скилл врал) сразу поправь этот файл.
- On failure twice: stop, run `--help`, ask the user — do not invent flags.
- **Описания и notes — только Textile** (не Markdown). Нарушение → HTML **500** при живой странице, API при этом часто **200** (см. ниже).
- **Роль не умеет удалять задачи и не умеет удалять/править notes** (см. [Deleting: what this role cannot do](#deleting-what-this-role-cannot-do)). Не пробуй, не ищи обход, не проси пользователя «удалить в веб-интерфейсе».
- **Пробные и черновые задачи запрещены.** Не создавай задачу «на проверку» — ни чтобы узнать следующий номер, ни чтобы проверить флаги, ни чтобы «посмотреть, как ответит API». Темы вида `probe`, `test`, `проверка`, `tmp`, `draft`, `черновик` — это пробный объект, а не работа. Номер следующей задачи — только чтением: `redmine issues list --status "*" --sort id:desc --limit 1 -o json | jq -r '.[0].id'`. Id созданной — из ответа: `redmine issues create … -o json | jq -r '.id'`; **`tail`/`head` на этом выводе запрещены** — они срезают поле `id`, и дальше хочется «измерить» номер созданием. Если id потерян — найди задачу чтением (`--filter "subject=~…"`), не создавай вторую. Создание, изменение и удаление задач — только по явному поручению пользователя.

## Verified flags (CLI v2.11.0)

Сверено с `redmine <cmd> --help` на этом сервере (2026-11-08, #15450). Самая частая ошибка — переносить `--note` из `update` в `comment`: у `comment` его **нет**, там `-m`.

| Задача | Команда | Проверенные флаги |
| --- | --- | --- |
| Добавить заметку | `issues comment <id>` | `-m`, `--message` (только это) |
| Изменить поля/добавить note | `issues update <id>` | `--note`, `--private-notes`, `--status`, `--assignee`, `--description`, `--custom-field`, `--attach`, `--due-date`, `--estimated-hours`, `--done-ratio` |
| Закрыть | `issues close <id>` | `--note` |
| Читать | `issues get <id>` | `--journals`, `--attachments`, `--relations`, `--children`, `--download-attachments <dir>`, `--include journals,children,relations,attachments` |
| Список/поиск | `issues list` | `--project`, `--status`, `--assignee`, `--author`, `--priority`, `--parent`, `--category`, `--query`, `--query-id`, `--filter key=value`, `--sort`, `--limit 0` |
| Скачать вложение | `attachments download <id>` | `-d`/`--dir`, `--path` (в т.ч. `--path -` в stdout) — **не** `-o` |
| Учесть время | `time log` | `--issue`, `--hours` (обязателен), `--activity`, `--date`, `--comment`, `--project`, `--user` |
| Версии | `versions list` | `--project` (обязателен), `--open`, `--closed`, `--locked`, `--status` |
| Сырой API | `api /issues.json` | `-X`, `--input <file>`, `-F`/`--raw-field` (тело), `-f`/`--field` (query), `-i`, `--silent` |

Глобальные: `-k/--api-key`, `-s/--server`, `-o/--output`, `--profile`, `--read-only` (страховка от случайной записи; также `REDMINE_READ_ONLY=1`), `-v/--verbose`.

Ловушки, на которых уже спотыкались:

* `issues comment <id> --notes "..."` → `Error: unknown flag: --notes`. Правильно: `-m`.
* `attachments download -o json` — это формат подтверждения, а не путь; файл кладётся в `--dir`/`--path`.
* `redmine version` → `unknown command`; версия смотрится через `redmine --version`.

## Description / notes (Textile) — частая причина HTML 500

Сервер Redmine (`redmine.msb-leasing.ru`) рендерит `description` и `notes` через **Textile (RedCloth)**. API `GET/PUT /issues/<id>.json` может быть **200/204**, а `GET /issues/<id>` (HTML) — **500 Internal error**. Уже ловили многократно (#13954 и раньше).

### Длинный текст — из файла, не строкой

`--description` и `--note` принимают только строку, поэтому описание на 5–10 КБ целиком уезжает в переписку агента. Обёртка `redmine-file` (в `PATH`, `~/.local/bin/redmine-file`) читает текст из файла сама:

```bash
redmine-file issues create --project "МСБ-лизинг" --parent 15598 --subject "…" --description-file /tmp/desc.txt
redmine-file issues update 15647 --status "Ожидает тестирование" --note-file /tmp/note.txt
```

Пиши текст в файл, в вызов передавай только путь. Остальные аргументы проходят в `redmine` без изменений.

### Перед create / update description или comment

1. Пиши **Textile**, не Markdown.
2. После записи **обязательно** проверь HTML:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
  "${REDMINE_SERVER}/issues/<id>"
# ожидай 200; если 500 — чини Textile, не создавай новую задачу
```

### Запрещено в `@code@` spans (ломает RedCloth → 500)

- Скобки: `@Foo::bar()@` → пиши `@Foo::bar@` или `@Foo::bar@()` вне span.
- Вложенный Markdown: `**жирный**`, `*(курсив)*` рядом с `@...@`.
- Непарные `@` (нечётное число на строке / в тексте).

```text
Плохо:  @DiscountFactorChainBasePaymentStrategy::balance()@
Хорошо: @DiscountFactorChainBasePaymentStrategy::balance@

Плохо:  **Эта задача** / *(отвергнуто)* рядом с @code@
Хорошо: *Эта задача* / (отвергнуто) — Textile emphasis без Markdown
```

### Разрешённый Textile (кратко)

- Заголовки: `h2.`, `h3.`
- Списки: `*`, вложенные `**`
- Код/моно: `@identifier@` (без `()` внутри)
- Акцент: `*текст*` (не `**текст**` из Markdown)
- Ссылки на задачи: `#12345`

### Диагностика «Internal error» на issue

1. `curl` HTML → 500, JSON API → 200 ⇒ почти наверняка Textile или `tag_list`.
2. Сначала проверь `tag_list` (массив строк — см. ниже).
3. Затем описание: убери `()` из `@...@`, замени Markdown `**`/`*(...)*` на Textile, выровняй пары `@`.
4. `PUT` description → снова проверь HTML **200**. Новых задач не создавать.

## Deleting: what this role cannot do

Verified on this server (2026-11-08, issue #15449): the API key's role has **no issue-delete permission**, and the CLI has **no note/journal delete or edit at all** (`issues comment` can only add; there is no `notes`, `journal` or `comment delete` subcommand). Plan around that instead of discovering it mid-task.

### Deleting an issue

`redmine issues delete <id> --force` fails with:

```text
Error: Permission denied: you don't have the required permissions for this action. Check your Redmine role permissions or contact your administrator.
```

That is a permission wall, not a transient failure: do not retry it, do not try `--profile`, do not ask the user to fix the role for this.

Junk cleanup that does work, and is what to use when you created something by mistake (test issue, wrong duplicate, abandoned draft):

```bash
redmine issues update <id> --status "Отклонена" \
  --note "Создана по ошибке при <контекст>. Junk, работу по ней не ведём; права на удаление у роли нет."
```

`Отклонена` is a closed status here, so the issue drops out of open-issue lists and reports. Report the id, the new status and the reason; that is the end of it.

### Notes (comments)

Never propose deleting a note, and never state that something can be deleted in the web interface: whether the UI would allow it is not something this skill can know, and passing that job to the user is misleading. The CLI cannot remove a journal entry, so a wrong or junk note stays on the issue.

- Wrong note that affects the work: post a **corrective note** (`redmine issues comment <id> -m "Уточнение к предыдущему: …"`) instead of trying to remove it.
- Junk note with no bearing on the task (a stray command echo, a duplicated status line): leave it alone.
- Only raise a note with the user when it would mislead whoever reads the issue's history later, that is, when it is critical to understanding the work done on the task, and then say it cannot be removed rather than asking them to delete it.

## Common workflows

### Read issue (with context)

```bash
redmine issues get <id> --journals --attachments --relations -o json
```

URL for user: `https://redmine.msb-leasing.ru/issues/<id>` or `redmine issues open <id>`.

### List / search

```bash
redmine issues list --project <id-or-name> --assignee me -o json
redmine issues list --status "*" --limit 0 -o json
redmine search "<query>" -o json
```

### Create / update / comment

```bash
redmine issues create --project <p> --subject "..." --tracker <t> -o json
redmine issues update <id> --status "<name>"   # only changed fields
redmine issues comment <id> -m "..."          # note; у comment нет --note/--notes
redmine issues comment <id> -m "$(cat note.textile)"
redmine issues close <id>
```

After create: give the user the issue URL.

### Create: never twice (это уже ловили)

`POST /issues.json` returns `{"issue": {"id": ...}}`. Two traps produce duplicate issues, and both were live in past sessions:

- Parsing the response with a top-level projection (`jq '{id, subject}'`) yields `null` for both, because everything is nested under `.issue`. `id: null` then reads like "create failed".
- `curl -sS` exits **0** on HTTP 500 as well as 200, so a Textile 500 looks like a successful empty response.

Rule: **a missing id means UNKNOWN, not failure.** The issue may already exist. Never re-POST the same payload. Look it up first:

```bash
redmine issues list --status "*" --limit 25 -o json \
  --filter "subject=~<distinctive fragment of the subject>" \
  | jq -c '.[] | {id, created_on, subject}'
```

**Never "measure" the next id by creating a probe issue.** The id of the issue you just created is in the create response — read it, do not truncate it:

```bash
redmine issues create … -o json | jq -r '.id'      # correct
redmine issues create … -o json | tail -20         # forbidden: cuts the id off
```

If the id is already lost, get the next number read-only — never by creating a throwaway issue:

```bash
redmine issues list --status "*" --sort id:desc --limit 1 -o json | jq -r '.[0].id'
```

Prefer the guard in `scripts/create-issue.sh`: it refuses when an issue with the exact subject already exists, POSTs through `redmine api` (which exits non-zero on 4xx/5xx, unlike curl), tolerates a nested or missing id, and on an ambiguous response looks the issue up and prints its id instead of creating a second one. Exit codes: 0 created or recovered, 2 already exists, 3 ambiguous, 4 genuinely failed.

```bash
jq -n --rawfile desc /tmp/desc.textile \
  '{issue:{project_id:5,tracker_id:1,subject:"…",description:$desc,tag_list:["Калькулятор-API"]}}' \
  > /tmp/payload.json
~/.pi/agent/skills/redmine-cli/scripts/create-issue.sh /tmp/payload.json   # prints the id
```

If you must shell out to curl, always pass `-f` (`--fail-with-body`) so HTTP errors are loud, and print `REDMINE_SERVER` before the call so a stub/local server mix-up is visible.

### Ambiguous tracker/status/priority

1. `redmine trackers list -o json` / `statuses list` / etc.
2. Confirm with the user if several matches.
3. Then run the mutating command.

### Users without admin

Resolving users **by name** needs admin. Prefer `--assignee me`, or take IDs from `issues list` / `memberships list --project … -o json`.

For yourself: `--assignee me`.

### Tags (redmineup_tags)

Plugin: **redmineup_tags** (`issue[tag_list]`). CLI has **no** `--tag` flag — set tags via REST API.

**Critical:** `tag_list` must be a **JSON array of strings**. A plain string (or `redmine api -F 'issue[tag_list]=…'`) often yields **500**. Correct:

```json
{"issue": {"tag_list": ["Калькулятор-API"]}}
```

Create with tag (and optional parent/assignee) in one request. Build the body with `jq`, then let the guard create it once:

```bash
eval "$(grep -E '^export REDMINE_' "$HOME/.profile")"
jq -n --rawfile desc /tmp/desc.textile '{"issue":{
  "project_id":5,"tracker_id":2,"subject":"…","description":$desc,
  "parent_issue_id":11301,"assigned_to_id":127,"priority_id":3,
  "tag_list":["Калькулятор-API"]}}' > /tmp/payload.json
~/.pi/agent/skills/redmine-cli/scripts/create-issue.sh /tmp/payload.json
```

`redmine api /issues.json -X POST --input /tmp/payload.json` is the raw equivalent: same body, and it exits non-zero on HTTP errors. Do not hand-roll `curl -sS` here; without `-f` it reports success on a 500.

Update tags on an existing issue (HTTP **204** on success):

```bash
curl -sSf -o /dev/null -w '%{http_code}\n' -X PUT \
  -H "X-Redmine-API-Key: ${REDMINE_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"issue":{"tag_list":["Калькулятор-API"]}}' \
  "${REDMINE_SERVER}/issues/<id>.json"
```

Notes:

- JSON `GET /issues/<id>.json` usually **omits** `tag_list` / `tags` — verify tags in HTML (`Теги:`) or the issue page.
- Common calculator tag: **`Калькулятор-API`**.
- Multiple tags: `"tag_list": ["Калькулятор-API", "UI"]`.

### Attachments (required when present)

If an issue has attachments (esp. images), **download and inspect** before answering:

```bash
redmine issues get <id> --attachments -o json
redmine attachments download <att-id> -d /tmp/redmine-<id>/
# or all:
redmine issues get <id> --download-attachments /tmp/redmine-<id>/
```

Then `Read` image/files. Do not guess from description alone.

### Time

```bash
redmine time list --issue <id> -o json
redmine time log --issue <id> --hours 1 --activity "<name>" --date today
```

## Top-level commands

`issues`, `attachments`, `queries`, `projects`, `time`, `versions`, `files`, `memberships`, `users`, `my-account`, `groups`, `roles`, `categories`, `trackers`, `statuses`, `custom-fields`, `search`, `auth`, `wiki`, `api`, `config`, `mcp`.

## Communication

- Respond to the user in **Russian** unless they write in English.
- Prefer issue links `https://redmine.msb-leasing.ru/issues/<id>`.
- Do not commit secrets; do not write API keys into repo files or plans.

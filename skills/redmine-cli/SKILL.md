---
name: redmine-cli
description: >-
  Drive Redmine via the `redmine` CLI (aarondpn/redmine-cli) against
  https://redmine.msb-leasing.ru for msb-lk work. Use when the user mentions Redmine,
  redmine-cli, ticket, issue, задача, тикет, time entry, wiki, tags/теги
  (redmineup_tags / tag_list), Textile/описание, Internal error / 500 на
  странице issue, or asks to list/create/update/close/search issues, read the
  journal and notes (`--journals`), relations, children, log time, or fetch
  attachments from Redmine (including #11301 / schedule form QA).
---

# Redmine CLI (msb-lk → redmine.msb-leasing.ru)

Project skill for **msb-lk**. Binary: `~/.local/bin/redmine` (v2.x). Server: `https://redmine.msb-leasing.ru`.

**Канон — этот файл** (возвращён в репозиторий после `15653cb8c4`, тело приведено к актуальному CLI v2.11.0 по внешней копии pi-агента `~/.pi/agent/skills/redmine-cli/`). Правка здесь; внешнюю копию синхронизировать вручную.

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
- Name flags (`--project`, `--tracker`, `--status`, `--priority`, …) resolve by name; **`--assignee` по имени на этом сервере падает** — только числовой id или `me` (= текущий пользователь), см. [Ловушки](#verified-flags-cli-v2110).
- `redmine-file` — обёртка над `redmine`, не второй бинарь: её флаги `--description-file` / `--note-file` **не видны в `--help`** (обёртка передаёт `--help` в `redmine` и своих флагов не показывает), поэтому `--help | grep description-file` даёт 0 — это не отсутствие флага, см. [Длинный текст](#длинный-текст--обёрткой-redmine-file).
- `issues list` defaults to **open**; use `--status closed`, `--status "*"`, or a status name.
- `issues update` sends **only** flags you pass.
- Dates: `--due-date`, `--from`, `--to` accept literal `today`.
- `issues get -o json` без `--journals` / `--attachments` / `--relations` этих блоков не содержит — журнал приходит только с `--journals`.
- `issues update --description` принимает **строку**, не файл: `--description "$(cat /tmp/desc.txt)"`. Прочитанное через `jq -r .description` возвращается с **CRLF** — при построчных заменах открывай файл с `newline=''` и правь `\r\n`, иначе точное совпадение не находится.
- Versions: prefer `redmine versions list --open` before assigning.
- **Не угадывай флаги.** У `comment`, `update` и `close` разные схемы (см. [Verified flags](#verified-flags-cli-v2110)); один неверный флаг = ошибка `unknown flag` и потерянный вызов. Если флаг отвалился — `redmine <cmd> --help`, поправь себя и (если скилл врал) сразу поправь этот файл.
- On failure twice: stop, run `--help`, ask the user — do not invent flags.
- **Не глушить stderr у `redmine`.** `redmine … 2>/dev/null` превращает `unknown flag: --search` в пустой список, и «ничего не заведено» читается как факт: в #15676 так четыре раза решили, что находки нигде не заведены, и завели работу, которую уже планировала соседняя задача (#15719 п.1). Нужен тихий вызов — сначала `redmine <cmd> --help` и убедись, что флаг существует.
- **Исполнителя, приоритет и статус не угадывать.** Поле, которого нет в запросе, заполняется по умолчанию, и дефолт у исполнителя не тот, что у автора: автор записи — владелец ключа (`redmine my-account`), а **исполнитель — дефолт трекера/проекта, а не автор запроса**. Замер 19.11.2026 (#15838): задача, созданная без `--assignee`, приехала на «Пользователь Технический», исправить пришлось вторым вызовом `--assignee 127`. Приоритет — дефолт трекера, статус — дефолт проекта. Соседняя задача с похожей темой или реплика со встречи («паритет отдаём X») — не основание назначить X: это другой объём работ. Если контекст указывает на другого человека, а пользователь его не назвал — один `ask_user_question` до создания, не после. В ответе после создания перечисли, какие поля взяты по умолчанию (#15579 — пакет создан на QA, хотя нужен был для самопроверки автору).
- **Описания и notes — только Textile** (не Markdown). Нарушение → HTML **500** при живой странице, API при этом часто **200** (см. ниже).
- **Роль не умеет удалять задачи и не умеет удалять/править notes** (см. [Deleting: what this role cannot do](#deleting-what-this-role-cannot-do)). Не пробуй, не ищи обход, не проси пользователя «удалить в веб-интерфейсе».
- **Пробные и черновые задачи запрещены.** Не создавай задачу «на проверку» — ни чтобы узнать следующий номер, ни чтобы проверить флаги, ни чтобы «посмотреть, как ответит API». Темы вида `probe`, `test`, `проверка`, `tmp`, `draft`, `черновик` — это пробный объект, а не работа. Номер следующей задачи — только чтением: `redmine issues list --status "*" --sort id:desc --limit 1 -o json | jq -r '.[0].id'`. Id созданной — из ответа: `redmine issues create … -o json | jq -r '.id'`; **`tail`/`head` на этом выводе запрещены** — они срезают поле `id`, и дальше хочется «измерить» номер созданием. Если id потерян — найди задачу чтением (`--filter "subject=~…"`), не создавай вторую. Создание, изменение и удаление задач — только по явному поручению пользователя.

## Verified flags (CLI v2.11.0)

Сверено с `redmine <cmd> --help` на этом сервере (2026-11-08, #15450). Самая частая ошибка — переносить `--note` из `update` в `comment`: у `comment` его **нет**, там `-m`.

| Задача | Команда | Проверенные флаги |
| --- | --- | --- |
| Добавить заметку | `issues comment <id>` | `-m`, `--message` (только это) |
| Изменить поля/добавить note | `issues update <id>` | `--note`, `--private-notes`, `--status`, `--priority`, `--assignee`, `--subject`, `--description`, `--tracker`, `--parent`, `--category`, `--version`, `--start-date`, `--due-date`, `--estimated-hours`, `--done-ratio`, `--custom-field`, `--attach`, `--private` |
| Закрыть | `issues close <id>` | `--note` |
| Читать | `issues get <id>` | `--journals`, `--attachments`, `--relations`, `--children`, `--download-attachments <dir>`, `--include journals,children,relations,attachments` |
| Дети задачи | `issues list --parent <id> --status "*"` | `--children` у `issues get` отдаёт **только id** — без тем и статусов, и вторым запросом их всё равно берут списком. Один вызов вместо двух (#15735 п.5) |
| Список статусов | `statuses list` | Без флагов, `-o json` отдаёт `id` и `name`. Запасной путь — `redmine api /issue_statuses.json` + выборка из `.issue_statuses`. `redmine issue-statuses list` — **нет такой команды** (`unknown command`, #15735 п.5) |
| Список | `issues list` | `--project`, `--status`, `--assignee`, `--author`, `--priority`, `--parent`, `--category`, `--query`, `--query-id`, `--filter key=value`, `--sort`, `--limit 0` |
| Поиск по тексту | `search` (и `search issues`) | `search "<query>"`, `--all-words`, `--attachments`, `--limit`; у `issues list` **нет** `--search` — эквивалент `--filter "subject=~…"` |
| Скачать вложение | `attachments download <id>` | `-d`/`--dir`, `--path` (в т.ч. `--path -` в stdout) — **не** `-o` |
| Учесть время | `time log` | `--issue`, `--hours` (обязателен), `--activity`, `--date`, `--comment`, `--project`, `--user` |
| Версии | `versions list` | `--project` (обязателен), `--open`, `--closed`, `--locked`, `--status` |
| Сырой API | `api /issues.json` | `-X`, `--input <file>`, `-F`/`--raw-field` (тело), `-f`/`--field` (query), `-i`, `--silent` |

Глобальные: `-k/--api-key`, `-s/--server`, `-o/--output`, `--profile`, `--read-only` (страховка от случайной записи; также `REDMINE_READ_ONLY=1`), `-v/--verbose`.

Ловушки, на которых уже спотыкались:

* `issues comment <id> --notes "..."` → `Error: unknown flag: --notes`. Правильно: `-m`.
* `attachments download -o json` — это формат подтверждения, а не путь; файл кладётся в `--dir`/`--path`.
* `redmine issues list --search "…"` → `Error: unknown flag: --search` (проверено 17.11.2026, #15719). Поиск по тексту: `redmine search "<query>" -o json` (объекты с `id` и `title`, не задачи), `redmine search issues "<query>"`, либо `redmine issues list --filter "subject=~…"` — точные поля задачи, как у `issues get`.
* `redmine version` → `unknown command`; версия смотрится через `redmine --version`.
* **`--assignee "Имя Фамилия"` на этом сервере не находится по имени** (проверено на #15602, 14.11.2026). CLI ищет пользователя через `GET /users.json`, у роли нет прав → `403`, CLI падает:

  ```
  Error: resolving assignee: cannot resolve assignee by name (listing users requires admin privileges).
  Use a numeric user ID instead, or "me" for yourself
  ```

  Код возврата 1. `--status` по имени при этом подставляется нормально (через `GET /issue_statuses.json`). Исполнителя задавать **числовым id** (`--assignee 128`) или `me`; id смотреть в уже назначенных задачах, `issues get` чужой задачи, или спросить.
* **Поля проверяются до `PUT`, и падение проверки отменяет весь запрос.** В `-v` видно `[debug] Resolver: …`, затем `[debug] HTTP PUT …`. Если `PUT` в логе нет — не применилось **ни одно** поле, включая успешно проверенный `--status`. Не считать «половину» применённой.
* **Снятие родителя через `--parent 0` сервер отклоняет и гасит весь `update`.** `redmine issues update <id> --parent 0` → `Validation error: Родительская задача имеет неверное значение`, и не применяется **ни одно** поле запроса. Итог тот же, что у падения проверки выше, но причина другая: `PUT` уходит и его отклоняет сервер — при отладке смотреть тело ответа, а не лог `[debug] HTTP Resolver`. Рабочий путь — сырой API с `null` (проверено 19.11.2026, #15779; #15835 п.3):

  ```bash
  printf '{"issue":{"parent_issue_id":null}}' > /tmp/parent-null.json
  redmine api /issues/<id>.json -X PUT --input /tmp/parent-null.json
  ```

* **`--priority` принимает русские имена и числовой id, но не `High`/`Normal`.** `--priority High` печатает список имён сервера («Высокий» (3), «Очень высокий(and fixed date)» (4), «Немедленно(expedite)» (5)) и приоритет **не** меняет, а выглядит как применение. Проходит `--priority "Высокий"` или `--priority 3` (#15838 п.4).
* **Код возврата теряется в конвейере.** `redmine … | jq` / `| head` возвращает код `jq`/`head`, а не CLI: упавший `update` выглядит успешным. Проверять без конвейера или с `set -o pipefail`.
* **Тело `issues update -o json` не содержит статуса и исполнителя.** Успешный ответ — `{"ok": true, "action": "updated", "resource": "issue", "id": N, "message": …}`: полей `status`/`assigned_to` там нет вовсе, поэтому `jq '{id, status:.status.name}'` по нему даёт `id` и `null`. Это **не** признак сбоя (#15661 п.4). Ошибка — тело `{"error":{"message":…,"code":"unknown"}}` или `ok: false`; проверять по ним, а применённое состояние — `issues get` (ниже).

  ```bash
  # Код CLI не теряется: сначала вывод в переменную, потом разбор (см. буллет выше).
  out=$(redmine issues update <id> --status "В работе (спринт)" -o json) || exit 1
  printf '%s' "$out" | jq -e '.ok == true' > /dev/null || { echo "update не применился: $out" >&2; exit 1; }
  state=$(redmine issues get <id> -o json) || exit 1
  printf '%s' "$state" | jq -r '"\(.status.name) | \(.assigned_to.name // "—")"'
  ```

* **Закрытие бывает отклонено молча, и код возврата об этом не говорит.** `issues close <id>` и `issues update <id> --status "Закрыта"` возвращают HTTP 204, а CLI с `-o json` печатает `{"ok": true, "action": "updated"}` — тело ответа CLI, а не сервера (см. буллет выше). Статус при этом остаётся прежним: записи `status_id` в журнале нет. Частая причина — **открытые подзадачи**, Redmine не даёт закрыть родителя. Пример 24.11.2026 (#16027 п.1): #15981 не закрывался, пока был открыт единственный ребёнок #16024; ребёнок закрыт в 12:15:32, родитель перешёл из «Ожидает тестирование» в «Закрыта» в 12:16:05. Права роли тут ни при чём, и проверять их пробной задачей нельзя (запрет выше). Признак применённого перехода — запись `status_id` в `issues get <id> --journals`. Открытые дети — `issues list --parent <id> --status "*"`: у `issues get <id> --children` только id, без тем и статусов (см. таблицу выше).
* **Кто закрывает — по канону сдачи, а не по этой строке.** Разработчик доводит задачу до «Ожидает тестирование» и закрывает только по явной просьбе; срез документации, тестов и агентской оснастки закрывает автор сам. Границы — `.pi/skills/hand-off-to-testing/SKILL.md` §0 и `.pi/skills/implement-plan/SKILL.md` §9; здесь они не переписываются. Пути в бэктиках, а не ссылками: у этой копии скилла нет соседних каталогов (она лежит и в pi-setup), и относительная ссылка ломается в одном из двух мест.

## Description / notes (Textile) — частая причина HTML 500

Сервер Redmine (`redmine.msb-leasing.ru`) рендерит `description` и `notes` через **Textile (RedCloth)**. API `GET/PUT /issues/<id>.json` может быть **200/204**, а `GET /issues/<id>` (HTML) — **500 Internal error**. Уже ловили многократно (#13954 и раньше).

### Перед create / update description или comment

1. Пиши **Textile**, не Markdown.
2. **Markdown-жирного в тексте нет** — ни внутри `@code@`, ни рядом, ни в обычном абзаце. Запрещён
   именно `**слово**`: две звёздочки, за которыми идёт не пробел. `**` в начале строки — маркер
   вложенного списка — легальный Textile и под запрет не попадает. Это единственная проверка, которую
   видно без Redmine и которая ловит самый частый случай (#15666 п.5). Текст держи в файле — его же
   читает `--note "$(cat "$NOTE")"`:

```bash
NOTE=/tmp/redmine-<id>/note.textile
[ -s "$NOTE" ] || { echo 'STOP: файл заметки не найден или пуст — проверять нечего' >&2; exit 1; }
if grep -nE '\*\*[^ *]' "$NOTE"; then
  echo 'STOP: Markdown-жирный (**слово**) — RedCloth упадёт; жирный в Textile: *слово*' >&2
  exit 1
fi
```

Проверка на отсутствующем файле закрыта отдельно: `grep` без файла возвращает код 2, и без строки
`[ -s ]` гейт прочитал бы это как «совпадений нет» — тот самый гейт, который проходит вхолостую.

3. После записи **обязательно** проверь HTML одной командой — она сама подставит креды и упадёт на ≠200:

```bash
bash .pi/skills/redmine-cli/scripts/check-issue-html.sh <id>
# issue #<id>: HTTP 200 (expect 200) → страница жива
# HTTP 500 → чини Textile, не создавай новую задачу
```

### Запрещено (ломает RedCloth → 500)

- **Markdown-жирный — нигде.** `**жирный**` и `*(курсив)*` роняют страницу не только внутри
  `@code@`: и рядом с ним, и в обычном абзаце без всякого кода. Запрет про Markdown-выделение, а не
  про `**` вообще: вложенный список в начале строки — легальный Textile (см. ниже). Оговорки «только
  в span» нет и не должно быть — journal 51953 положил страницу #15664 заметкой, где жирный стоял
  рядом со span (#15666 п.5). Жирный — только Textile: `*жирный*`.
- Скобки в span: `@Foo::bar()@` → пиши `@Foo::bar@` или `@Foo::bar@()` вне span.
- Непарные `@` (нечётное число на строке / в тексте).

```text
Плохо:  @DiscountFactorChainBasePaymentStrategy::balance()@
Хорошо: @DiscountFactorChainBasePaymentStrategy::balance@

Плохо:  **Эта задача** / *(отвергнуто)* — в заметке, рядом с @code@ или без него
Хорошо: *Эта задача* / (отвергнуто) — Textile emphasis без Markdown
```

### Разрешённый Textile (кратко)

- Заголовки: `h2.`, `h3.`
- Списки: `*`, вложенные `**`; нумерованный — `#` (не `1.` — Textile его не нумерует)
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
redmine issues list --filter "subject=~Ретро" --limit 0 -o json   # точные поля задачи
redmine search "Ретро #15676" -o json                          # поиск по тексту: id + title
```

`issues list` не знает `--search`: неизвестный флаг падает, а с погашенным stderr выглядит как
пустой список (#15719 п.1). Поиск по тексту — `search` или `--filter "subject=~…"`.

### Create / update / comment

```bash
redmine issues create --project <p> --subject "..." --tracker <t> -o json
redmine issues update <id> --status "<name>"   # only changed fields
redmine issues comment <id> -m "..."          # note; у comment нет --note/--notes
redmine issues comment <id> -m "$(cat note.textile)"
redmine issues close <id>
```

After create: give the user the issue URL.

### Длинный текст — обёрткой `redmine-file`

`--description` и `--note` принимают только строку, поэтому описание на несколько килобайт целиком
попадает в переписку агента. Обёртка `~/.local/bin/redmine-file` (в `PATH` раньше `redmine`) читает текст
из файла и подставляет в тот же флаг:

```bash
redmine-file issues create --project "МСБ-лизинг" --parent 15598 --subject "…" --description-file /tmp/desc.txt
redmine-file issues update 15705 --note-file /tmp/note.txt [--private-notes]
```

Флаги обёртки — `--description-file` и `--note-file` (в том числе в форме `--flag=путь`). `--help` она не
перехватывает: дописывает путь и передаёт вызов в `redmine`, поэтому `redmine-file issues create --help`
печатает справку `redmine` (замер 19.11.2026: stdout 2603 байта, stderr пуст), и своих флагов в ней нет —
`grep description-file` даёт 0 в обоих потоках. Это не отсутствие флага (#15705 п.4); источник правды об
обёртке — её текст, `~/p/pi-setup/bin/redmine-file`.

### Verify that an update landed (canonical read)

Один и тот же вызов и для «проверить, что нота и вложение на месте», и для передачи в QA
(`hand-off-to-testing` §5). Флаги `--journals` и `--attachments` — не украшение: без них ответ
приходит с `notes: 0` и без блока вложений даже при опубликованной ноте, и следующий шаг — повторный
`--note`, то есть дубль в трекере (#15611 п.5).

**Ключа может не быть вовсе — обоих полей.** На задаче без записей `--journals` не даёт
`journals: []`, на задаче без вложений `--attachments` не даёт `attachments: []`: ключа в ответе нет
вовсе (проверено 19.11.2026 на #15833, #15832 и #15830: `has("journals")` → `false`). Это штатный случай, а не ошибка: `jq` его маскирует
(`length` от `null` равен нулю), `python3` падает на `KeyError`. Читать оба поля только через `// []`
(#15675 п.5, #15738 п.1):

```bash
redmine issues get <id> --journals --attachments -o json \
  | jq -r '"\(.status.name) · нот: \(.journals // [] | length) · вложений: \(.attachments // [] | length)"'
```

Нужны связи и дочерние — те же флаги плюс `--relations --children`; «всё сразу» — `--include
journals,children,relations,attachments`.

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

Без `-o json` номер — **в первой строке** ответа (`Created issue <id>: <subject>`), ниже идут поля
(Tracker, Status, Subject, Assignee). `tail -5` на таком выводе оставляет только поля, и номер
приходится искать вторым запросом — так и случилось при заведении #15670. Обёртка `redmine-file`
ничего не меняет: она передаёт вывод `redmine` как есть.

If the id is already lost, get the next number read-only — never by creating a throwaway issue:

```bash
redmine issues list --status "*" --sort id:desc --limit 1 -o json | jq -r '.[0].id'
```

Prefer the guard in `scripts/create-issue.sh`: it refuses when an issue with the exact subject already exists, POSTs through `redmine api` (which exits non-zero on 4xx/5xx, unlike curl), tolerates a nested or missing id, and on an ambiguous response looks the issue up and prints its id instead of creating a second one. Exit codes: 0 created or recovered, 2 already exists, 3 ambiguous, 4 genuinely failed.

**Путь к скрипту зависит от ветки.** `.pi/skills/` есть на эпик-ветке, но не на `master`. Если основное дерево на `master` и файла `.pi/skills/redmine-cli/scripts/create-issue.sh` нет — не ищи его по worktree: используй `redmine api /issues.json --input /tmp/payload.json` (тот же payload, exits non-zero на 4xx/5xx) или скрипт из worktree эпика. То же для `scripts/check-issue-html.sh` (проверка рендера после записи): нет скрипта — тот же `curl -sS -o /dev/null -w '%{http_code}'` с заголовком `X-Redmine-API-Key`.

```bash
jq -n --rawfile desc /tmp/desc.textile \
  '{issue:{project_id:5,tracker_id:1,subject:"…",description:$desc,tag_list:["Калькулятор-API"]}}' \
  > /tmp/payload.json
bash .pi/skills/redmine-cli/scripts/create-issue.sh /tmp/payload.json   # prints the id
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
bash .pi/skills/redmine-cli/scripts/create-issue.sh /tmp/payload.json
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
- Multiple tags: `"tag_list": ["Калькулятор-API", "UI"]`.

#### Правило: тег `Калькулятор-API` на всех задачах калькулятора

Якорь охвата — поддерево **#9853** «Планирование переработки лизингового калькулятора»: всё, что под ним, — калькулятор. Прямые дети: этапы 10432, 10540, 10805, 11310, 11311, 11312. Внутри 11312 — 11301 (UI формы графика), внутри 11310 — 15598 (паритет V2 на живых графиках), а под 15598 — #15602, #15599, #15601. Тег **`Калькулятор-API`** ставится на любую из этих задач.

Задачи про калькулятор и форму графика без родителя в этом дереве тоже получают тег — по смыслу, а не по родителю: меняет расчёт, форму графика, её админские настройки, пакет `msb-calculator-api` или фикстуры расчёта. Примеры: #15600 (заявка без строки `leasing_request_values`), #15596 (подпись «Баллон» → «Выкупной платёж») — обе без родителя.

Проверять на двух шагах:

1. **При создании** — `tag_list` сразу в теле `POST /issues.json` (см. пример выше).
2. **При сдаче в работу/на тестирование** — убедиться, что тег есть; у старых задач его нет, добавлять при первой же правке полей.

Подкоманда `issues update` тег не ставит: флага `--tag` нет. Если менять статус и тег одновременно — одним `PUT` через сырой API, оба поля в одном теле:

```bash
jq -n '{issue:{status_id:9, tag_list:["Калькулятор-API"]}}' > /tmp/p.json
redmine api /issues/<id>.json -X PUT --input /tmp/p.json -i   # 204 No Content
```

`-F` здесь не подходит: это `ключ=значение` для скалярных полей (`-F 'issue[subject]=…'`), массив строк им не задать — только `--input` с JSON-файлом.

Оговорка про путаницу в номерах: `11301` висит под `11312`, а не наоборот, и `15602 → 15598 → 11310` идёт мимо 11301 — оба этапа соседние под `9853`. Поэтому проверка «входит ли в поддерево 11301» даёт ложный минус на половине задач; проверять надо поддерево **9853**.

### Attachments (required when present)

If an issue has attachments (esp. images), **download and inspect** before answering:

```bash
redmine issues get <id> --attachments -o json
redmine attachments download <att-id> -d /tmp/redmine-<id>/
# or all:
redmine issues get <id> --download-attachments /tmp/redmine-<id>/
```

Then `Read` image/files. Do not guess from description alone.

### Relations (связи между задачами)

Форма команды — с `issues` и подкомандой (#15857 п.4): `redmine relations create` — unknown command, `issues relations add 15787 --issue 15854` — unknown flag, и до `--help` уходило пять вызовов. Тип — короткое имя (`relates`), а не число; `--delay` принимают только `precedes` и `follows`.

```bash
redmine issues relations add <id> --to <id> --type relates   # relates|duplicates|duplicated|blocks|blocked|precedes|follows|copied_to|copied_from
redmine issues relations add <id> --to <id> --type precedes --delay 5
redmine issues relations list <id> -o json                    # id связи — только отсюда, для remove
redmine issues relations remove <relation-id>
```

Связь, уже существующая в обратную сторону (`A blocks B` == `B blocked A`), вторым вызовом не создаётся: сначала `list`, потом `add`.

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

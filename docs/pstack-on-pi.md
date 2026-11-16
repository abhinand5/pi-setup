# pstack skills on Pi — what is compatible with this setup

Status: **installed via `npm:pi-pstack-adapter`.** `npm:pstack-claude-mirror` was removed on 2026-11-11 because its Pi
extension registered a tool named `ask_user_question`, which collides with
`@juicesharp/rpiv-ask-user-question` and makes Pi refuse to start:

```txt
Error: Failed to load extension ".../pstack-claude-mirror/plugins/pstack/pi/index.ts":
Tool "ask_user_question" conflicts with ".../@juicesharp/rpiv-ask-user-question/index.ts"
```

This note records what the alternatives are, which ones are safe next to the tools this setup
already runs, and how to re-check the numbers before installing anything.

## Two lineages, not one

Most "pstack for Pi" packages are ports of one of two different upstreams. The version numbers
do not compare across the two.

| Lineage | Upstream | Current version | Pi packages |
| --- | --- | --- | --- |
| Cursor's official pstack (poteto) | [cursor/plugins/pstack](https://github.com/cursor/plugins/tree/main/pstack) | 0.15.x | `@justjoshn/pi-pstack`, `pi-pstack-adapter`, `pi-herdr-pstack`, `pi-pstack`, `pstack-opencode` |
| Claude Code port | [michael-denyer/pstack-claude](https://github.com/michael-denyer/pstack-claude) | 0.9.135 | `pstack-claude-mirror` (what this setup used) |

The Claude Code port is a plugin with a Pi shim bolted on, which is why it collided with an
existing Pi extension. The Cursor-lineage ports are written against Pi's extension API directly.

## Packages, measured 2026-11-11

Weekly downloads from `api.npmjs.org`, publish dates from `npm view`.

| Package | dl/wk | last publish | Shape | Safe next to this setup? |
| --- | --- | --- | --- | --- |
| `@justjoshn/pi-pstack` | 5666 | 2026-11-10 | Full host: `Task`, `AskQuestion`, `TodoWrite`, `/plan`, `/loop`, automations, cloud agents | No name clash, but duplicates delegation/todo/question tools |
| `pi-herdr-pstack` | 930 | 2026-11-07 | Methodology only; needs `pi-herdr-agents` as the subagent host | Adds a second subagent engine |
| `pstack-claude-mirror` | 593 | 2026-11-11 | Unmodified mirror of the Claude Code port | **No** — `ask_user_question` collision |
| `pi-pstack-adapter` | 454 | 2026-11-06 | Downloads a pinned upstream release, exposes skills as `pistack-*`, registers no tools | **Yes** — composes with `pi-subagents` and `pi-ask-user` |
| `@casualjim/pi-pstack` | 469 | 2026-11-10 | Fork | Unverified |
| `@zenspc/pi-pstack` | 389 | 2026-10-31 | Fork | Unverified |
| `@0xrsydn/pstack-pi` | 323 | 2026-11-10 | Fork | Unverified |
| `@jiangkoumo/pi-pstack` | 197 | 2026-11-02 | Fork | Unverified |
| `pi-pstack` | 56 | 2026-08-08 | Single publish, no repository URL | **No** — registers a tool named `subagent` |

The whole namespace was created between August and November 2026, so "popular" here means a few
thousand downloads, not battle-tested. Several packages are personal repos published to npm.

## Why the collisions happen

Pi refuses to start when two extensions register the same tool name. The tool names each package
registers are the only reliable predictor, and they are not in the READMEs.

| Tool name | Registered by | Collides with |
| --- | --- | --- |
| `ask_user_question` | `pstack-claude-mirror` | `@juicesharp/rpiv-ask-user-question` |
| `subagent` | `pi-pstack` | `pi-subagents` |
| `AskQuestion` | `@justjoshn/pi-pstack` | nothing by name — but it is a second question tool next to `ask_user_question` |
| `Task` | `@justjoshn/pi-pstack` | nothing by name — but it is a second delegation tool next to `subagent` |
| `TodoWrite` | `@justjoshn/pi-pstack` | nothing by name — but it is a second todo tool next to `rpiv-todo` |

A name clash is a startup failure you cannot miss. A vocabulary clash is worse in practice: the
model sees two ways to delegate, two ways to track todos, and two ways to ask a question, and
picks one at random.

## Recommendation for this setup

This setup runs `@juicesharp/rpiv-ask-user-question`, `@juicesharp/rpiv-todo`, `pi-subagents`,
and codemode.

1. **Want the pstack skills only** (`architect`, `arena`, `interrogate`, `thermos`, `deslop`,
   `poteto-mode`, `principle-*`): use `pi-pstack-adapter`. It forks nothing, keeps upstream files
   unmodified, registers no tools, and expects `pi-subagents` for delegation and `pi-ask-user`
   for questions. Cost: a runtime download of the upstream release on first start, `pistack-*`
   skill names, one maintainer.
2. **Want the full pstack host** (`Task` with cloud agents, `/plan`, `/loop`, automations): use
   `@justjoshn/pi-pstack`, then disable `rpiv-todo` and `pi-subagents` so only one delegation,
   todo, and question vocabulary is live. It is a personal customizations repo published to npm,
   pinned to pstack 0.15.36.
3. **Skip `pi-pstack`** (abandoned since August, collides with `pi-subagents`) and
   **`pi-herdr-pstack`** (needs `pi-herdr-agents`, a second subagent host).

If pstack is reinstalled and the `ask_user_question` collision returns, the pstack side can yield
the tool instead of removing the package: write `pi ask tool: off` to
`~/.pi/agent/pstack-models.md`. That file is pstack's override sheet and is not backed up by this
repo.

## Model slugs, and why a fan-out dies outside the cap

Three different mechanisms get conflated here, so keep them apart.

**The skills name models.** Upstream pstack targets Cursor, where every skill reads
`~/.cursor/rules/pstack-models.mdc` and falls back to a literal slug when that file is missing:
`claude-opus-5-5-xhigh`, `grok-4.7-xhigh-fast`, `composer-*`, `cursor-grok-*`. Pi never has the rule
file, so the fallback always fires. Measured on pstack 0.15.36: 7 skills plus 6 playbooks, 51
occurrences, and no `gemini` anywhere in the upstream tree. `patches/pi-pstack-models.sh` replaces
them with `pstack:<role>` references at generation time, and fails the run if a future release adds
a slug the table does not cover.

**The adapter lists models it cannot run.** `pstack_adapter models`, `subagent({ action: "list" })`
and `~/.pi/agent/models-store.json` print every id Pi knows, not every id the provider serves. Two
measured losses:

| date | what picked the model | what died |
| --- | --- | --- |
| 2026-11-13 | ad-hoc `subagent` fan-out in `work/msl-msb-lk`, reading the catalog "for family diversity" | `openrouter/google/gemini-3.8-flash`, blocked family |
| 2026-11-15 | `code-review` delegation, roles unset so the child inherited the parent model | `openrouter/deepseek/deepseek-v4-pro`, `404 ... 0 endpoints out of 14 ... guardrail restrictions` |

The 2026-11-15 loss is the important one: an **OpenRouter workspace guardrail ("model cap")**
serves exactly 14 ids, and the cap is provider-side. A model in `models-store.json` is not evidence
that the workspace may call it. The adapter itself never picks a model — with unset roles it passes
`pstack:<role>` and the child inherits the parent's model, which is how `deepseek-v4-pro` escaped
from a session that had it configured.

### Where the guard actually lives

Four layers, each doing one job:

| layer | file | job |
| --- | --- | --- |
| gate | `~/.pi/agent/settings.json` → `subagents.modelScope` (`enforce: true`, `strict: true`, 14 ids in `allow`, narrower per-agent lists for `reviewer`/`oracle`/`evidence-auditor`) | rejects any delegation naming an id outside the cap before the child starts, including the parent-model inheritance path |
| roles | `~/.pi/agent/pi-pstack-adapter.json` (versioned here as `config/pi-pstack-adapter.example.json`) | pins all 12 pstack roles and panels to capped ids, so `pstack:<role>` never resolves to `inherit` |
| policy | `config/AGENTS.md` + `config/delegation-models.md` | the policy text with the explicit block list, and the table of the 14 ids, prices and roles it points at (restored as `~/.pi/agent/docs/delegation-models.md`) |
| probe | `bin/pi-models-check` | POSTs `max_tokens: 1` to every id in `modelScope.allow` and reports 200/404, so "verified on …" is regenerable instead of folklore |

`pi-setup-sync` refuses to sync when those disagree: every id in the adapter example and in
`modelScope.agents.*.allow` must be inside `modelScope.allow`, and the model-id table in
`config/AGENTS.md` must equal it exactly.

```bash
pi-models-check            # probe the allow list
pi-models-check --json     # same, machine-readable, with the date
```

A `404` there is the provider cap, not a local misconfiguration: remove the id from the allow list
and the `AGENTS.md` table, or have the guardrail widened. Never retry it.

The cap covers OpenRouter only. `routerai/*` ids are configured as a direct provider and are still
outside delegation policy: the four RouterAI pins in `config/models.example.json` are vendor routing
for direct use, never a target for `subagent`.

Do not fix this with `set_filter` or the adapter's `modelFilter`. Per `src/gate.ts`, an active
filter blocks every `subagent` workflow script, every child that names no model, and the `resume`,
`steer`, and `schedule` actions — that broke `code-review` and any skill that lets a child inherit,
and the filter had to be removed. `subagents.modelScope` is the gate; a session-scoped `set_filter`
is worth it only inside a pstack panel run, and has to be cleared afterwards.

## Re-checking before installing

```sh
# version, publish date, maintainer, repo
npm view <pkg> version time.modified maintainers repository.url

# weekly downloads
curl -s "https://api.npmjs.org/downloads/point/last-week/<pkg>"

# every tool name it registers — the only reliable collision check
npm pack <pkg> && tar xzf <pkg>-*.tgz
grep -rhoE 'name: "[a-z_]+"' package/ | sort -u
```

## Links

- [Pi packages](https://pi.dev/packages)
- [Cursor pstack (upstream)](https://github.com/cursor/plugins/tree/main/pstack)
- [michael-denyer/pstack-claude](https://github.com/michael-denyer/pstack-claude)
- [pi-pstack-adapter](https://www.npmjs.com/package/pi-pstack-adapter)
- [@justjoshn/pi-pstack](https://www.npmjs.com/package/@justjoshn/pi-pstack)
- [pi-herdr-pstack](https://www.npmjs.com/package/pi-herdr-pstack)
- [pi-pstack](https://www.npmjs.com/package/pi-pstack)
- [@juicesharp/rpiv-ask-user-question](https://www.npmjs.com/package/@juicesharp/rpiv-ask-user-question)
- [pi-subagents](https://www.npmjs.com/package/pi-subagents)

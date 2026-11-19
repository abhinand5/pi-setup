# Abhinand's Pi Setup

<p align="center">
  <img src="assets/featured.png" alt="Pi setup screenshot" width="800">
</p>

Personal `pi-setup` for [Pi coding agent](https://pi.dev): extensions, custom themes, skills, config examples, and sync tooling.

**Recommendation:** install the Pi CLI first, then run this setup. This repo wraps and customizes an existing Pi install; it is not a replacement installer for Pi itself.

## Core model

`~/.pi/agent` is the live Pi setup. This repo is the versioned `pi-setup` copy used to back up that live setup to GitHub and recreate it on any machine.

```txt
Live Pi runtime / source of truth:
  ~/.pi/agent/extensions
  ~/.pi/agent/themes
  ~/.pi/agent/skills
  ~/.pi/agent/settings.json
  ~/.pi/agent/mcp.json

Versioned pi-setup repo:
  ~/dev/ai-agents/pi-setup
  updated from live Pi files by pi-setup-sync
```

Normal flow:

```txt
make Pi changes in ~/.pi/agent  ->  pi-setup-sync  ->  GitHub
GitHub clone on another machine ->  install Pi CLI -> ./install.sh --restore --copy-config -> ~/.pi/agent
```

Do **not** install this checkout as an active Pi package in normal use. Loading both `~/.pi/agent` and this repo causes duplicate skill/theme conflict warnings at startup. If you are editing Pi functionality while your shell is inside this repo, edit the live file under `~/.pi/agent/...` first, then run `pi-setup-sync` to copy it back here.

## What's included

| Area | Included |
| --- | --- |
| Launcher | Compact `pi` wrapper with one-line major/minor update notices |
| Install safety | `--dry-run` preview, `--backup`, and `--revert <backup-dir>` |
| Sync | `pi-setup-sync` copies live `~/.pi/agent` resources back to this repo, commits, and pushes |
| Extensions | welcome header, context breakdown, file-change review, safety guard, custom footer, local model manager |
| Config examples | Safe `settings.example.json`, `mcp.example.json`, `micme.example.json`, `playwright-mcp.json`, and the `pi-pstack-adapter.json` role pinning; the settings example pins OpenRouter through the local xray proxy and gates delegation with `subagents.modelScope` |
| Model cap check | `pi-models-check` probes every id in the delegation allow list against the provider, so a catalog entry is never mistaken for a served model |
| Russian prose check | `ru-spellcheck` catches Latin homoglyphs inside Cyrillic words and dictionary misses in Russian text, so a flash-tier model's corrupted prose is caught before it is published |
| Search guard | `rg` wrapper refuses `-r`/`--replace` (a substitution, not recursion) and an empty pattern, so a search cannot silently rewrite or flood the code an agent is reading |
| Voice dictation | Micme wired to the local [Handy](https://handy.computer) CLI — `alt+m` to dictate, no cloud STT, no API key |
| Browser automation | Playwright MCP server for interactive UAT on a private Xvfb display (no focus stealing), with a `browser-uat` skill and `uat.sh` environment CLI |
| Themes | `nebula-pulse`, `opencode`, `tokyo-night`, `one-dark-pro`, and more |
| tmux | `home/.tmux.conf` — mouse, truecolor through panes, kitty-graphics passthrough, extended keys |
| Skills | Portable backups of installed Pi/agent skills |
| Smoke test | Docker restore/sync contract test in `tests/docker-e2e.sh` |
| Guard rules test | `node --test tests/path-guard.test.mjs` — правила блокировки путей в `write`/`edit` без запуска Pi |

- `bin/pi` — compact Pi launcher wrapper
  - one-line major/minor update notices instead of large startup boxes
  - suppresses Pi's large built-in update boxes via `PI_OFFLINE=1` after its own compact notice
  - detects the real Pi binary from `PI_REAL_BIN`, `/usr/local/bin/pi`, `/usr/bin/pi`, or `/opt/homebrew/bin/pi`
  - preserves Pi's native themed header and loaded skills/extensions/themes listing
- `bin/ru-spellcheck` — deterministic Russian prose checker (homoglyphs + hunspell `ru_RU`)
  - `--homoglyph-only` flags Latin letters inside Cyrillic words (`лоkalной`, `восстанóвленное`, `обéих`) with no dictionary and no false positives; the full run also reports words missing from `ru_RU` with suggestions
  - the gate is meant for short prose: an input longer than 40 lines or 500 tokens exits 3 and asks for the full run, because vowel reduction (`сесии`, `велечину`, `скрыпт`) is invisible without the dictionary; `--allow-long` bypasses that on purpose (#15799 п.2)
  - code spans, fenced blocks, URLs, paths, and filenames are masked, so identifiers are never flagged
  - `--add СЛОВО` inside a repository grows that repository's own `.ru-spellcheck-allow` (committed with the code, found upwards from the checked file, applied on top of the personal list); `--add-personal` keeps the machine-wide `${XDG_CONFIG_HOME:-~/.config}/ru-spellcheck/allow.txt`, which the repo ships as a seed copy in `config/ru-spellcheck/allow.txt` that a restore installs only when absent
  - `tests/ru-spellcheck-repo-dict.sh` checks the project dictionary and both `--add` targets on a throwaway repository; `tests/ru-spellcheck-long-input.sh` checks the long-input refusal (exit 3), the short-text gate and `--allow-long`; `tests/ru-spellcheck-deny-list.sh` checks the denylist (priority over allow, exact word form, `--add` refusal, project `.ru-spellcheck-deny`)
  - `prek.toml` (installed by `./install.sh` when `prek` is on PATH) carries one policy hook: `deny-list-guard` refuses a commit that stages `config/ru-spellcheck/deny.txt`. `path-guard` only sees `write`/`edit`, so a `bash` rewrite in the same session used to slip past it (#15820); the commit is where the file starts travelling to `main` and to other machines. Deliberate edits pass with `SKIP=deny-list-guard git commit …` or `PI_ALLOW_DENY_LIST_CHANGE=1`, and the reason belongs in the commit message. Two builtin hooks (`trailing-whitespace`, `end-of-file-fixer`) sit next to it mostly so `SKIP=` leaves something to run: prek 0.4.3 fails with "No hooks found after filtering" when the skip empties the list
  - the denylist `config/ru-spellcheck/deny.txt` is the opposite of the allowlist and belongs to a human: a denylisted word is always a finding, even when spelled correctly or sitting in an allowlist, and `--add` refuses it. Restore **overwrites** the live `~/.config/ru-spellcheck/deny.txt` from the repo (unlike the allowlist, which is seeded only when absent): a session that could grow the deny list would un-ban its own invented vocabulary. `path-guard` additionally refuses `write`/`edit` on any `ru-spellcheck/deny.txt` and on `.ru-spellcheck-deny` (`PI_PATH_GUARD_ALLOW_DENY_LIST=1` bypasses it)
  - needs `python3-enchant` and `hunspell-ru` for the full run; `--homoglyph-only` needs neither, so it also works under a project venv that shadows `python3`
  - exit 1 on findings, so it can gate a publish step; exit 3 is the "input too long for the homoglyph gate" refusal
- `bin/pi-models-check` — probes `subagents.modelScope.allow` against the provider
  - `max_tokens: 1` per id, key from the environment or `models.json`; prints 200/404 per model
  - turns "the catalog lists it" into "the provider answered", which is the only evidence that matters under a workspace guardrail
  - exit 1 on any 404, so it can gate a restore or a CI run
- `bin/rg` — ripgrep wrapper that refuses two calls which look like a search and are not
  - `-r`/`--replace` substitutes the match (`rg -rn 'x'` rewrites every match into `n`); rg recurses by default, so the flag is never needed. Exit 2 with the hint `-n` or `-l`
  - an empty pattern matches every line — one such call put 18 829 lines into an agent's context. Exit 2
  - everything else is passed through untouched; the real binary comes from `PI_REAL_RG`, `/usr/bin/rg`, or the rest of `PATH`
- `extensions/` — versioned copies of custom Pi extensions (each one has its own note in [Feature audit](#feature-audit); the guard rules of `path-guard` are covered by `node --test tests/path-guard.test.mjs`)
  - themed startup welcome card with `/welcome updates on|off`
  - `/context` usage breakdown for startup tokens, messages, and tool calls (scrollback output; not added to model context)
  - `/filechanges` review/accept/decline workflow for Pi-made `edit`/`write` changes
  - `/safety` and `/permissions` guard rails for risky shell/file actions
  - custom footer with input/output/reasoning tokens, cost, context %, tokens/sec, model, thinking level, and git branch
  - `/local-models` manager for OpenAI-compatible local endpoints such as Ollama, LM Studio, RunPod, or llama.cpp servers
- `themes/` — versioned copies of custom themes
  - `nebula-pulse` *(current default)*
  - `opencode`
  - `tokyo-night`
  - `one-dark-pro`
  - `dracula`
  - `catppuccin-mocha`
  - `nord`
  - `gruvbox`
  - `rose-pine`
  - `synthwave-84`
- `skills/` — versioned portable copies of installed Pi skills
  - browser-uat (with `scripts/uat.sh` and the Xvfb MCP wrapper), codebase-design, diagnosing-bugs, domain-modeling, find-docs, find-skills, grill-me, grill-with-docs, grilling, handoff, hf-cli, improve-codebase-architecture, mcp-code-search, redmine-cli, safety-guard, teach, write-a-skill
  - ask-matt, code-review, implement, implement-spec, pr, prototype, research, retro, setup-matt-pocock-skills, tdd, to-questionnaire, to-spec, to-tickets, triage, wait-what, wayfinder, wizard, writing-for-agents
  - local additions, not in upstream `mattpocock/skills`: `skills/setup-matt-pocock-skills/issue-tracker-redmine.md` (a Redmine backend for the tracker skills) and its `## Local addition` section in that skill's `SKILL.md`
- `config/` — safe example config files
  - `vscode-keybindings.json` — VS Code integrated-terminal bindings that forward `ctrl+alt+d` / `ctrl+shift+d` to Pi as Kitty sequences (see [VS Code terminal keys](#vs-code-terminal-keys))
  - `micme.example.json` — Micme voice dictation wired to the local Handy CLI (see [Voice dictation](#voice-dictation-handy--micme))
  - `playwright-mcp.json` — base Playwright MCP config the Xvfb wrapper derives from (see [Browser automation](#browser-automation-playwright-mcp))
  - `models.example.json` — the OpenRouter vendor pin; `--copy-config` merges it into `models.json` instead of replacing it
  - `pi-pstack-adapter.example.json` — every pstack role and panel pinned to an id the provider serves; `--restore` copies it only when `~/.pi/agent/pi-pstack-adapter.json` is absent, `--restore --copy-config` overwrites
  - `AGENTS.md` — the delegation model policy: the blocked list (`deepseek-v4-pro`, `google/*`/`gemini-*`, `openai/*`/`gpt-*`, all `routerai/*`), the enforcement gate, the delegation rules, and the pointer to the allowed table; no Cursor model slugs; `pstack:<role>` instead of a model (see [pstack skills](#pstack-skills-pi-pstack-adapter))
  - `delegation-models.md` — the 14 ids the OpenRouter workspace guardrail serves, with prices, the cache-read ranking and assigned roles; restored to `~/.pi/agent/docs/delegation-models.md`, read before delegating

## Set up from GitHub on a machine

Install Pi first (preferred), so `pi` already works before this repo adds the optional compact launcher. In containers or unusual installs, Pi may live at `/usr/local/bin/pi`; the launcher now detects that, and you can override it with `PI_REAL_BIN=/path/to/pi`.

On a minimal Ubuntu machine/container, install clone prerequisites first:

```bash
sudo apt-get update
sudo apt-get install -y git ca-certificates
```

Fast path with preview first:

```bash
# Show exactly what would change without installing anything
curl -fsSL https://raw.githubusercontent.com/abhinand5/pi-setup/main/install.sh \
  | bash -s -- --restore --copy-config --dry-run

# Install with a timestamped backup you can revert
curl -fsSL https://raw.githubusercontent.com/abhinand5/pi-setup/main/install.sh \
  | bash -s -- --restore --copy-config --backup
```

The one-line installer clones/updates this repo at `~/dev/ai-agents/pi-setup` by default, then runs the checked-out installer. Override with `PI_SETUP_CHECKOUT=/path/to/pi-setup` or `PI_SETUP_REPO_URL=https://github.com/<user>/<repo>.git`.

Manual clone path:

```bash
git clone git@github.com:abhinand5/pi-setup.git ~/dev/ai-agents/pi-setup
cd ~/dev/ai-agents/pi-setup
./install.sh --restore --copy-config --backup
```

For HTTPS:

```bash
git clone https://github.com/abhinand5/pi-setup.git ~/dev/ai-agents/pi-setup
cd ~/dev/ai-agents/pi-setup
./install.sh --restore --copy-config --backup
```

Useful installer options:

```bash
./install.sh --restore --copy-config --dry-run   # preview without changing files
./install.sh --restore --copy-config --backup    # save current live files first
./install.sh --revert ~/.pi/agent/backups/pi-setup-YYYYMMDD-HHMMSS
```

`--restore` copies repo resources into `~/.pi/agent/extensions`, `~/.pi/agent/themes`, and `~/.pi/agent/skills`.

`--copy-config` copies `config/settings.example.json`, `config/mcp.example.json`, and `config/micme.example.json` into `~/.pi/agent/`, copies the `home/` dotfiles (`home/.tmux.conf` → `~/.tmux.conf`), and merges `config/vscode-keybindings.json` into the VS Code user `keybindings.json` (existing entries and comments are preserved; a `.bak-<timestamp>` copy is written first). A dotfile that differs from the repo copy gets the same `.bak-<timestamp>` treatment before it is overwritten, even without `--backup`.

`--backup` saves current `extensions`, `themes`, `skills`, `settings.json`, and `mcp.json` under `~/.pi/agent/backups/pi-setup-*` before replacing anything; with `--copy-config` it also records the pre-install state of every `home/` dotfile in `home-manifest.txt`, which is what `--revert` reads. Revert with the exact command printed at the end of install.

The example settings pin the startup model with `defaultProvider` + `defaultModel` (both are required — `defaultModel` is the bare model id, not `provider/model`). If that provider is not configured on your machine, Pi falls back to the first authenticated model. `enabledModels` is intentionally **not** included: those patterns are machine-specific and can produce noisy "No models match pattern" warnings for anyone restoring this repo before configuring their own providers.

Provider routing in the example:

- `defaultProvider` is `openrouter` with `defaultModel` `deepseek/deepseek-v4.1-flash-1017`; the key comes from `OPENROUTER_API_KEY`.
- `httpProxy` is `http://127.0.0.1:10808` — the local xray inbound. Pi applies it as `HTTP_PROXY`/`HTTPS_PROXY` for its own HTTP clients (only when those env vars are unset), so OpenRouter works even when the shell has no proxy env. Change or drop it on machines without that proxy. Keep `NO_PROXY=localhost,127.0.0.1,::1` in the shell so local endpoints (LM Studio, local MCP) bypass the proxy.
- `subagents.modelScope` is the delegation gate: `enforce: true`, `strict: false` in the example, `allow` = the 14 ids the OpenRouter workspace guardrail serves, plus narrower lists for `reviewer`, `oracle`, and `evidence-auditor`. `strict: true` on a live machine additionally rejects an id the gate cannot classify; the example ships `false` so a different cap does not block every launch. Background: [docs/pstack-on-pi.md](docs/pstack-on-pi.md#model-slugs-and-why-a-fan-out-dies-outside-the-cap).
- `subagents.defaultModel` is `openrouter/z-ai/glm-5.3-flash`, and every bundled agent has an explicit `agentOverrides.<name>.model`, so a delegation that names no model lands on a capped id instead of inheriting the parent's. `observational-memory.models` uses `deepseek-v4.1-flash-1017` (`observer` low, `consolidator` off — memory consolidation is bookkeeping, not a place to spend an 8192-token thinking budget, and `medium` there was being served as `high`).
- Verify the allow list against the provider before trusting it: `pi-models-check`. A 404 is the cap, not local config.
- The vendor pin (`deepinfra → inference-net → primeintellect`) lives in `~/.pi/agent/models.json` as `providers.openrouter.modelOverrides`, not in `settings.json`. `config/models.example.json` carries it for restores: `--copy-config` deep-merges that file into the live `models.json`, so other providers (RouterAI, custom endpoints) survive. Order is by observed cost, not list price: OpenRouter's own per-endpoint cache hit rate decides it, because a uniform 94% cache-read assumption flatters providers that cache worse. Read the rates from the frontend stats API the model page uses:

```bash
curl -s "https://openrouter.ai/api/frontend/v1/stats/effective-pricing?permaslug=deepseek/deepseek-v4.1-flash-20261017&shape=v7&variant=standard"
```

It returns `providerSummaries[].cacheHitRate` and `effectiveInputPrice`/`effectiveOutputPrice` per endpoint, both in dollars per million tokens. At the 2,280.8M prompt / 11.72M output profile — cost = 2280.8 × effectiveInputPrice + 11.72 × effectiveOutputPrice — the endpoints measured on 2026-11-12 cost: `deepinfra` $17.87 (flex, 94.4% cache) / $22.04 (fp8, 94.6%) / $29.08 (priority, 96.9%), `morph/fp8` $18.31 (89.0%), `primeintellect` $19.90 (93.4%), `inference-net` $42.52 (89.5%) / $45.45 (87.7%). `deepinfra/fp8/flex` is the cheapest tier but sits outside Standard routing with p50 3.6 s. List prices only: `curl -s https://openrouter.ai/api/v1/models/deepseek/deepseek-v4.1-flash-1017/endpoints`.

- `extensions/no-output-cap.ts` strips the output cap from routed requests. Pi sends `model.maxTokens` as `max_completion_tokens` on every request, and OpenRouter uses that field as an endpoint *filter*, not just a cap: `models-store.json` has 943718 for this model while every DeepInfra/InferenceNet endpoint stops at 393216, so the pin collapsed to `morph` — at the time the only endpoint that accepts 943718 — before `order` was consulted. Verified with the same pinned request: `max_completion_tokens: 393216` → DeepInfra, `393217` → Morph. The extension drops the field when the payload carries a `provider` routing object (endpoints' own limits apply), so the order holds; it leaves unrouted requests alone. Verified on a live Pi run: `provider_name` `DeepInfra`, and the billed cost matched `deepinfra/fp8` exactly (11747 × 98e-9 + 3 × 294e-9 = $0.001152088), so dropping the cap does not drift into the `flex` or `priority` tier.

Check `status` on that `api/v1` response before trusting the order. That is what retired `morph`: its only endpoint went `0 → -2 → -5` on 2026-11-11 with 23% uptime over 30 minutes, and by 2026-11-12 `status` was still `-5` at 0% uptime, so a request pinned to `only: ["morph"]` returned `Provider returned error` — a third slot that only ever produced a retry. The replacement is the cheapest healthy endpoint that is not already pinned: `primeintellect`, $19.90 at 93.4% cache hit rate, `status` 0 and 100% uptime, with a 1,048,576 context, and the same slug exists on RouterAI (`status` 0). `deepinfra` still leads on both health and cache hit rate and `inference-net` remains the neutral fallback; `morph` goes back in the pin if its `status` returns to 0 and it stays cheaper than `primeintellect`.

- The previous RouterAI provider block and settings are archived in `~/p/tunnels/docs/client/ai-routing/routerai-provider-config-backup-2026-11-11.md`.
- `config/models.example.json` also carries the four RouterAI pins (`z-ai/glm-5.3`, `z-ai/glm-5.3-flash`, `deepseek/deepseek-v4.1-flash-1017`, `~deepseek/deepseek-v4-flash-latest`) under `providers.routerai.modelOverrides`. They are inert unless a `routerai` provider with `ROUTERAI_API_KEY` exists, and the merge leaves that provider's 36-model catalog alone. RouterAI honours the same `provider.only`/`order` contract — an unknown slug returns `No endpoints found matching your provider preferences` — and its `/api/v1/models/<id>/endpoints` returns per-endpoint `tag`, `quantization`, `status`, and prices in **RUB**, so order by price within RouterAI, never across the two providers. Only those four models are pinned; the other 32 route freely. RouterAI is a **direct provider**: it is outside the delegation policy, so `routerai/*` ids never appear in `subagents.modelScope.allow`, in `pi-pstack-adapter.json`, or in the `AGENTS.md` table, even though the routing above stays configured for direct use. **Where a model is pinned on both providers, RouterAI copies the OpenRouter order** — `deepseek/deepseek-v4.1-flash-1017` is `deepinfra → inference-net → primeintellect` on both (`primeintellect` is a RouterAI endpoint too, `status` 0, which is why it could replace `morph` without breaking the equality rule), so the two providers never disagree about which vendor is preferred. RouterAI exposes no cache-hit or uptime stats (its `/api/frontend/*` is 404), so for models OpenRouter has no rule for, the order falls back to listed price with `status != 0` demoted.

Warnings:

- `--restore` replaces the current contents of those live resource directories.
- `--copy-config` overwrites `~/.pi/agent/settings.json` and `~/.pi/agent/mcp.json`, and merges (does not overwrite) `~/.pi/agent/models.json`.
- `--copy-config` is also the only step that writes `~/.tmux.conf`; a plain `./install.sh` reports the difference and leaves the
  live file alone. `--revert` restores it, or deletes it again when the backup recorded that it did not exist.
- `--restore` also copies `~/.pi/agent/AGENTS.md` and `~/.pi/agent/pi-pstack-adapter.json` when they are absent; add `--copy-config` to overwrite them. Without `--restore` neither file is touched.
- `--copy-config` only *adds* missing VS Code keybindings; it never rewrites or removes existing ones. Set `VSCODE_KEYBINDINGS=/path/to/keybindings.json` to target a non-default location (e.g. VS Code Insiders or a profile).
- Use `--dry-run` first if you only want to preview the restore.

## Use your own GitHub repo

`pi-setup-sync` does not hardcode a GitHub URL. It commits in the checkout it is installed from and runs `git push`, so it uses that checkout's configured git remote.

For your own backup, fork or create your own repo first, then clone that repo:

```bash
git clone git@github.com:<user>/<repo>.git ~/dev/ai-agents/pi-setup
cd ~/dev/ai-agents/pi-setup
./install.sh --restore --copy-config
```

If you cloned this repo first and want future syncs to push to your own GitHub repo, change `origin`:

```bash
git remote -v
git remote set-url origin git@github.com:<user>/<repo>.git
git remote -v
```

Then `pi-setup-sync` will back up your live `~/.pi/agent` changes to that remote.

## Install helper commands only

On a machine that already has the live files in `~/.pi/agent`, run:

```bash
./install.sh
```

This installs:

- `pi-setup-sync` into `~/.local/bin`
- compact launcher `bin/pi` into `~/.local/bin/pi`
- `bin/pi-models-check` into `~/.local/bin/pi-models-check`
- `bin/ru-spellcheck` into `~/.local/bin/ru-spellcheck`, plus the seed allow list into `~/.config/ru-spellcheck/allow.txt`
- `bin/rg` into `~/.local/bin/rg`, which shadows `/usr/bin/rg` for every shell that has `~/.local/bin` first in `PATH`

It also removes any legacy settings entry that points Pi at this repo as an active package.

## Uninstall pi-setup changes

To remove only what this repo installed/restored while leaving the underlying Pi CLI untouched:

```bash
./uninstall.sh
```

This removes the compact launcher, the `pi-setup-sync` helper if it points at this checkout, and restored resources under `~/.pi/agent/extensions`, `themes`, and `skills` that are owned by this repo. It removes copied example config files only when they are still identical to the examples; modified settings are left in place.

Preview first:

```bash
./uninstall.sh --dry-run
```

## Sync live Pi tweaks back to GitHub

After changing Pi locally, run this from the repo:

```bash
./sync.sh
```

Install the global helper from this checkout:

```bash
./setup_sync.sh
```

Then use it from anywhere:

```bash
pi-setup-sync
```

`pi-setup-sync` copies current `~/.pi/agent/extensions`, `~/.pi/agent/themes`, selected skills, `settings.json`, `mcp.json`, `micme.json`, `AGENTS.md`, and `pi-pstack-adapter.json` into this repo, validates JSON/theme tokens, commits, and pushes. It also copies back each dotfile already tracked under `home/` (today just `.tmux.conf`) from `$HOME`, so a hand-edited tmux config travels with the repo. It strips any self-referential package entry that would make Pi load this `pi-setup` repo at startup.

Two transforms keep the examples portable and honest:

- `settings.example.json` ships `subagents.modelScope` with the real allow list but `strict: false`, so a restore on a machine with a different cap rejects unknown ids without failing outright.
- `config/models.example.json` is merged with the live `providers.<name>.modelOverrides`, never replaced: the pins are portable, the API keys and provider catalogs are not.

It then refuses to commit when the three copies of the allow list disagree — every id in `pi-pstack-adapter.example.json` and in `modelScope.agents.*.allow` must be inside `modelScope.allow`, and the model-id table in `config/AGENTS.md` must match it exactly.

Syncing requires `git` and `python3`; pushing requires normal GitHub credentials for this repo.

Custom commit message:

```bash
pi-setup-sync "Update themes and footer"
```

Commit without pushing:

```bash
pi-setup-sync --no-push "Checkpoint local Pi setup"
```

Skill backup scans `~/.pi/agent/skills` and `~/.agents/skills`, resolves symlinks, dedupes duplicates, and stores portable copies in `skills/`. All skills are selected by default; press Enter at the selector to accept all in one keystroke. To customize, use ↑/↓ to move, Space to toggle, `a` for all, `n` for none, and Enter to continue.

Non-interactive options:

```bash
pi-setup-sync --all-skills
pi-setup-sync --skills hf-cli,diagnosing-bugs "Back up selected skills"
pi-setup-sync --no-skills "Skip skill backup"
pi-setup-sync --prune-skills "Drop skills that are gone"
```

Skill backup never deletes a repo skill just because this machine cannot see it. `skills/` entries that were not selected — because the skill is not installed under `~/.pi/agent/skills` or `~/.agents/skills`, or because you deselected it — are kept and reported:

```
warning: 1 skill(s) in repo not found locally (kept): redmine-cli
hint: --prune-skills deletes them instead
```

A locally archived skill (`~/.pi/agent/skills-archive/...`) is therefore safe: it stays in the repo as a backup and is not wiped by a sync from a machine that does not load it. Only `--prune-skills` removes those entries, and it refuses to run when discovery found no local skills at all, so a missing `~/.pi/agent/skills` cannot empty the repo.

### Pull a merged PR into the checkout

After a PR is merged on GitHub, fast-forward the checkout:

```bash
git fetch origin && git merge --ff-only origin/main
```

If git refuses with `untracked working tree files would be overwritten`, a file this machine created
outside the index — often a local config the repo has since started shipping — has exactly the content the
incoming commit brings. Prove that with `cmp` and remove the local copy instead of checking it out:

```bash
# silent and exit 0 means the local file is byte-identical to the one in main
git show origin/main:config/ru-spellcheck/deny.txt | cmp - config/ru-spellcheck/deny.txt
rm config/ru-spellcheck/deny.txt
git merge --ff-only origin/main
```

`cmp` must pass before `rm` deletes anything: only then is the file the same one main carries, and only
then is losing the local copy harmless. Do not reach for `git checkout -- <path>` in this situation — it
overwrites the file without that proof, and for an untracked path it either does nothing or checks out the
incoming content over local edits.

## Manual tests

The guard rules of `extensions/path-guard.ts` are plain JavaScript (`extensions/path-guard-core.mjs`),
so they run under the Node test runner without Pi, a model, or a session:

```bash
node --test tests/path-guard.test.mjs
```

The shell tests of the Russian checker run standalone as well (each one skips itself when its tool
is missing):

```bash
tests/ru-spellcheck-deny-list.sh     # denylist: priority over allow, exact form, --add refusal
tests/ru-spellcheck-repo-dict.sh     # project .ru-spellcheck-allow and both --add targets
tests/ru-spellcheck-long-input.sh    # long-input refusal (exit 3) and --allow-long
tests/prek-deny-list-guard.sh        # commit hook: denylist edit blocked, SKIP and env bypass pass
```

Testing anything that writes outside the repo (`install.sh`, `sync.sh`, `uninstall.sh`) needs a
throwaway `$HOME` and, for the sync case, a `git clone` — never a `cp -a` of a worktree, whose
`.git` is a file pointing back at the real gitdir. Both recipes, with the incidents behind them,
are in [tests/README.md](tests/README.md).

Run the Docker end-to-end smoke test when you want to verify the setup/restore contract without adding CI:

```bash
tests/docker-e2e.sh
```

The test starts a fresh Ubuntu container, installs minimal clone prerequisites, clones this repo from its git remote, runs `./install.sh --restore --copy-config`, verifies the live `~/.pi/agent` layout, then checks that `pi-setup-sync` can copy a live change back into the cloned repo without pushing.

Useful variants:

```bash
tests/docker-e2e.sh --restore-only
tests/docker-e2e.sh --remote https://github.com/<user>/<repo>.git --branch main
```

## Feature audit

This repo currently includes these Pi customizations.

### Launcher and startup

- `bin/pi` wraps an existing Pi CLI instead of replacing it.
- Shows compact update notices only for major/minor Pi or npm package updates.
- Uses `PI_COMPACT_UPDATE_CHECK=0` or `/welcome updates off` to disable compact update notices.
- Uses `PI_REAL_BIN=/path/to/pi` if Pi is installed somewhere unusual.
- `extensions/flow-title.ts` replaces the startup header with a themed Pi logo, version, active model, cwd, key hints, and project name.

### Transcript rendering

- `extensions/collapse-bash.ts` overrides the built-in `bash` renderers so each shell call takes one line: `$ npm test ✓ 0.8s` (or `✗` on failure). `Ctrl+O` still expands the full output.

### Tool safety

- `extensions/path-guard.ts` blocks `write`/`edit` calls whose `path` carries shell metacharacters (`>`, `|`, `;`, `` ` ``, `$(…)`, globs) or points outside cwd, `$HOME` and `/tmp`. A path is not a command: `/home/denis/work 2>/dev/null` once created the directory `/home/denis/work 2>` in the home directory, and it stayed unnoticed for twenty tool calls (#15723 п.5). The rules live in `extensions/path-guard-core.mjs` (no Pi API), so they are testable without a session: `node --test tests/path-guard.test.mjs`.
  Two more rules guard "written to the wrong place" (#15820):
  - *homoglyph twin* — the first path level that does not exist yet is compared char by char with its existing siblings through a Cyrillic→Latin lookalike table (`п` is both `p` and `n`). A twin is refused and named: `write` with `/home/denis/п/p/pi-setup-wt/…` once created four levels of directories next to `/home/denis/p` (#15743 п.1). Case-only differences (`P` next to `p`) are not a twin on purpose — they are legal on case-sensitive filesystems;
  - *main tree write* — with the session inside a worktree, a path that points into the repository but outside that worktree is refused: the edit would land in the main checkout, where nothing commits it. Two layouts are recognized: `<repo>/.claude/worktrees/<name>` (msb-lk) and `<repo>-wt/<name>` (pi-setup); any other worktree layout is not covered. The check is lexical, so writing to the shared `vendor`/`.env` symlinks of a worktree still passes.
  Both rules can be bypassed deliberately: `PI_PATH_GUARD_ALLOW_TWIN=1`, `PI_PATH_GUARD_ALLOW_MAIN_TREE=1`.

### Commands added by extensions

```txt
/welcome updates on|off       # toggle compact startup update notices
/context                      # explain context-window usage
/filechanges                  # inspect tracked edit/write changes and diffs
/filechanges-accept [force]   # keep files and clear the filechanges log
/filechanges-decline [force]  # revert tracked Pi-made changes
/safety enable|disable|status # manage Safety Guard
/permissions ...              # alias for /safety
/local-models                 # add, refresh, remove, and select local LLM endpoints
```

### Context and review workflow

- `/context` estimates startup prompt, skills, context files, selected tools, messages, and tool-call result usage.
- `/filechanges` tracks successful Pi `edit` and `write` tool calls, stores baselines in the session, shows a status/widget, renders diffs, and can accept or revert all tracked changes.
- Non-interactive accept/decline requires `force` to avoid accidental destructive reverts.

### Safety Guard

- Injects a short safety instruction before agent start.
- Blocks or asks for confirmation before destructive/risky actions not explicitly requested by the user.
- Detects force pushes, amend/rebase/reset hard, branch/tag deletion, recursive deletion, protected path writes, package removals, service changes, broad `sudo`, and context purge.
- In git repos, normal recoverable edits are allowed without extra prompts.

### Local models

- `/local-models` manages OpenAI-compatible endpoints.
- Stores endpoint metadata in `~/.pi/agent/local-models.json`.
- Registers available models as `local-<endpoint-id>` providers during extension load so `/model` can see them.
- Supports endpoint refresh, model selection, and endpoint removal.

### Footer and themes

- Custom footer shows input/output/reasoning tokens, cost, context percentage, tokens/sec, current model, thinking level, and git branch.
- Theme files define reusable palettes for the header, footer, diffs, thinking levels, markdown, and tool output.

### Configured packages

`config/settings.example.json` registers these external Pi packages by default:

- ask-user-question and todo tools
- Markdown preview/export
- MCP adapter
- context-mode and related context skills
- goal completion helper
- advisor tool
- spinner, `/btw`, and fff search

`config/mcp.example.json` configures two MCP servers: the remote grep server and the
Playwright browser server. See [Browser automation](#browser-automation-playwright-mcp).

### Rewind checkpoints (removed)

`@ayulab/pi-rewind` was dropped from the package list on 2026-11-11. It auto-checkpointed the
session cwd with `git add` into one bare repo per session under
`~/.pi/agent/ayu/checkpoints/sessions`, with no blob sharing between sessions: 25 GB after
~100 sessions, ~745 MB for a single session in a large project. Launched from `$HOME` it walked
the entire home tree, so Pi printed nothing and appeared to hang at startup; the workaround was
`~/.pi/settings.json` with `{ "ayu": { "checkpoint": { "enabled": false } } }`.

The package and `~/.pi/agent/ayu` are both gone. `/rewind` and `/tree` file restore are no longer
available; if the package comes back, set `ayu.checkpoint.exclude` (or `enabled: false`) before
the first session in any large project.

### pstack skills (`pi-pstack-adapter`)

pstack is Cursor's engineering-workflow skill set (`architect`, `arena`, `interrogate`,
`thermos`, `deslop`, `poteto-mode`, `principle-*`). It is installed here through
`npm:pi-pstack-adapter`, which downloads a certified pstack checkout and exposes every workflow
as a `pistack-*` skill:

```bash
pi install npm:pi-pstack-adapter
PISTACK_ALLOW_BOOTSTRAP=1 pi --print ok   # populate the cache without the first-start prompt
```

Cache: `~/.pi/agent/cache/pi-pstack-adapter/`. Status and per-workflow requirements:
`/pistack-status` and `/pistack-check <skill>`.

The question provider is `@juicesharp/rpiv-ask-user-question`, **not** `pi-ask-user`. The adapter
hardcodes a probe for a tool named `ask_user` with `question` + `options` parameters, so
`patches/pi-pstack-adapter.sh` rewrites that probe to `ask_user_question` / `questions` and fixes
the generated host-mapping row. `install.sh` re-applies it, because `pi install` and
`pi update --extensions` reinstall the npm package and revert the patch:

```bash
./patches/pi-pstack-adapter.sh --check     # exit 1 if the patch is missing
./patches/pi-pstack-adapter.sh             # apply + drop stale generated wrappers
```

The earlier `pstack-claude-mirror` package registered its own `ask_user_question` tool, which
collided with rpiv and stopped Pi from starting; it was removed on 2026-11-11 and stays out.
Which other ports are safe next to this setup's tools: [docs/pstack-on-pi.md](docs/pstack-on-pi.md).

The upstream bodies also hardcode Cursor model ids. Whenever their Cursor rule file is missing —
always, on Pi — they fall back to `claude-opus-5-5-xhigh` and `grok-4.7-xhigh-fast`, ids that do not
exist here. `patches/pi-pstack-models.sh` rewrites every generated body, and every copied playbook
and reference file, to a `pstack:<role>` reference, so no skill names a model; the adapter's own
`setup.md` examples use `<provider>/<model>` placeholders instead. The rewrite table lives in the
script and the run fails when a new upstream release adds a slug the table does not cover:

```bash
./patches/pi-pstack-models.sh --check     # exit 1 if the patch is missing
./patches/pi-pstack-models.sh             # apply + drop stale generated wrappers
```

The roles then need models that the provider actually serves, and the adapter passes
`pstack:<role>` through to whatever `~/.pi/agent/pi-pstack-adapter.json` pins. All 12 roles and
panels are pinned there to ids inside the workspace cap; the file is versioned here as
`config/pi-pstack-adapter.example.json`. `install.sh --restore` copies both `AGENTS.md` and
`pi-pstack-adapter.json` only when the live file is absent; `--restore --copy-config` overwrites.
The enforcement layer behind both is `subagents.modelScope` in `settings.json`, and `pi-models-check`
proves the allow list against the provider. Background and the evidence:
[docs/pstack-on-pi.md](docs/pstack-on-pi.md#model-slugs-and-why-a-fan-out-dies-outside-the-cap).

### `/review-loop`: the reviewer stays in its own directory

`patches/pi-subagents-review-loop-scope.sh` adds one paragraph to the packaged `/review-loop`
prompt: a reviewer works only in the directory it was given and must not read, quote, or claim the
uncommitted work of a sibling worktree. `cwd` alone is not enough — `git worktree list` invites the
detour by itself, and a reviewer that took it reported 13 dirty files of another session as findings
about the diff it was given (#15674 п.3). The edit is idempotent and survives `pi update --extensions`
through `install.sh`:

```bash
./patches/pi-subagents-review-loop-scope.sh --check     # exit 1 if the paragraph is missing
./patches/pi-subagents-review-loop-scope.sh             # apply
```

### `/review-loop`: the diff is taken against `origin/<base>`

`patches/pi-subagents-review-loop-origin-base.sh` adds one paragraph to the same packaged prompt: the
artifact under review is taken against `origin/<base>`, not the local base branch, with an explicit
fallback for a repository whose base has no remote-tracking ref. A local branch lags silently: on
2026-11-17 a review of #15702 was taken against a local `main` two commits behind `origin/main`, the
artifact included an unrelated #175 fix and the 0.28.8 release files, and both reviewers spent a P1 on
it (#15733 п.2). The block is idempotent and survives `pi update --extensions` through `install.sh`:

```bash
./patches/pi-subagents-review-loop-origin-base.sh --check     # exit 1 if the paragraph is missing
./patches/pi-subagents-review-loop-origin-base.sh             # apply
```

## Voice dictation (Handy + Micme)

`alt+m` toggles dictation inside Pi. Audio is recorded with `ffmpeg`, transcribed by the local [Handy](https://handy.computer) CLI, and appended to the focused editor for review — no cloud STT, no API key.

```bash
pi install npm:@senad-d/micme
```

`config/micme.example.json` is restored to `~/.pi/agent/micme.json` by `./install.sh --copy-config`. It sets:

| Key | Value | Why |
| --- | --- | --- |
| `MICME_TRANSCRIBE_BACKEND` | `custom` | Use the shell command instead of whisper.cpp |
| `MICME_TRANSCRIBE_COMMAND` | `handy --transcribe-file {audio} --json > {tempDir}/handy.json && jq -r .text {tempDir}/handy.json` | Handy's headless CLI; the `> file && jq` form surfaces Handy failures instead of returning an empty transcript (`sh -lc` is dash, so `pipefail` is unavailable) |
| `MICME_RECORD_SAMPLE_RATE` | `16000` | Handy rejects anything but 16 kHz mono 16-bit PCM |
| `MICME_SHORTCUT` | `alt+m` | Same binding as upstream pi-dictate |
| `MICME_AUTO_SUBMIT` | `0` | Paste for review, never auto-send |

Handy must have a model installed (`handy --list-models` marks installed ones with `✓`). Each dictation cold-loads the model (~1-2 s) because `--transcribe-file` runs a separate process from the running app.

Verify the wiring without touching the mic:

```bash
cd /tmp && git clone --depth 1 https://github.com/senad-d/micme && cd micme \
  && npm install --ignore-scripts --legacy-peer-deps \
  && node --experimental-strip-types scripts/doctor.mjs
```

Expect `✓ effective backend: custom` and `✓ custom transcribe command: configured`. The doctor must run from a checkout, not from `node_modules` — Node refuses type-stripping there.

## Browser automation (Playwright MCP)

Interactive browser UAT: navigating, clicking, filling forms, reading console and
network activity, and taking screenshots of a real browser. This is for manual
testing and debugging, not for authoring CI test suites.

The browser runs on a **private Xvfb display**, so it never opens a window on
your desktop, never steals focus, and never covers your editor. Screenshots are
the only way to see it.

### What is configured

`config/mcp.example.json` registers the server through a wrapper script:

```json
"playwright": {
  "command": "~/.pi/agent/skills/browser-uat/scripts/playwright-mcp-xvfb.sh",
  "args": ["--isolated"]
}
```

The wrapper (`skills/browser-uat/scripts/playwright-mcp-xvfb.sh`) owns the
launch details so `mcp.json` stays readable:

- starts `Xvfb`, which picks its own free display number (via `-displayfd`), at `1920x1080x24`
- derives an Xvfb config from `~/.pi/agent/playwright-mcp.json`, swapping
  `--start-maximized` (a no-op without a window manager) for `--window-size`
- writes screenshots, snapshots, and console logs to `$TMPDIR/browser-uat`
  instead of `./.playwright-mcp/` in the repo
- closes an idle browser after 15 minutes
- kills the display when the MCP server exits
- falls back to `--headless` when Xvfb is missing, so UAT still works

Override the wrapper defaults with `UAT_HEADLESS`, `UAT_SCREEN`, `UAT_ARTIFACTS`,
`UAT_IDLE_TIMEOUT`, `UAT_MCP_PKG`, or `UAT_PLAYWRIGHT_CONFIG`; the wrapper header
documents each.

The `:99`-`:120` display scan belongs to `uat.sh display start`, which is only for
manual debugging; the wrapper never scans.

`config/playwright-mcp.json` is the base config the wrapper derives from:

```json
{
  "browser": {
    "launchOptions": { "args": ["--start-maximized", "--ozone-platform=x11"] },
    "contextOptions": { "viewport": null }
  }
}
```

- The server version is pinned in the wrapper (`UAT_MCP_PKG`) so the tool surface
  is reproducible. Bump it deliberately.
- `--isolated` keeps the browser profile in memory and never touches your real
  browser profile. Logins therefore do not persist between restarts.
- `viewport: null` is required for the window size to mean anything; otherwise
  Playwright pins a fixed viewport inside a default-sized window.
- `--ozone-platform=x11` is kept in the base config; it is harmless on the Xvfb
  path (`DISPLAY` is set, `WAYLAND_DISPLAY` is unset) and required on the
  headless/fallback path, where `WAYLAND_DISPLAY` may still be set.

### Verify the setup

```bash
~/.pi/agent/skills/browser-uat/scripts/uat.sh doctor
```

`doctor` checks npx, a browser, Xvfb, the MCP entry, and the artifact directory,
and prints the exact fix for anything missing. `install.sh` runs a subset of
these checks in advisory mode and never installs prerequisites for you.

Inside Pi, a newly added server is only callable after `/reload` (or a new
session). The first `npx` run downloads the server package, so the first
connection is slow.

### Managing the environment

```bash
uat.sh doctor                     # preconditions, with fixes
uat.sh config install [--dry-run] # point ~/.pi/agent/mcp.json at the wrapper
uat.sh config show                # effective playwright config
uat.sh display start|stop|status  # standalone Xvfb for manual debugging
uat.sh artifacts list|clean|path  # screenshots, snapshots, logs
uat.sh report                     # UAT report template
```

The browser itself is driven with `mcp__playwright__*` tools, not from the
script. The `browser-uat` skill carries the operating procedure: build a QA
inventory first, act from `browser_snapshot` refs, verify with console/network
evidence, and screenshot anything visual.

### Logging in without putting credentials in the chat

`uat.sh login` reads the phone and the one-time code from the project's `.env`,
drives the sign-in form in a headless browser, and saves the Playwright storage
state the MCP server loads on its next start. Two things it gets right by default:

- **Proxy** — taken from `browser.contextOptions.proxy` in
  `~/.pi/agent/playwright-mcp.json` (or `UAT_PLAYWRIGHT_CONFIG`), the same file the
  MCP wrapper reads. The login starts a browser of its own, so the two can end up
  on different routes — that is what timed the sign-in page out in #15799 п.1.
  `--proxy-server URL` overrides the server; `--no-proxy` passes
  `--no-proxy-server`, which is the only way to pin the direct route, because
  otherwise Chromium may take a proxy from the system settings.
- **Host** — the saved state is domain-scoped, so a login made on `127.0.0.1` is
  a guest in a browser that opens `localhost`. The loopback host is rewritten to
  `localhost` (the port is kept) and the cookie domains are printed after the
  login; `--keep-host` leaves the URL alone.

`tests/browser-uat-login-proxy.sh` checks the resolved values on `--dry-run` and the options
`chromium.launch()` actually receives, through a stub Playwright package — no browser, no network.

Two sharp edges are worth repeating:

- `browser_take_screenshot` **requires** a `scale` argument (`"css"` or
  `"device"`), even though the schema claims a default.
- Omit `filename` on screenshots so they land in the artifact directory; an
  explicit name resolves against the session cwd and litters the repo.

### Optional: pinned browser instead of system Chrome

The default uses your installed Chrome. For a fully reproducible browser:

```bash
npx @playwright/mcp install-browser chrome-for-testing   # ~150 MB, one time; version pinned in the wrapper
```

Then add `"--browser", "chromium"` to the `args` in `~/.pi/agent/mcp.json`.
Trade-off: UAT then runs against a Playwright-managed Chromium build rather than
the browser you actually use.

## Useful Pi commands

Welcome update notices only appear for major/minor updates, not patches. Toggle them with:

```txt
/welcome updates on
/welcome updates off
```

Review files changed by Pi before keeping or reverting them:

```txt
/filechanges          # inspect tracked edit/write changes and diffs
/filechanges-accept   # keep files and clear the log
/filechanges-decline  # revert tracked changes
```

In non-interactive print/json mode, accept/decline require `force`.

## VS Code terminal keys

Pi's TUI reserves some modified keys before any extension sees them, and the VS Code
integrated terminal reserves some before Pi sees them. Two consequences worth knowing:

- **`ctrl+shift+d` is Pi's global debug dump.** `pi-tui` handles `shift+ctrl+d` in
  `handleTerminalInput` before the focused component, so it writes
  `~/.pi/agent/pi-debug.log` and no extension shortcut on that key can ever fire.
  The `filechanges` widget therefore collapses/expands on **`ctrl+alt+d`**.
- **VS Code owns modified keys in its terminal.** `ctrl+shift+d` is the default
  "Run and Debug" binding, so it never reaches the pty. `config/vscode-keybindings.json`
  forwards the keys Pi needs as Kitty sequences, scoped to `terminalFocus`:

  | Key | Sequence | Meaning |
  | --- | --- | --- |
  | `ctrl+alt+d` | `\u001b[100;7u` | `d` (100) with `ctrl+alt` (7) — toggles the filechanges widget |
  | `ctrl+shift+d` | `\u001b[100;6u` | `d` with `ctrl+shift` (6) — Pi's debug dump |

  `./install.sh --copy-config` merges these into the VS Code user `keybindings.json`
  without touching existing entries. Outside Pi, the same keys type the raw escape
  sequence into a plain shell — remove the bindings if that bothers you.

Verify what Pi actually receives with `/hotkeys` (registered shortcuts) and by pressing
the key: a working `ctrl+alt+d` toggles the `Δ N files (+x/-y)` line.

## tmux configuration

`home/` is a `$HOME` mirror for dotfiles that are not Pi config; today it holds one file. That is why the tmux config is
not in `config/`: that directory holds Pi's own templates (`vscode-keybindings.json` is the only exception, because the
merge step needs the snippet next to the settings it belongs to).

```bash
./install.sh --copy-config    # copies home/.tmux.conf -> ~/.tmux.conf
```

A plain `./install.sh` never touches it — `~/.tmux.conf` is not Pi's, so the only step
allowed to overwrite it is `--copy-config`, the same gate that overwrites
`~/.pi/agent/settings.json`. With `--backup` the previous file is saved under
`<backup>/home/` and `--revert` puts it back (removing `~/.tmux.conf` again if it did not
exist before). `./sync.sh` copies the live `~/.tmux.conf` back into `home/`; files are
captured only if the repo already tracks them, so a stray `~/.bashrc` is never swept in.
`./uninstall.sh` removes `~/.tmux.conf` only when it is still byte-identical to the repo
copy.

A native window (this tmux window) is captured per [docs/screenshots.md](docs/screenshots.md):
`import` cannot read the root window on KDE/Wayland, and spectacle's default mode is the whole
desktop — including other sessions — so pass `-a` and capture the one window. A web page goes to
the `browser-uat` skill instead, which screenshots through Playwright.

`tests/home-dotfiles.sh` covers that contract against throwaway `$HOME` directories — no
Docker, no network: plain install leaves the file alone, `--copy-config` keeps a `.bak`
before overwriting, `--backup` + `--revert` restore it (or delete what install created),
`--backup` without `--copy-config` records nothing, `uninstall.sh` keeps a modified copy,
and `sync.sh` commits a tracked dotfile while ignoring an untracked one.

What the config actually does (tmux 3.4, validated on a throwaway server before it landed
in the live one):

| Setting | Why |
| --- | --- |
| `set -g mouse on` | Replaces the four `mode-mouse` / `mouse-select-pane` / `mouse-resize-pane` / `mouse-select-window` options that tmux removed in 2.1 and that fail with `invalid option` on any current tmux. Click focuses a pane, click on the status bar switches windows, dragging a border resizes, wheel goes to the app when it asked for mouse (`less --mouse`, `vim set mouse=a`) and to copy-mode otherwise. `Shift`+drag is the escape hatch for the terminal's own selection, which mouse mode takes over |
| `set -g default-terminal "tmux-256color"` | `screen-256color` caps a pane at 256 colours. Panes created before the change keep their old `$TERM` until the server restarts |
| `set -as terminal-features 'xterm-kitty:RGB'` | Truecolor through the pane (needs the `tmux-256color` terminfo, present on Debian/Ubuntu via `ncurses-term`) |
| `set -as terminal-features 'xterm-kitty:extkeys'` + `set -g extended-keys on` | Pi's modified keys. tmux 3.4 has no CSI-u support, so it falls back to `modifyOtherKeys` and kitty prints a `PARSE ERROR … superseded by the kitty keyboard protocol` line — harmless, and tmux 3.5+ drops it |
| `set -g allow-passthrough on` | Kitty graphics (inline images) survive tmux |
| `bind -r m resize-pane -Z` | Zoom toggle; the old `tmp`-window swap trick loses the layout and is unnecessary since tmux 1.8 |
| `setw -g monitor-activity on` + `set -g visual-activity on` | Activity alerts in the status bar |
| `set -g status-justify centre` | Centre the window list. `center` is rejected as an unknown value; `absolute-centre` (3.2+) centres it against the terminal, not the status line |

Validate a change on a throwaway server before it touches the live one — `-L` gives it its own
socket, so nothing can leak into the session you are working in:

```bash
tmux -L cfgtest -f ~/.tmux.conf new-session -d -s t -x 200 -y 45   # -x/-y size it like a real client
tmux -L cfgtest show -gv mouse \; show -gv default-terminal        # what actually took effect
tmux -L cfgtest split-window -h 'less --mouse README.md'            # an app that asks for mouse events
tmux -L cfgtest list-panes -a -F '#{pane_id} active=#{pane_active} mouse=#{mouse_any_flag} #{pane_width}x#{pane_height}'
tmux -L cfgtest kill-server
```

`show -gv` proves the option parsed; `list-panes` proves the behaviour — `mouse_any_flag` turns `1`
only for the pane whose app asked for mouse events, which is what "the wheel reaches the app"
looks like from the outside. A detached session with a bare shell reports `0` everywhere, so the
split with `less --mouse` is what makes the check mean anything. A removed option fails loudly here (`invalid option: mode-mouse`)
instead of at the next attach.

## Do not commit

Never commit secrets or runtime state:

- `~/.pi/agent/auth.json`
- `~/.pi/agent/sessions/`
- `~/.pi/agent/npm/`
- `~/.pi/agent/git/`
- `~/.pi/agent/local-models.json` unless intentionally sanitized
- cache files such as `mcp-cache.json`

## References / Citations

References and inspirations.

- [Pi Packages](https://pi.dev/packages)
- [mattpocock/skills](https://github.com/mattpocock/skills)
- [Cursor pstack](https://github.com/cursor/plugins/tree/main/pstack) and
  [michael-denyer/pstack-claude](https://github.com/michael-denyer/pstack-claude) — see
  [docs/pstack-on-pi.md](docs/pstack-on-pi.md)
- [amosblomqvist/pi-config](https://github.com/amosblomqvist/pi-config)
- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [noonghunna/club-3090](https://github.com/noonghunna/club-3090)
- [r/LocalLLaMA](https://www.reddit.com/r/LocalLLaMA)

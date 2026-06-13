# Abhinand's Pi Setup

<p align="center">
  <img src="assets/featured.png" alt="Pi setup screenshot" width="800">
</p>

Personal `pi-setup` for [Pi coding agent](https://pi.dev): extensions, custom themes, skills, config examples, and sync tooling.

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
GitHub clone on another machine ->  ./install.sh --restore --copy-config  ->  ~/.pi/agent
```

Do **not** install this checkout as an active Pi package in normal use. Loading both `~/.pi/agent` and this repo causes duplicate skill/theme conflict warnings at startup. If you are editing Pi functionality while your shell is inside this repo, edit the live file under `~/.pi/agent/...` first, then run `pi-setup-sync` to copy it back here.

## What's included

- `bin/pi` — compact Pi launcher wrapper
  - one-line major/minor update notices instead of large startup boxes
  - preserves Pi's native themed header and loaded skills/extensions/themes listing
- `extensions/` — versioned copies of custom Pi extensions
  - themed startup welcome card
  - `/context` usage breakdown for startup tokens, messages, and tool calls (scrollback output; not added to model context)
  - `/filechanges` review/accept/decline workflow for Pi-made `edit`/`write` changes
  - custom footer with token usage and git branch
  - local model manager
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
  - diagnose, find-docs, find-skills, grill-me, grill-with-docs, handoff, hf-cli, improve-codebase-architecture, mcp-code-search, teach, write-a-skill
- `config/` — safe example config files

## Set up from GitHub on a machine

Clone the repo, then restore the live Pi setup from it:

```bash
git clone git@github.com:abhinand5/pi-setup.git ~/dev/ai-agents/pi-setup
cd ~/dev/ai-agents/pi-setup
./install.sh --restore --copy-config
```

For HTTPS:

```bash
git clone https://github.com/abhinand5/pi-setup.git ~/dev/ai-agents/pi-setup
cd ~/dev/ai-agents/pi-setup
./install.sh --restore --copy-config
```

`--restore` copies repo resources into `~/.pi/agent/extensions`, `~/.pi/agent/themes`, and `~/.pi/agent/skills`.

`--copy-config` copies `config/settings.example.json` and `config/mcp.example.json` into `~/.pi/agent/`.

Warnings:

- `--restore` replaces the current contents of those live resource directories.
- `--copy-config` overwrites `~/.pi/agent/settings.json` and `~/.pi/agent/mcp.json`.

## Install helper commands only

On a machine that already has the live files in `~/.pi/agent`, run:

```bash
./install.sh
```

This installs:

- `pi-setup-sync` into `~/.local/bin`
- compact launcher `bin/pi` into `~/.local/bin/pi`

It also removes any legacy settings entry that points Pi at this repo as an active package.

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

`pi-setup-sync` copies current `~/.pi/agent/extensions`, `~/.pi/agent/themes`, selected skills, `settings.json`, and `mcp.json` into this repo, validates JSON/theme tokens, commits, and pushes. It strips any self-referential package entry that would make Pi load this `pi-setup` repo at startup.

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
pi-setup-sync --skills hf-cli,diagnose "Back up selected skills"
pi-setup-sync --no-skills "Skip skill backup"
```

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

## Do not commit

Never commit secrets or runtime state:

- `~/.pi/agent/auth.json`
- `~/.pi/agent/sessions/`
- `~/.pi/agent/npm/`
- `~/.pi/agent/git/`
- `~/.pi/agent/local-models.json` unless intentionally sanitized
- cache files such as `mcp-cache.json`

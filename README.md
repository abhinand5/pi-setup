# Abhinand's Pi Setup

<p align="center">
  <img src="assets/featured.png" alt="Pi setup screenshot" width="800">
</p>

Personal reproducible setup for [Pi coding agent](https://pi.dev): extensions, custom themes, and safe configuration examples.

## What's included

- `bin/pi` — compact Pi launcher wrapper
  - one-line major/minor update notices instead of large startup boxes
  - preserves Pi's native themed header and loaded skills/extensions/themes listing
- `extensions/` — custom Pi extensions
  - themed startup welcome card
  - `/context` usage breakdown for startup tokens, messages, and tool calls (scrollback output; not added to model context)
  - `/filechanges` review/accept/decline workflow for Pi-made `edit`/`write` changes
  - custom footer with token usage and git branch
  - local model manager
  - thinking timer — animated `Thinking.` → `Thinking..` → `Thinking...` while the model reasons, then `💭 Thought for 3s` when it finishes
- `themes/` — polished custom themes
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
- `skills/` — portable copies of installed Pi skills
  - diagnose, find-docs, find-skills, grill-me, grill-with-docs, handoff, hf-cli, improve-codebase-architecture, mcp-code-search, teach, write-a-skill
- `config/` — safe example config files

## Install from GitHub

After pushing this repo to GitHub, install it with one of these:

```bash
pi install git:https://github.com/abhinand5/pi-setup
```

or private SSH:

```bash
pi install git:git@github.com:abhinand5/pi-setup
```

Then restart Pi or run:

```txt
/reload
```

## Install from a local checkout

```bash
./install.sh
```

To also copy the example settings into `~/.pi/agent/`:

```bash
./install.sh --copy-config
```

Warning: `--copy-config` overwrites `~/.pi/agent/settings.json` and `~/.pi/agent/mcp.json`.

## Recreate config manually

```bash
mkdir -p ~/.pi/agent
cp config/settings.example.json ~/.pi/agent/settings.json
cp config/mcp.example.json ~/.pi/agent/mcp.json
pi install git:https://github.com/abhinand5/pi-setup
```

## Do not commit

Never commit secrets or runtime state:

- `~/.pi/agent/auth.json`
- `~/.pi/agent/sessions/`
- `~/.pi/agent/npm/`
- `~/.pi/agent/git/`
- `~/.pi/agent/local-models.json` unless intentionally sanitized
- cache files such as `mcp-cache.json`

## Syncing future tweaks

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

`./install.sh` also runs `./setup_sync.sh` automatically and installs the compact `pi` launcher to `~/.local/bin/pi`.

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

Custom commit message:

```bash
pi-setup-sync "Update themes and footer"
```

Commit without pushing:

```bash
pi-setup-sync --no-push "Checkpoint local Pi setup"
```

The sync command copies current `~/.pi/agent/extensions`, `~/.pi/agent/themes`, selected skills, `settings.json`, and `mcp.json` into this repo, validates JSON/theme tokens, commits, and pushes.

Skill backup scans `~/.pi/agent/skills` and `~/.agents/skills`, resolves symlinks, dedupes duplicates, and stores portable copies in `skills/`. All skills are selected by default; press Enter at the selector to accept all in one keystroke. To customize, use ↑/↓ to move, Space to toggle, `a` for all, `n` for none, and Enter to continue.

Non-interactive options:

```bash
pi-setup-sync --all-skills
pi-setup-sync --skills hf-cli,diagnose "Back up selected skills"
pi-setup-sync --no-skills "Skip skill backup"
```

## Applying updates on another machine

```bash
pi update git:https://github.com/abhinand5/pi-setup
```

or just:

```bash
pi update --extensions
```

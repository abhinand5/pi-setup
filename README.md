# Abhinand's Pi Setup

Personal reproducible setup for [Pi coding agent](https://pi.dev): extensions, custom themes, and safe configuration examples.

## What's included

- `extensions/` — custom Pi extensions
  - startup welcome card
  - custom footer
  - context command
  - local model manager
- `themes/` — polished custom themes
  - `nebula-pulse` *(current default)*
  - `tokyo-night`
  - `one-dark-pro`
  - `dracula`
  - `catppuccin-mocha`
  - `nord`
  - `gruvbox`
  - `rose-pine`
  - `synthwave-84`
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

`./install.sh` also runs `./setup_sync.sh` automatically.

Custom commit message:

```bash
pi-setup-sync "Update themes and footer"
```

Commit without pushing:

```bash
pi-setup-sync --no-push "Checkpoint local Pi setup"
```

The sync command copies current `~/.pi/agent/extensions`, `~/.pi/agent/themes`, `settings.json`, and `mcp.json` into this repo, validates JSON/theme tokens, commits, and pushes.

## Applying updates on another machine

```bash
pi update git:https://github.com/abhinand5/pi-setup
```

or just:

```bash
pi update --extensions
```

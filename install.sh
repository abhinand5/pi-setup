#!/usr/bin/env bash
set -euo pipefail

# Install helper commands for this pi-setup repo.
#
# ~/.pi/agent is the live Pi setup. This repo is the versioned pi-setup copy
# used to back up that live setup to GitHub and recreate it on any machine.
#
# Usage:
#   ./install.sh                         # install sync helper + compact launcher only
#   ./install.sh --copy-config           # also overwrite ~/.pi/agent/settings.json and mcp.json,
#                                        # overwrite AGENTS.md/pi-pstack-adapter.json when
#                                        # restoring, copy the home/ dotfiles (e.g. ~/.tmux.conf),
#                                        # and merge config/vscode-keybindings.json
#   ./install.sh --restore               # also restore extensions/themes/skills from this repo
#   ./install.sh --restore --dry-run     # preview changes without writing files
#   ./install.sh --restore --backup      # save current live files before replacing them
#   ./install.sh --revert <backup-dir>   # restore a backup created by --backup

REPO_URL="${PI_SETUP_REPO_URL:-https://github.com/abhinand5/pi-setup.git}"
DEFAULT_CHECKOUT="${PI_SETUP_CHECKOUT:-$HOME/dev/ai-agents/pi-setup}"

# One-line installer mode: when this script is run from curl/bash instead of a
# checkout, clone/update the repo and re-exec the real script from there.
if [[ -z "${PI_SETUP_BOOTSTRAPPED:-}" ]]; then
  SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd || pwd)"
  if [[ ! -f "$SCRIPT_DIR/sync.sh" || ! -d "$SCRIPT_DIR/extensions" || ! -d "$SCRIPT_DIR/themes" ]]; then
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
      : # fall through to local usage when possible
    else
      if [[ -d "$DEFAULT_CHECKOUT/.git" ]]; then
        echo "Using existing pi-setup checkout: $DEFAULT_CHECKOUT"
        git -C "$DEFAULT_CHECKOUT" pull --ff-only
      else
        echo "Cloning pi-setup into: $DEFAULT_CHECKOUT"
        mkdir -p "$(dirname "$DEFAULT_CHECKOUT")"
        git clone "$REPO_URL" "$DEFAULT_CHECKOUT"
      fi
      export PI_SETUP_BOOTSTRAPPED=1
      exec "$DEFAULT_CHECKOUT/install.sh" "$@"
    fi
  fi
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_HOME="${PI_HOME:-$HOME/.pi/agent}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
COPY_CONFIG=0
RESTORE=0
DRY_RUN=0
FORCE=0
BACKUP=0
BACKUP_DIR=""
REVERT_DIR=""

usage() {
  cat <<'EOF'
Install helper commands for this pi-setup repo.

~/.pi/agent is the live Pi setup. This repo is the versioned pi-setup copy
used to back up that live setup to GitHub and recreate it on any machine.

Usage:
  ./install.sh                         # install sync helper + compact launcher only
  ./install.sh --copy-config           # also overwrite ~/.pi/agent/settings.json and mcp.json,
                                       # overwrite AGENTS.md/pi-pstack-adapter.json when
                                       # restoring, copy the home/ dotfiles (~/.tmux.conf),
                                       # and merge config/vscode-keybindings.json
  ./install.sh --restore               # also restore extensions/themes/skills into ~/.pi/agent
  ./install.sh --restore --dry-run     # preview changes without writing files
  ./install.sh --restore --backup      # save current live files before replacing them
  ./install.sh --revert <backup-dir>   # restore a backup created by --backup

One-line install from GitHub:
  curl -fsSL https://raw.githubusercontent.com/abhinand5/pi-setup/main/install.sh | bash -s -- --restore --backup

Options:
  --dry-run       Print what would change without writing files.
  --backup        Back up current live Pi files before restore/config overwrite.
  --no-backup     Explicitly skip backup prompts/policy; useful in scripts.
  --revert DIR    Restore extensions/themes/skills/settings/mcp from a backup dir.
  --force         Overwrite a live copy that has edits of its own (the two-copy guard refuses
                  such a write: run ./sync.sh to bring them into the repo instead).

Browser automation (playwright MCP) is checked but never installed automatically.
If prerequisites are missing, install.sh only prints the commands to run.
The browser runs on a private Xvfb display, so it never steals window focus.

Recommended: install the Pi CLI first. The compact launcher wraps an existing
Pi binary and will look in /usr/local/bin/pi, /usr/bin/pi, /opt/homebrew/bin/pi,
or PI_REAL_BIN.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy-config)
      COPY_CONFIG=1
      shift
      ;;
    --restore)
      RESTORE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --backup)
      BACKUP=1
      shift
      ;;
    --no-backup)
      BACKUP=0
      shift
      ;;
    --revert)
      REVERT_DIR="${2:?missing backup directory for --revert}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Сторож двух копий: файл, у которого есть свои правки в живой копии, без --force валит restore
# с diff-ом, а не теряется молча (#15838 п.7).
# shellcheck source=scripts/lib/two-copy-guard.sh
source "$ROOT/scripts/lib/two-copy-guard.sh"

# diff_lines <repo-копия> <живая>: сколько строк разошлось — одной строкой в предупреждение.
diff_lines() {
  local a d _
  while read -r a d _; do
    printf '+%s −%s строк' "$a" "$d"
    return 0
  done < <(git -C "$ROOT" diff --numstat --no-index -- "$1" "$2" 2>/dev/null || true)
  printf 'размер не посчитан'
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'would run: '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

copy_path() {
  local src="$1" dst="$2"
  if [[ -d "$src" ]]; then
    run mkdir -p "$dst"
    run cp -R "$src"/. "$dst"/
  elif [[ -f "$src" ]]; then
    run mkdir -p "$(dirname "$dst")"
    run cp "$src" "$dst"
  fi
}

# Сторож двух копий идёт до первой записи: живая копия может нести собственные правки, и restore
# перезаписал бы их молча (#15836 п.2, #15838 п.7).
# --revert пишет из каталога бэкапа, а не из репозитория: две копии тут не при чём.
if [[ -z "$REVERT_DIR" && ( "$RESTORE" == "1" || "$COPY_CONFIG" == "1" ) ]]; then
  # Сверяем только то, что этот запуск действительно пишет: --restore не трогает AGENTS.md и
  # ~/.tmux.conf, --copy-config не трогает skills/themes/extensions.
  if [[ "$RESTORE" == "1" && "$COPY_CONFIG" == "1" ]]; then
    dg_mode=all
  elif [[ "$RESTORE" == "1" ]]; then
    dg_mode=restore
  else
    dg_mode=copy-config
  fi
  dg_standard_pairs live "$dg_mode"
  if [[ "$DRY_RUN" == "1" ]]; then
    dg_report dry-run
  else
    dg_report install "two-copy guard: перенесите правку в репозиторий (./sync.sh) или перезапишите осознанно: --force"
  fi
fi

copy_dir_contents() {
  local src="$1"
  local dst="$2"
  [[ -d "$src" ]] || return 0
  run mkdir -p "$dst"
  run find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf '{}' +
  run cp -R "$src"/. "$dst"/
}

# AGENTS.md holds always-on instructions for every Pi session, and
# pi-pstack-adapter.json pins every pstack role and panel to a model id the provider
# actually serves (with the roles unset the adapter passes `pstack:<role>` and the
# child inherits the parent's model, which is how a delegation escaped the workspace
# cap). Both can carry machine-local rules, so restore each only when the live copy
# is absent; --restore --copy-config asks for the overwrite.
install_config_if_absent() {
  local src="$1"
  local dst="$2"
  local label="$3"
  [[ -f "$src" ]] || return 0
  if [[ -f "$dst" && "$COPY_CONFIG" != "1" ]]; then
    if cmp -s "$src" "$dst"; then
      echo "$label is up to date."
    else
      echo "$label differs from the repo copy ($(diff_lines "$src" "$dst")); leaving it (use --restore --copy-config to overwrite)."
    fi
    return 0
  fi
  copy_path "$src" "$dst"
}

# Merge config/models.example.json into the live models.json instead of replacing it.
# models.json holds machine-specific providers (API keys, custom endpoints), so a
# straight copy would destroy them; only the example's keys are overlaid.
merge_models_example() {
  local example="$ROOT/config/models.example.json"
  local live="$PI_HOME/models.json"
  [[ -f "$example" ]] || return 0

  if [[ ! -f "$live" ]]; then
    copy_path "$example" "$live"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would merge config/models.example.json into $live (existing providers kept)"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  if command -v jq >/dev/null 2>&1; then
    if jq -s '.[0] * .[1]' "$live" "$example" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$live"
      echo "Merged the OpenRouter vendor pin into $live"
      return 0
    fi
  elif command -v node >/dev/null 2>&1; then
    if node - "$live" "$example" >"$tmp" <<'JS'
const fs = require("fs");
const [livePath, examplePath] = process.argv.slice(2);
const merge = (base, extra) => {
  for (const [key, value] of Object.entries(extra)) {
    if (value && typeof value === "object" && !Array.isArray(value) &&
        base[key] && typeof base[key] === "object" && !Array.isArray(base[key])) {
      merge(base[key], value);
    } else {
      base[key] = value;
    }
  }
  return base;
};
const data = merge(JSON.parse(fs.readFileSync(livePath, "utf8")), JSON.parse(fs.readFileSync(examplePath, "utf8")));
process.stdout.write(JSON.stringify(data, null, 2) + "\n");
JS
    then
      mv "$tmp" "$live"
      echo "Merged the OpenRouter vendor pin into $live"
      return 0
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if python3 - "$live" "$example" >"$tmp" <<'PY'
import json
import sys
from pathlib import Path

def merge(base, extra):
    for key, value in extra.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value
    return base

live = Path(sys.argv[1])
data = json.loads(live.read_text())
merge(data, json.loads(Path(sys.argv[2]).read_text()))
print(json.dumps(data, indent=2))
PY
    then
      mv "$tmp" "$live"
      echo "Merged the OpenRouter vendor pin into $live"
      return 0
    fi
  fi
  rm -f "$tmp"
  echo "note: could not merge config/models.example.json into $live; add providers.openrouter.modelOverrides manually"
}

# Relative paths of the dotfiles the repo owns, one per line. Command substitution (not
# `find … < <( )`) so a failed walk is visible: `set -e` covers `$( )`, not process
# substitution. Install/backup/revert act on filesystem presence on purpose — a restore
# runs on a machine where home/ is the only thing that exists yet. sync.sh is the one step
# that has to follow git tracking instead, because it is the step that commits and pushes.
home_dotfile_rels() {
  [[ -d "$ROOT/home" ]] || return 0
  (cd "$ROOT/home" && find . -type f) | sed 's|^\./||' | LC_ALL=C sort
}

make_backup() {
  if [[ "$BACKUP" != "1" || "$DRY_RUN" == "1" ]]; then
    [[ "$BACKUP" == "1" && "$DRY_RUN" == "1" ]] && echo "would create backup under $PI_HOME/backups/"
    return 0
  fi

  BACKUP_DIR="$PI_HOME/backups/pi-setup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"

  for name in extensions themes skills; do
    if [[ -d "$PI_HOME/$name" ]]; then
      mkdir -p "$BACKUP_DIR/$name"
      cp -R "$PI_HOME/$name"/. "$BACKUP_DIR/$name"/
    else
      touch "$BACKUP_DIR/.absent-$name"
    fi
  done
  for name in settings.json mcp.json playwright-mcp.json models.json pi-pstack-adapter.json; do
    if [[ -f "$PI_HOME/$name" ]]; then
      cp "$PI_HOME/$name" "$BACKUP_DIR/$name"
    else
      touch "$BACKUP_DIR/.absent-$name"
    fi
  done
  # Policy files that --restore may overwrite: AGENTS.md and the allowed-model
  # table it points at. The table is overwritten unconditionally (a stale table
  # loses delegation runs), so a local edit has to be revertible (#15647).
  for name in AGENTS.md docs/delegation-models.md docs/session-logs.md; do
    if [[ -f "$PI_HOME/$name" ]]; then
      mkdir -p "$BACKUP_DIR/$(dirname "$name")"
      cp "$PI_HOME/$name" "$BACKUP_DIR/$name"
    else
      touch "$BACKUP_DIR/.absent-$(basename "$name")"
    fi
  done
  # Dotfiles from home/ mirror $HOME, so they sit outside $PI_HOME. Only --copy-config
  # writes them, so only that combination has pre-install state worth keeping: recording
  # them on a plain --backup would let a later --revert delete a file this run never wrote.
  # The manifest is what revert reads, so a dotfile dropped from the repo afterwards still
  # has its pre-install copy.
  if [[ "$COPY_CONFIG" == "1" ]]; then
    local rels rel
    rels="$(home_dotfile_rels)"
    : >"$BACKUP_DIR/home-manifest.txt"
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      if [[ -f "$HOME/$rel" ]]; then
        mkdir -p "$BACKUP_DIR/home/$(dirname "$rel")"
        cp "$HOME/$rel" "$BACKUP_DIR/home/$rel"
        echo "present $rel" >>"$BACKUP_DIR/home-manifest.txt"
      else
        echo "absent $rel" >>"$BACKUP_DIR/home-manifest.txt"
      fi
    done <<<"$rels"
  fi

  cat >"$BACKUP_DIR/MANIFEST.txt" <<EOF
pi-setup backup
created: $(date -Is)
source: $PI_HOME
repo: $ROOT
revert: $ROOT/install.sh --revert "$BACKUP_DIR"
EOF
  echo "Created backup: $BACKUP_DIR"
}

revert_backup() {
  local backup="$1"
  if [[ ! -d "$backup" ]]; then
    echo "error: backup directory not found: $backup" >&2
    exit 1
  fi

  echo "Reverting live Pi setup from backup: $backup"
  for name in extensions themes skills; do
    if [[ -d "$backup/$name" ]]; then
      copy_dir_contents "$backup/$name" "$PI_HOME/$name"
    elif [[ -f "$backup/.absent-$name" ]]; then
      echo "Removing $PI_HOME/$name because it was absent when the backup was created."
      run rm -rf "$PI_HOME/$name"
    else
      echo "Backup has no $name/ state; leaving $PI_HOME/$name unchanged."
    fi
  done
  for name in settings.json mcp.json playwright-mcp.json models.json pi-pstack-adapter.json AGENTS.md docs/delegation-models.md docs/session-logs.md; do
    if [[ -f "$backup/$name" ]]; then
      copy_path "$backup/$name" "$PI_HOME/$name"
    elif [[ -f "$backup/.absent-$(basename "$name")" ]]; then
      echo "Removing $PI_HOME/$name because it was absent when the backup was created."
      run rm -f "$PI_HOME/$name"
    else
      echo "Backup has no $name state; leaving $PI_HOME/$name unchanged."
    fi
  done
  if [[ -f "$backup/home-manifest.txt" ]]; then
    local state rel
    while IFS=' ' read -r state rel; do
      [[ -n "$state" && -n "$rel" ]] || continue
      if [[ "$state" == "present" && -f "$backup/home/$rel" ]]; then
        copy_path "$backup/home/$rel" "$HOME/$rel"
      elif [[ "$state" == "absent" ]]; then
        echo "Removing $HOME/$rel because it was absent when the backup was created."
        run rm -f "$HOME/$rel"
      else
        echo "Backup has no home/$rel state; leaving $HOME/$rel unchanged."
      fi
    done <"$backup/home-manifest.txt"
  fi
  echo "Revert complete. Restart Pi or run /reload in an existing session."
}

install_vscode_keybindings() {
  local snippet="$ROOT/config/vscode-keybindings.json"
  [[ -f "$snippet" ]] || return 0

  local target
  if [[ -n "${VSCODE_KEYBINDINGS:-}" ]]; then
    target="$VSCODE_KEYBINDINGS"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    target="$HOME/Library/Application Support/Code/User/keybindings.json"
  else
    target="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User/keybindings.json"
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Skipping VS Code keybindings: python3 not found. Snippet: $snippet"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would merge $snippet into $target"
    return 0
  fi

  python3 - "$snippet" "$target" <<'PY'
import json
import shutil
import sys
import time
from pathlib import Path

snippet_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
entries = json.loads(snippet_path.read_text(encoding="utf-8"))
if not isinstance(entries, list):
    sys.exit(f"error: {snippet_path} must contain a JSON array")

if not target_path.exists():
    target_path.parent.mkdir(parents=True, exist_ok=True)
    target_path.write_text(json.dumps(entries, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"created {target_path} with {len(entries)} binding(s)")
    raise SystemExit(0)

text = target_path.read_text(encoding="utf-8")


def already_present(entry, haystack):
    # The same sequence may be stored raw (ESC byte) or escaped (\u001b).
    raw = entry["args"]["text"]
    escaped = json.dumps(raw)[1:-1]
    return raw in haystack or escaped in haystack


missing = [e for e in entries if not already_present(e, text)]
if not missing:
    print(f"{target_path}: VS Code keybindings already present")
    raise SystemExit(0)

index = text.find("[")
if index == -1:
    print(f"warning: {target_path} has no JSON array; add these bindings manually:")
    print(json.dumps(missing, indent=4, ensure_ascii=False))
    raise SystemExit(0)

backup = target_path.with_name(target_path.name + ".bak-" + time.strftime("%Y%m%dT%H%M%S"))
shutil.copy2(target_path, backup)
block = "".join(
    "    " + json.dumps(e, indent=4, ensure_ascii=False).replace("\n", "\n    ") + ",\n"
    for e in missing
)
target_path.write_text(text[: index + 1] + "\n" + block + text[index + 1 :], encoding="utf-8")
print(f"added {len(missing)} binding(s) to {target_path} (backup: {backup.name})")
PY
}

remove_legacy_package_reference() {
  local settings="$PI_HOME/settings.json"
  [[ -f "$settings" ]] || return 0

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Skipping legacy package-reference cleanup: python3 not found."
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would remove legacy active package references to $ROOT from $settings"
    return 0
  fi

  python3 - <<'PY' "$settings" "$ROOT"
import json
import sys
from pathlib import Path

settings = Path(sys.argv[1])
root = Path(sys.argv[2]).resolve()
try:
    data = json.loads(settings.read_text())
except Exception as exc:
    raise SystemExit(f"error: failed to parse {settings}: {exc}")

packages = data.get("packages")
if not isinstance(packages, list):
    raise SystemExit(0)

changed = False
kept = []
for item in packages:
    source = item.get("source") if isinstance(item, dict) else item
    remove = False
    if isinstance(source, str) and not source.startswith(("npm:", "git:", "http://", "https://", "ssh://")):
        try:
            candidate = (settings.parent / source).expanduser().resolve()
        except Exception:
            candidate = None
        remove = candidate == root
    if remove:
        changed = True
    else:
        kept.append(item)

if changed:
    data["packages"] = kept
    settings.write_text(json.dumps(data, indent=2) + "\n")
    print(f"Removed legacy active package reference to {root} from {settings}")
PY
}

check_browser_prereqs() {
  # Non-fatal, advisory only: the playwright MCP server needs Node/npx, an
  # installed browser, and Xvfb for the private display. Missing pieces never
  # break Pi itself, only browser UAT, so this never fails the install.
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would check browser automation prerequisites (npx, browser, Xvfb)"
    return 0
  fi

  local missing=0

  if ! command -v npx >/dev/null 2>&1; then
    echo "note: npx not found. The playwright MCP server needs Node.js:"
    echo "        install Node, then restart Pi so the server can start."
    missing=1
  fi

  local browser_found=0
  for candidate in google-chrome google-chrome-stable chromium chromium-browser; do
    command -v "$candidate" >/dev/null 2>&1 && browser_found=1 && break
  done
  if [[ "$browser_found" == "0" ]]; then
    # shellcheck disable=SC2086
    compgen -G "$HOME/.cache/ms-playwright/chromium-*" >/dev/null 2>&1 && browser_found=1
  fi
  if [[ "$browser_found" == "0" ]]; then
    echo "note: no Chrome/Chromium found for browser UAT. Install one of:"
    echo "        sudo apt install chromium-browser   # or Google Chrome"
    echo "        npx playwright install chromium"
    missing=1
  fi

  if ! command -v Xvfb >/dev/null 2>&1; then
    echo "note: Xvfb not found. Browser UAT will fall back to headless."
    echo "        sudo apt install xvfb   # keeps the browser off your desktop"
  fi

  local wrapper="$PI_HOME/skills/browser-uat/scripts/playwright-mcp-xvfb.sh"
  if [[ ! -x "$wrapper" ]]; then
    echo "note: the browser-uat wrapper is not installed at $wrapper"
    echo "        run ./install.sh --restore, then: $ROOT/skills/browser-uat/scripts/uat.sh config install"
    missing=1
  fi

  if [[ "$missing" == "0" ]]; then
    echo "Browser automation prerequisites look good. Verify with:"
    echo "  $PI_HOME/skills/browser-uat/scripts/uat.sh doctor"
  fi
}

if [[ -n "$REVERT_DIR" ]]; then
  revert_backup "$REVERT_DIR"
  exit 0
fi

run mkdir -p "$PI_HOME"
make_backup
remove_legacy_package_reference

if [[ "$RESTORE" == "1" ]]; then
  echo "Restoring repo resources into live Pi home: $PI_HOME"
  copy_dir_contents "$ROOT/extensions" "$PI_HOME/extensions"
  copy_dir_contents "$ROOT/themes" "$PI_HOME/themes"
  copy_dir_contents "$ROOT/skills" "$PI_HOME/skills"
  install_config_if_absent "$ROOT/config/AGENTS.md" "$PI_HOME/AGENTS.md" "AGENTS.md"
  # The allowed-model table AGENTS.md points at. Policy, not machine-local
  # config, so restore overwrites it: a stale table is what loses a delegation
  # run. make_backup keeps a copy of the previous one, so --revert brings a local
  # edit back (#15647).
  if [[ -f "$ROOT/config/delegation-models.md" ]]; then
    copy_path "$ROOT/config/delegation-models.md" "$PI_HOME/docs/delegation-models.md"
  else
    echo "warning: $ROOT/config/delegation-models.md is missing — the allowed-model table was not restored"
  fi
  # Recipes for reading session logs; the retro skill points at this page, and a
  # skill that points nowhere is worse than no pointer (#15807).
  if [[ -f "$ROOT/config/session-logs.md" ]]; then
    copy_path "$ROOT/config/session-logs.md" "$PI_HOME/docs/session-logs.md"
  else
    echo "warning: $ROOT/config/session-logs.md is missing — the session-log recipes were not restored"
  fi
  # The table is useless if nothing points at it: AGENTS.md is restored only when
  # absent, so an older live copy may have no pointer.
  if [[ -f "$PI_HOME/AGENTS.md" ]] && ! grep -q "docs/delegation-models.md" "$PI_HOME/AGENTS.md"; then
    echo "warning: $PI_HOME/AGENTS.md does not point to docs/delegation-models.md — the restored table will not be read (run --restore --copy-config to take the repo copy)"
  fi
  install_config_if_absent "$ROOT/config/pi-pstack-adapter.example.json" "$PI_HOME/pi-pstack-adapter.json" "pi-pstack-adapter.json"
  if compgen -G "$ROOT/skills/browser-uat/scripts/*.sh" >/dev/null; then
    run chmod +x "$PI_HOME/skills/browser-uat/scripts/"*.sh
  fi
else
  echo "Skipping resource restore. To copy repo resources into $PI_HOME, run: ./install.sh --restore"
fi

if [[ "$COPY_CONFIG" == "1" ]]; then
  echo "Copying example config into $PI_HOME/"
  copy_path "$ROOT/config/settings.example.json" "$PI_HOME/settings.json"
  if [[ -f "$ROOT/config/mcp.example.json" ]]; then
    copy_path "$ROOT/config/mcp.example.json" "$PI_HOME/mcp.json"
    wrapper_path="$PI_HOME/skills/browser-uat/scripts/playwright-mcp-xvfb.sh"
    wrapper_display="$wrapper_path"
    if [[ "$wrapper_path" == "$HOME"/* ]]; then
      wrapper_display="~/${wrapper_path#"$HOME"/}"
    fi
    if command -v jq >/dev/null 2>&1; then
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "would rewrite .mcpServers.playwright.command in $PI_HOME/mcp.json to $wrapper_display"
      else
        mcp_tmp="$(mktemp)"
        if jq --arg cmd "$wrapper_display" '.mcpServers.playwright.command = $cmd' "$PI_HOME/mcp.json" >"$mcp_tmp" 2>/dev/null; then
          mv "$mcp_tmp" "$PI_HOME/mcp.json"
        else
          rm -f "$mcp_tmp"
          echo "note: could not rewrite $PI_HOME/mcp.json; set .mcpServers.playwright.command to $wrapper_display manually"
        fi
      fi
    elif command -v python3 >/dev/null 2>&1; then
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "would rewrite .mcpServers.playwright.command in $PI_HOME/mcp.json to $wrapper_display"
      elif python3 - "$PI_HOME/mcp.json" "$wrapper_display" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
command = sys.argv[2]
data = json.loads(path.read_text())
data.setdefault("mcpServers", {}).setdefault("playwright", {})["command"] = command
path.write_text(json.dumps(data, indent=2) + "\n")
PY
      then
        :
      else
        echo "note: could not rewrite $PI_HOME/mcp.json; set .mcpServers.playwright.command to $wrapper_display manually"
      fi
    else
      echo "note: jq and python3 not found; leaving $PI_HOME/mcp.json unchanged. Set .mcpServers.playwright.command to $wrapper_display manually."
    fi
  fi
  if [[ ! -x "$PI_HOME/skills/browser-uat/scripts/playwright-mcp-xvfb.sh" ]]; then
    copy_dir_contents "$ROOT/skills/browser-uat/scripts" "$PI_HOME/skills/browser-uat/scripts"
    run chmod +x "$PI_HOME/skills/browser-uat/scripts/playwright-mcp-xvfb.sh" \
      "$PI_HOME/skills/browser-uat/scripts/uat.sh"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "would install the browser-uat wrapper so the mcp.json playwright entry can spawn."
    else
      echo "Installed the browser-uat wrapper so the mcp.json playwright entry can spawn."
    fi
  fi
  if [[ -f "$ROOT/config/micme.example.json" ]]; then
    copy_path "$ROOT/config/micme.example.json" "$PI_HOME/micme.json"
  fi
  if [[ -f "$ROOT/config/playwright-mcp.json" ]]; then
    copy_path "$ROOT/config/playwright-mcp.json" "$PI_HOME/playwright-mcp.json"
  fi
  merge_models_example
  install_vscode_keybindings
  remove_legacy_package_reference
else
  echo "Skipping config copy. To copy settings/mcp examples, run: ./install.sh --copy-config"
fi

check_browser_prereqs

if [[ "$DRY_RUN" == "1" ]]; then
  echo "would run: $ROOT/setup_sync.sh"
else
  "$ROOT/setup_sync.sh"
fi

# Pi reinstalls npm packages on `pi install` / `pi update --extensions`, which
# reverts local patches to them. Re-apply ours here; each script is idempotent
# and skips packages that are not installed.
apply_local_patches() {
  local patch_script
  for patch_script in "$ROOT"/patches/*.sh; do
    [[ -f "$patch_script" ]] || continue
    [[ -x "$patch_script" ]] || chmod +x "$patch_script"
    if [[ "$DRY_RUN" == "1" ]]; then
      "$patch_script" --dry-run || true
    else
      "$patch_script"
    fi
  done
}

apply_local_patches

is_our_launcher() {
  grep -q "Personal Pi launcher" "$1" 2>/dev/null
}

# Find a real Pi binary, ignoring our own launcher at $BIN_DIR/pi.
find_real_pi() {
  local candidate launcher
  launcher="$(readlink -f "$BIN_DIR/pi" 2>/dev/null || printf '%s\n' "$BIN_DIR/pi")"

  if [[ -n "${PI_REAL_BIN:-}" && -x "${PI_REAL_BIN}" ]]; then
    printf '%s\n' "$PI_REAL_BIN"
    return 0
  fi
  for candidate in /usr/local/bin/pi /usr/bin/pi /opt/homebrew/bin/pi; do
    [[ -x "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  while IFS= read -r candidate; do
    [[ -x "$candidate" ]] || continue
    [[ "$(readlink -f "$candidate" 2>/dev/null || printf '%s\n' "$candidate")" == "$launcher" ]] && continue
    printf '%s\n' "$candidate"
    return 0
  done < <(type -P -a pi 2>/dev/null || true)
  return 1
}

install_launcher() {
  local src="$ROOT/bin/pi"
  local dst="$BIN_DIR/pi"
  local replaced_target=""

  [[ -f "$src" ]] || return 0
  run mkdir -p "$BIN_DIR"

  # Never copy onto whatever is already at $dst: cp follows symlinks and writes
  # *through* them, so installing over a symlink that points at the real Pi
  # binary would overwrite Pi's own executable with this shell script. Unlink
  # first so the copy always creates a fresh regular file.
  if [[ -e "$dst" || -L "$dst" ]]; then
    if ! is_our_launcher "$dst"; then
      replaced_target="$(readlink -f "$dst" 2>/dev/null || printf '%s\n' "$dst")"
      echo "Note: replacing existing $dst (resolves to $replaced_target)"
    fi
    run rm -f "$dst"
  fi

  run cp "$src" "$dst"
  run chmod +x "$dst"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "would install compact Pi launcher: $dst"
  else
    echo "Installed compact Pi launcher: $dst"
  fi

  local real_pi
  real_pi="$(find_real_pi || true)"
  if [[ -z "$real_pi" ]]; then
    echo "Warning: no existing Pi binary found. Install Pi first, or set PI_REAL_BIN before running the launcher."
    if [[ -n "$replaced_target" && -x "$replaced_target" ]]; then
      echo "         $dst previously pointed at $replaced_target; set PI_REAL_BIN='$replaced_target' to keep using it."
    fi
  elif [[ "$real_pi" != /usr/local/bin/pi && "$real_pi" != /usr/bin/pi && "$real_pi" != /opt/homebrew/bin/pi ]]; then
    # Found only via PATH (e.g. an nvm/npm global). That PATH entry may be absent
    # in a fresh shell, which would leave the launcher unable to resolve Pi.
    echo "Note: Pi resolved via PATH at $real_pi."
    echo "      If that directory is not on PATH in every shell, set PI_REAL_BIN='$real_pi'."
  fi
}

install_launcher

# Куда указывать симлинки ~/.local/bin. Обычно это сам чекаут, но из связанного воркдерева
# ($ROOT/.git — файл) путь внутри него исчезает вместе с деревом, а симлинк остаётся битым:
# 20.11.2026 restore, запущенный из ~/p/pi-setup-wt/<задача>, переключил симлинки rg, ru-spellcheck,
# pi-models-check и redmine-file внутрь воркдерева, который убирают сразу после мержа PR (#15838 п.7
# — та же ловушка, что «не копируй воркдерево в /tmp»). Поэтому цель симлинка — основное дерево из
# `git worktree list`, а содержимое скиллов/расширений по-прежнему берётся из $ROOT.
bin_link_root() {
  if [[ ! -f "$ROOT/.git" ]]; then
    printf '%s\n' "$ROOT"
    return 0
  fi
  local main_root
  main_root="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)"
  printf '%s\n' "${main_root:-$ROOT}"
}

# pi-models-check probes every id in subagents.modelScope.allow so "the catalog
# lists it" is never mistaken for "the provider serves it".
install_bin_helpers() {
  local src dst name link_root
  link_root="$(bin_link_root)"
  if [[ "$link_root" != "$ROOT" ]]; then
    echo "Note: $ROOT — связанное воркдерево; $BIN_DIR/* будет указывать на основное дерево $link_root,"
    echo "      чтобы симлинки не умерли вместе с воркдеревом после мержа."
  fi
  for src in "$ROOT"/bin/*; do
    [[ -f "$src" ]] || continue
    name="$(basename "$src")"
    [[ "$name" == "pi" ]] && continue
    dst="$BIN_DIR/$name"
    if [[ "$link_root" != "$ROOT" && ! -f "$link_root/bin/$name" ]]; then
      echo "Warning: $link_root/bin/$name нет — симлинк $name не ставлю (в воркдереве файл есть, в основном дереве нет)."
      continue
    fi
    src="$link_root/bin/$name"
    run mkdir -p "$BIN_DIR"
    run rm -f "$dst"
    run ln -s "$src" "$dst"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "would link $name -> $dst"
    else
      echo "Linked $name -> $dst"
    fi
  done
}

install_bin_helpers

# Commit hooks of this repository itself: the deny-list gate must run on `git commit` in the
# pi-setup checkout (#15820). prek is optional on a target machine, so a missing binary is a note,
# not a failure — the hook only matters where this checkout is committed to.
install_repo_hooks() {
  if [[ ! -f "$ROOT/prek.toml" ]]; then
    return 0
  fi
  if command -v prek >/dev/null 2>&1; then
    ( cd "$ROOT" && run prek install ) || echo "warning: prek install не прошёл — хуки в $ROOT не активны"
  else
    echo "note: prek не найден — хуки коммита в $ROOT остаются выключенными (поставьте prek и повторите)"
  fi
}

install_repo_hooks

# ru-spellcheck reads its allow list from XDG config. Seed it from the repo copy
# only when absent: the live file grows through `ru-spellcheck --add`, and those
# additions are the point, so a restore must not clobber them.
install_spellcheck_allow() {
  local cfg_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  install_config_if_absent \
    "$ROOT/config/ru-spellcheck/allow.txt" \
    "$cfg_home/ru-spellcheck/allow.txt" \
    "ru-spellcheck allow list"
}

# The deny list is the opposite: it names vocabulary an agent must not legalize, so the repo copy
# is authoritative and a restore overwrites the live file. Leaving local edits would let a session
# that grew the deny list un-ban its own wording on the next machine — and the list is human-owned
# policy (a word is banned regardless of what an allowlist says).
install_spellcheck_deny() {
  local cfg_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  if [[ -f "$ROOT/config/ru-spellcheck/deny.txt" ]]; then
    copy_path "$ROOT/config/ru-spellcheck/deny.txt" "$cfg_home/ru-spellcheck/deny.txt"
  else
    echo "warning: $ROOT/config/ru-spellcheck/deny.txt is missing — the deny list was not restored"
  fi
}

install_spellcheck_allow
install_spellcheck_deny

# Dotfiles that live outside ~/.pi/agent (tmux, and anything else that lands under
# home/) are mirrored in a home/ tree that shadows $HOME. They are not Pi config, so a
# plain install never touches them; --copy-config, the same gate that overwrites
# ~/.pi/agent/settings.json, is what writes them. make_backup keeps the previous copy
# revertible, because ~/.tmux.conf is usually hand-edited on each machine.
install_home_dotfiles() {
  local rels rel src dst stamp
  rels="$(home_dotfile_rels)"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    src="$ROOT/home/$rel"
    dst="$HOME/$rel"
    if [[ "$COPY_CONFIG" != "1" ]]; then
      if [[ ! -f "$dst" ]]; then
        echo "$dst is not installed; run ./install.sh --copy-config to install it."
      elif cmp -s "$src" "$dst"; then
        echo "$dst is up to date."
      else
        echo "$dst differs from the repo copy ($(diff_lines "$src" "$dst")); leaving it (use --copy-config to overwrite)."
      fi
      continue
    fi
    if [[ -f "$dst" ]]; then
      if cmp -s "$src" "$dst"; then
        # Already the repo copy — which includes a ~/.tmux.conf symlinked into the repo,
        # where `cp` onto itself aborts with "are the same file".
        echo "$dst is up to date."
        continue
      fi
      # Same precedent as the VS Code keybindings merge: the live file is the user's, so
      # an overwrite keeps the previous copy next to it even without --backup.
      stamp="$(date +%Y%m%dT%H%M%S)"
      run cp "$dst" "$dst.bak-$stamp"
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "would back up the previous $dst to $dst.bak-<timestamp>"
      else
        echo "Backed up the previous $dst to $dst.bak-$stamp"
      fi
    fi
    copy_path "$src" "$dst"
  done <<<"$rels"
}

install_home_dotfiles

if [[ -n "$BACKUP_DIR" ]]; then
  echo "To revert this install: $ROOT/install.sh --revert '$BACKUP_DIR'"
fi

echo "Done. Restart Pi or run /reload in an existing session."
echo "Sync live Pi tweaks back here with: pi-setup-sync"

#!/usr/bin/env bash
set -euo pipefail

# Install helper commands for this pi-setup repo.
#
# ~/.pi/agent is the live Pi setup. This repo is the versioned pi-setup copy
# used to back up that live setup to GitHub and recreate it on any machine.
#
# Usage:
#   ./install.sh                 # install sync helper + compact launcher only
#   ./install.sh --copy-config   # also overwrite ~/.pi/agent/settings.json and mcp.json
#   ./install.sh --restore       # also restore extensions/themes/skills from this repo into ~/.pi/agent

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_HOME="${PI_HOME:-$HOME/.pi/agent}"
COPY_CONFIG=0
RESTORE=0

usage() {
  cat <<'EOF'
Install helper commands for this pi-setup repo.

~/.pi/agent is the live Pi setup. This repo is the versioned pi-setup copy
used to back up that live setup to GitHub and recreate it on any machine.

Usage:
  ./install.sh                 # install sync helper + compact launcher only
  ./install.sh --copy-config   # also overwrite ~/.pi/agent/settings.json and mcp.json
  ./install.sh --restore       # also restore extensions/themes/skills into ~/.pi/agent
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$PI_HOME"

remove_legacy_package_reference() {
  local settings="$PI_HOME/settings.json"
  [[ -f "$settings" ]] || return 0

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

copy_dir_contents() {
  local src="$1"
  local dst="$2"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"
  find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -R "$src"/. "$dst"/
}

remove_legacy_package_reference

if [[ "$RESTORE" == "1" ]]; then
  echo "Restoring repo resources into live Pi home: $PI_HOME"
  copy_dir_contents "$ROOT/extensions" "$PI_HOME/extensions"
  copy_dir_contents "$ROOT/themes" "$PI_HOME/themes"
  copy_dir_contents "$ROOT/skills" "$PI_HOME/skills"
else
  echo "Skipping resource restore. To copy repo resources into $PI_HOME, run: ./install.sh --restore"
fi

if [[ "$COPY_CONFIG" == "1" ]]; then
  echo "Copying example config into $PI_HOME/"
  cp "$ROOT/config/settings.example.json" "$PI_HOME/settings.json"
  if [[ -f "$ROOT/config/mcp.example.json" ]]; then
    cp "$ROOT/config/mcp.example.json" "$PI_HOME/mcp.json"
  fi
  remove_legacy_package_reference
else
  echo "Skipping config copy. To copy settings/mcp examples, run: ./install.sh --copy-config"
fi

"$ROOT/setup_sync.sh"

if [[ -f "$ROOT/bin/pi" ]]; then
  mkdir -p "$HOME/.local/bin"
  cp "$ROOT/bin/pi" "$HOME/.local/bin/pi"
  chmod +x "$HOME/.local/bin/pi"
  echo "Installed compact Pi launcher: $HOME/.local/bin/pi"
fi

echo "Done. Restart Pi or run /reload in an existing session."
echo "Sync live Pi tweaks back here with: pi-setup-sync"

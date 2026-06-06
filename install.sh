#!/usr/bin/env bash
set -euo pipefail

# Install this Pi package and optionally copy safe example config files.
# Usage:
#   ./install.sh                 # local install from this checkout
#   ./install.sh --copy-config   # also overwrite ~/.pi/agent/settings.json and mcp.json

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COPY_CONFIG=0

if [[ "${1:-}" == "--copy-config" ]]; then
  COPY_CONFIG=1
fi

mkdir -p "$HOME/.pi/agent"

if ! command -v pi >/dev/null 2>&1; then
  echo "error: pi command not found. Install Pi first: https://pi.dev" >&2
  exit 1
fi

echo "Installing Pi package from: $ROOT"
pi install "$ROOT"

if [[ "$COPY_CONFIG" == "1" ]]; then
  echo "Copying example config into ~/.pi/agent/"
  cp "$ROOT/config/settings.example.json" "$HOME/.pi/agent/settings.json"
  if [[ -f "$ROOT/config/mcp.example.json" ]]; then
    cp "$ROOT/config/mcp.example.json" "$HOME/.pi/agent/mcp.json"
  fi
else
  echo "Skipping config copy. To copy settings/mcp examples, run: ./install.sh --copy-config"
fi

"$ROOT/setup_sync.sh"

echo "Done. Restart Pi or run /reload in an existing session."
echo "Sync future tweaks with: pi-setup-sync"

#!/usr/bin/env bash
set -euo pipefail

# End-to-end pi-setup smoke test, intentionally outside CI.
#
# This tests the real user flow in a fresh Ubuntu container:
#   git clone <remote> -> ./install.sh --restore --copy-config -> ~/.pi/agent
# and then verifies the backup flow:
#   ~/.pi/agent change -> pi-setup-sync --no-push -> repo commit

IMAGE="ubuntu:24.04"
REMOTE=""
BRANCH=""
RUN_SYNC=1

usage() {
  cat <<'EOF'
Usage: tests/docker-e2e.sh [options]

Options:
  --remote URL      Git remote to clone inside the container.
                    Defaults to this checkout's origin, converting GitHub SSH
                    remotes to HTTPS when possible.
  --branch NAME     Branch to clone. Defaults to this checkout's current branch.
  --image IMAGE     Docker image. Default: ubuntu:24.04
  --restore-only    Test clone + restore only; skip the pi-setup-sync backup smoke.
  -h, --help        Show this help.

Examples:
  tests/docker-e2e.sh
  tests/docker-e2e.sh --remote https://github.com/abhinand5/pi-setup.git --branch main
  tests/docker-e2e.sh --restore-only
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      REMOTE="${2:?missing value for --remote}"
      shift 2
      ;;
    --branch)
      BRANCH="${2:?missing value for --branch}"
      shift 2
      ;;
    --image)
      IMAGE="${2:?missing value for --image}"
      shift 2
      ;;
    --restore-only)
      RUN_SYNC=0
      shift
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required" >&2
  exit 1
fi

if [[ -z "$REMOTE" ]]; then
  REMOTE="$(git -C "$ROOT" config --get remote.origin.url || true)"
  if [[ -z "$REMOTE" ]]; then
    echo "error: could not infer remote.origin.url; pass --remote" >&2
    exit 1
  fi
fi

# A fresh container usually has no SSH credentials. For public GitHub repos,
# convert common SSH remotes to HTTPS so the test behaves like a fresh user clone.
if [[ "$REMOTE" =~ ^git@github.com:(.+)$ ]]; then
  REMOTE="https://github.com/${BASH_REMATCH[1]}"
elif [[ "$REMOTE" =~ ^ssh://git@github.com/(.+)$ ]]; then
  REMOTE="https://github.com/${BASH_REMATCH[1]}"
fi

if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  if [[ "$BRANCH" == "HEAD" ]]; then
    BRANCH=""
  fi
fi

CONTAINER="pi-setup-e2e-$(date +%s)"

echo "Docker image: $IMAGE"
echo "Remote:       $REMOTE"
[[ -n "$BRANCH" ]] && echo "Branch:       $BRANCH" || echo "Branch:       remote default"
echo "Container:    $CONTAINER"

docker run --rm \
  --name "$CONTAINER" \
  -e PI_SETUP_REMOTE="$REMOTE" \
  -e PI_SETUP_BRANCH="$BRANCH" \
  -e PI_SETUP_RUN_SYNC="$RUN_SYNC" \
  "$IMAGE" \
  bash -lc '
set -euo pipefail

. /etc/os-release
echo "ubuntu=$PRETTY_NAME"

apt-get update >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates jq python3 curl >/dev/null

if command -v python3 >/dev/null 2>&1; then
  echo "python3_before_restore=present"
else
  echo "python3_before_restore=absent"
fi

mkdir -p /root/dev/ai-agents
cd /root/dev/ai-agents

if [[ -n "${PI_SETUP_BRANCH:-}" ]]; then
  git clone --branch "$PI_SETUP_BRANCH" "$PI_SETUP_REMOTE" pi-setup >/dev/null 2>&1
else
  git clone "$PI_SETUP_REMOTE" pi-setup >/dev/null 2>&1
fi

cd pi-setup
echo "commit=$(git rev-parse --short HEAD)"

# Seed a machine-specific provider: --copy-config must merge the vendor pin into
# models.json without dropping it.
mkdir -p /root/.pi/agent
cat > /root/.pi/agent/models.json <<JSON
{
  "\$schema": "https://pi.dev/schemas/models.schema.json",
  "providers": {
    "custom": {
      "name": "Custom",
      "baseUrl": "https://example.invalid/v1",
      "api": "openai-completions",
      "models": []
    }
  }
}
JSON

./install.sh --restore --copy-config

cat > /usr/local/bin/pi <<PI_FAKE
#!/usr/bin/env bash
echo 0.0.0-container
PI_FAKE
chmod +x /usr/local/bin/pi
/root/.local/bin/pi --version | grep -q "0.0.0-container"

printf "\nVERIFY RESTORE\n"
test -d /root/.pi/agent/extensions
test -d /root/.pi/agent/themes
test -d /root/.pi/agent/skills
test -f /root/.pi/agent/settings.json
test -f /root/.pi/agent/mcp.json
test -f /root/.pi/agent/playwright-mcp.json
test -x /root/.local/bin/pi
test -L /root/.local/bin/pi-setup-sync

grep -q '"playwright"' /root/.pi/agent/mcp.json
grep -q 'start-maximized' /root/.pi/agent/playwright-mcp.json
grep -q 'playwright-mcp-xvfb.sh' /root/.pi/agent/mcp.json
test -x /root/.pi/agent/skills/browser-uat/scripts/playwright-mcp-xvfb.sh
test -x /root/.pi/agent/skills/browser-uat/scripts/uat.sh
grep -q '@playwright/mcp@[0-9]' /root/.pi/agent/skills/browser-uat/scripts/playwright-mcp-xvfb.sh
bash -n /root/.pi/agent/skills/browser-uat/scripts/playwright-mcp-xvfb.sh
bash -n /root/.pi/agent/skills/browser-uat/scripts/uat.sh
mcp_cmd=$(grep '"command"' /root/.pi/agent/mcp.json | grep "browser-uat" | head -1 | sed "s/.*\"command\": *\"\([^\"]*\)\".*/\1/")
test -n "$mcp_cmd"
test -x "${mcp_cmd/#\~/$HOME}"

ext_count=$(find /root/.pi/agent/extensions -type f | wc -l)
theme_count=$(find /root/.pi/agent/themes -type f -name "*.json" | wc -l)
skill_count=$(find /root/.pi/agent/skills -type f -name "SKILL.md" | wc -l)
echo "extensions=$ext_count themes=$theme_count skills=$skill_count"
test "$ext_count" -gt 0
test "$theme_count" -gt 0
test "$skill_count" -gt 0

if grep -q "pi-setup" /root/.pi/agent/settings.json; then
  echo "error: settings contains a pi-setup self-reference" >&2
  cat /root/.pi/agent/settings.json >&2
  exit 1
fi
if grep -Eq '"enabledModels"' /root/.pi/agent/settings.json; then
  echo "error: example settings should not contain machine-specific enabledModels" >&2
  cat /root/.pi/agent/settings.json >&2
  exit 1
fi
grep -q '"defaultProvider"' /root/.pi/agent/settings.json
grep -q '"defaultModel"' /root/.pi/agent/settings.json

printf "\nVERIFY MODEL CAP\n"
jq -e ".subagents.modelScope.enforce == true" /root/.pi/agent/settings.json >/dev/null
jq -e ".subagents.modelScope.strict == false" /root/.pi/agent/settings.json >/dev/null
jq -e ".subagents.modelScope.allow | length == 14" /root/.pi/agent/settings.json >/dev/null
jq -e ".subagents.defaultModel == \"openrouter/z-ai/glm-5.3-flash\"" /root/.pi/agent/settings.json >/dev/null
jq -e ".subagents.modelScope as \$s | [\$s.agents[] | .allow[]] - \$s.allow | length == 0" /root/.pi/agent/settings.json >/dev/null
jq -e "[.subagents.agentOverrides | keys[]] | (index(\"reviewer\") != null and index(\"oracle\") != null and index(\"evidence-auditor\") != null and index(\"uat-browser\") != null)" /root/.pi/agent/settings.json >/dev/null
test -f /root/.pi/agent/pi-pstack-adapter.json
jq -e --slurpfile s /root/.pi/agent/settings.json "[.models[] | split(\" \")[] | split(\":\")[0]] | unique | map(. as \$m | \$s[0].subagents.modelScope.allow | index(\$m)) | all(. != null)" /root/.pi/agent/pi-pstack-adapter.json >/dev/null
# Rows of the allowed table: first cell is a provider-qualified id. The old
# pattern expected "<price> / ..." in the second cell and matched nothing even
# before the table moved out of AGENTS.md (#15647).
test "$(grep -cE '^\| `[^`]+/[^`]+`' /root/.pi/agent/docs/delegation-models.md)" -eq 14
grep -qi "model cap" /root/.pi/agent/AGENTS.md
grep -q "docs/delegation-models.md" /root/.pi/agent/AGENTS.md
test -L /root/.local/bin/pi-models-check
test "$(/root/.local/bin/pi-models-check --list | wc -l)" -eq 14
echo "model cap ok (14 ids, adapter roles inside the allow list, delegation-models table matches)"

printf "\nVERIFY MODELS MERGE\n"
test -f /root/.pi/agent/models.json
jq -e ".providers.custom.baseUrl == \"https://example.invalid/v1\"" /root/.pi/agent/models.json >/dev/null
jq -e ".providers.openrouter.modelOverrides[\"deepseek/deepseek-v4.1-flash-1017\"].compat.openRouterRouting.order == [\"deepinfra\",\"inference-net\",\"primeintellect\"]" /root/.pi/agent/models.json >/dev/null
jq -e "[.providers[].modelOverrides // {} | .[] | .compat.openRouterRouting // {} | (.only // []) + (.order // [])] | flatten | index(\"morph\") == null" /root/.pi/agent/models.json >/dev/null
jq -e ".providers.routerai.modelOverrides[\"z-ai/glm-5.3\"].compat.openRouterRouting.order == [\"wafer\",\"decart\",\"gmicloud\"]" /root/.pi/agent/models.json >/dev/null
jq -e ".providers.routerai.modelOverrides[\"deepseek/deepseek-v4.1-flash-1017\"].compat.openRouterRouting.order == .providers.openrouter.modelOverrides[\"deepseek/deepseek-v4.1-flash-1017\"].compat.openRouterRouting.order" /root/.pi/agent/models.json >/dev/null
echo "models.json merge ok (custom provider kept, openrouter + routerai pins added)"

printf "\nVERIFY ROUTED-REQUEST EXTENSION\n"
test -f /root/.pi/agent/extensions/no-output-cap.ts
grep -q 'before_provider_request' /root/.pi/agent/extensions/no-output-cap.ts
echo "no-output-cap extension restored"

grep -q "\"extensions\": \[\]" package.json
grep -q "\"skills\": \[\]" package.json
grep -q "\"themes\": \[\]" package.json

printf "\nVERIFY SYNC HELPER TARGET\n"
/root/.local/bin/pi-setup-sync --dry-run | tee /tmp/dry-run.txt
grep -q "into /root/dev/ai-agents/pi-setup" /tmp/dry-run.txt
if grep -q "into /root/.local/bin" /tmp/dry-run.txt; then
  echo "error: pi-setup-sync resolved ROOT to ~/.local/bin" >&2
  exit 1
fi

if [[ "$PI_SETUP_RUN_SYNC" == "1" ]]; then
  printf "\nVERIFY BACKUP/SYNC PATH\n"
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3 >/dev/null
  git config user.email container@example.invalid
  git config user.name "Container Test"
  printf "\n// container-sync-smoke\n" >> /root/.pi/agent/extensions/flow-title.ts
  /root/.local/bin/pi-setup-sync --all-skills --no-push "Container sync smoke"
  git log --oneline -1 | grep -q "Container sync smoke"
  grep -q "container-sync-smoke" extensions/flow-title.ts
fi

printf "\nVERIFY UNINSTALL\n"
./uninstall.sh
test -x /usr/local/bin/pi
test ! -e /root/.local/bin/pi
test ! -e /root/.local/bin/pi-setup-sync
test ! -e /root/.pi/agent/themes/nebula-pulse.json
test ! -e /root/.pi/agent/playwright-mcp.json

echo "remote clone pi-setup e2e passed"
'

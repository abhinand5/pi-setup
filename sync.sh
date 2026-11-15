#!/usr/bin/env bash
set -euo pipefail

# Sync current ~/.pi/agent customizations into this repo, commit, and push.
# Usage:
#   ./sync.sh
#   ./sync.sh "Commit message"
#   ./sync.sh --no-push "Commit only"
#   ./sync.sh --dry-run
#   ./sync.sh --all-skills
#   ./sync.sh --skills hf-cli,diagnosing-bugs
#   ./sync.sh --prune-skills

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do
  SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  [[ "$SCRIPT_SOURCE" == /* ]] || SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
ROOT="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
PI_HOME="${PI_HOME:-$HOME/.pi/agent}"
PUSH=1
DRY_RUN=0
SKILLS_MODE="prompt"
SKILLS_FILTER=""
PRUNE_SKILLS=0
MESSAGE="Update Pi setup"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push)
      PUSH=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --all-skills)
      SKILLS_MODE="all"
      shift
      ;;
    --no-skills)
      SKILLS_MODE="none"
      shift
      ;;
    --prune-skills)
      PRUNE_SKILLS=1
      shift
      ;;
    --skills)
      SKILLS_MODE="filter"
      SKILLS_FILTER="${2:?missing comma-separated skill names for --skills}"
      shift 2
      ;;
    -h|--help)
      awk 'NR <= 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *)
      MESSAGE="$1"
      shift
      ;;
  esac
done

require_dir() {
  if [[ ! -d "$1" ]]; then
    echo "error: missing directory: $1" >&2
    exit 1
  fi
}

copy_dir_contents() {
  local src="$1"
  local dst="$2"
  require_dir "$src"
  mkdir -p "$dst"
  find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -R "$src"/. "$dst"/
}

# Discover Pi skills from both Pi's native skill root and the shared Agent Skills
# root. Most local Pi skills may be symlinks into ~/.agents/skills, so we dedupe
# by resolved path and later copy with -L to make this repo portable.
SKILL_NAMES=()
SKILL_PATHS=()
SKILL_KINDS=()
SKILL_SELECTED=()

add_skill() {
  local name="$1"
  local path="$2"
  local kind="$3"
  local real
  real="$(realpath -e "$path")"
  for existing in "${SKILL_PATHS[@]}"; do
    if [[ "$(realpath -e "$existing")" == "$real" ]]; then
      return
    fi
  done
  SKILL_NAMES+=("$name")
  SKILL_PATHS+=("$path")
  SKILL_KINDS+=("$kind")
  SKILL_SELECTED+=(1)
}

discover_skills() {
  local roots=("$PI_HOME/skills" "$HOME/.agents/skills")
  local root skill_md skill_dir skill_file
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue

    while IFS= read -r skill_md; do
      skill_dir="$(dirname "$skill_md")"
      add_skill "$(basename "$skill_dir")" "$skill_dir" "dir"
    done < <(find -L "$root" -type f -name 'SKILL.md' 2>/dev/null | sort)

    while IFS= read -r skill_file; do
      add_skill "$(basename "$skill_file" .md)" "$skill_file" "file"
    done < <(find -L "$root" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
  done
}

set_selected_from_filter() {
  local filter=",$1,"
  local i
  for i in "${!SKILL_NAMES[@]}"; do
    if [[ "$filter" == *",${SKILL_NAMES[$i]},"* ]]; then
      SKILL_SELECTED[$i]=1
    else
      SKILL_SELECTED[$i]=0
    fi
  done
}

toggle_skill_token() {
  local token="$1"
  local start end i
  if [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
    start="${token%-*}"
    end="${token#*-}"
    for ((i=start; i<=end; i++)); do
      toggle_skill_token "$i"
    done
  elif [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#SKILL_NAMES[@]} )); then
    i=$((token - 1))
    if [[ "${SKILL_SELECTED[$i]}" == "1" ]]; then
      SKILL_SELECTED[$i]=0
    else
      SKILL_SELECTED[$i]=1
    fi
  fi
}

render_skill_selector() {
  local cursor="$1"
  local i mark pointer selected_count=0
  printf '\033[H\033[J'
  printf 'Skills to back up\n\n'
  printf '  ↑/↓ move   Space toggle   Enter continue   a all   n none   q cancel\n'
  printf '  Default is all selected, so Enter once backs everything up.\n\n'

  for i in "${!SKILL_NAMES[@]}"; do
    [[ "${SKILL_SELECTED[$i]}" == "1" ]] && mark="x" && selected_count=$((selected_count + 1)) || mark=" "
    [[ "$i" == "$cursor" ]] && pointer="❯" || pointer=" "
    printf ' %s %2d. [%s] %s\n' "$pointer" "$((i + 1))" "$mark" "${SKILL_NAMES[$i]}"
  done
  printf '\nSelected: %d/%d\n' "$selected_count" "${#SKILL_NAMES[@]}"
}

select_skills() {
  discover_skills
  if [[ "${#SKILL_NAMES[@]}" == "0" ]]; then
    echo "No local skills found under $PI_HOME/skills or ~/.agents/skills."
    return
  fi

  case "$SKILLS_MODE" in
    all)
      return
      ;;
    none)
      local i
      for i in "${!SKILL_SELECTED[@]}"; do SKILL_SELECTED[$i]=0; done
      return
      ;;
    filter)
      set_selected_from_filter "$SKILLS_FILTER"
      return
      ;;
  esac

  if [[ ! -t 0 ]]; then
    echo "Non-interactive input detected; backing up all skills."
    return
  fi

  local cursor=0 key rest i
  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null || true' RETURN
  while true; do
    render_skill_selector "$cursor"
    IFS= read -rsn1 key
    case "$key" in
      "")
        break
        ;;
      $'\x1b')
        IFS= read -rsn2 -t 0.05 rest || rest=""
        case "$rest" in
          "[A") ((cursor > 0)) && cursor=$((cursor - 1)) ;;
          "[B") ((cursor < ${#SKILL_NAMES[@]} - 1)) && cursor=$((cursor + 1)) ;;
        esac
        ;;
      " ")
        if [[ "${SKILL_SELECTED[$cursor]}" == "1" ]]; then
          SKILL_SELECTED[$cursor]=0
        else
          SKILL_SELECTED[$cursor]=1
        fi
        ;;
      j|J)
        ((cursor < ${#SKILL_NAMES[@]} - 1)) && cursor=$((cursor + 1))
        ;;
      k|K)
        ((cursor > 0)) && cursor=$((cursor - 1))
        ;;
      a|A)
        for i in "${!SKILL_SELECTED[@]}"; do SKILL_SELECTED[$i]=1; done
        ;;
      n|N)
        for i in "${!SKILL_SELECTED[@]}"; do SKILL_SELECTED[$i]=0; done
        ;;
      q|Q)
        tput cnorm 2>/dev/null || true
        echo "Skill backup cancelled." >&2
        exit 1
        ;;
    esac
  done
  tput cnorm 2>/dev/null || true
  trap - RETURN
  printf '\n'
}

copy_selected_skills() {
  local dst_root="$ROOT/skills"
  local i name src kind dst selected_count=0 entry base
  local -A local_name=() selected_name=()
  local -a kept_missing=() kept_deselected=()
  # --no-skills means "leave the repo's skills/ alone", not "delete them".
  # Wiping here would silently drop every backed-up skill from the repo.
  if [[ "$SKILLS_MODE" == "none" ]]; then
    echo "Skipping skill backup (repo skills/ left untouched)"
    return
  fi
  mkdir -p "$dst_root"

  for i in "${!SKILL_NAMES[@]}"; do
    local_name["${SKILL_NAMES[$i]}"]=1
    [[ "${SKILL_SELECTED[$i]}" == "1" ]] && selected_name["${SKILL_NAMES[$i]}"]=1
  done

  # Pruning a repo that discovery never populated would delete every backed-up
  # skill at once, so refuse that combination outright.
  if [[ "$PRUNE_SKILLS" == "1" && "${#SKILL_NAMES[@]}" == "0" ]]; then
    echo "error: --prune-skills with no locally discovered skills; refusing to empty $dst_root" >&2
    exit 1
  fi

  # Remove only the entries this run is about to rewrite. Everything else stays
  # unless --prune-skills asks for it: a skill that exists only in the repo (a
  # copy archived locally, a skill never installed on this machine) must not
  # disappear just because this machine does not have it.
  for entry in "$dst_root"/*; do
    [[ -e "$entry" ]] || continue
    base="$(basename "$entry")"
    base="${base%.md}"
    if [[ -n "${selected_name[$base]:-}" ]]; then
      rm -rf "$entry"
    elif [[ "$PRUNE_SKILLS" == "1" ]]; then
      echo "pruned: $base"
      rm -rf "$entry"
    elif [[ -n "${local_name[$base]:-}" ]]; then
      kept_deselected+=("$base")
    else
      kept_missing+=("$base")
    fi
  done

  if [[ "${#kept_missing[@]}" -gt 0 ]]; then
    echo "warning: ${#kept_missing[@]} skill(s) in repo not found locally (kept): ${kept_missing[*]}"
  fi
  if [[ "${#kept_deselected[@]}" -gt 0 ]]; then
    echo "warning: ${#kept_deselected[@]} skill(s) in repo deselected this run (kept): ${kept_deselected[*]}"
  fi
  if [[ "${#kept_missing[@]}" -gt 0 || "${#kept_deselected[@]}" -gt 0 ]]; then
    echo "hint: --prune-skills deletes them instead"
  fi

  for i in "${!SKILL_NAMES[@]}"; do
    [[ "${SKILL_SELECTED[$i]}" == "1" ]] || continue
    name="${SKILL_NAMES[$i]}"
    src="${SKILL_PATHS[$i]}"
    kind="${SKILL_KINDS[$i]}"
    if [[ "$kind" == "file" ]]; then
      dst="$dst_root/$name.md"
      cp -L "$src" "$dst"
    else
      dst="$dst_root/$name"
      cp -RL "$src" "$dst"
    fi
    selected_count=$((selected_count + 1))
  done
  echo "Backed up $selected_count skill(s) into $dst_root"
}

copy_settings_example() {
  python3 - <<'PY' "$PI_HOME/settings.json" "$ROOT/config/settings.example.json" "$ROOT"
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
repo_root = Path(sys.argv[3]).resolve()

data = json.loads(src.read_text())

# Keep the checked-in example portable. The pinned startup model
# (defaultProvider + defaultModel) is intentionally kept so a restore reproduces
# the same startup model; Pi falls back to the first authenticated model when the
# provider is not configured. enabledModels patterns are machine-specific and can
# produce noisy "No models match pattern" warnings, so they stay local-only.
for key in ("enabledModels",):
    if key in data:
        data.pop(key)
        print(f"settings ok: removed local-only {key}")

# subagents.modelScope is the delegation gate (see config/AGENTS.md). The allow
# list is the OpenRouter workspace cap, which is a provider fact and therefore
# portable; `strict` is a local policy choice. Ship the gate non-strict: an
# unknown id is still rejected, but an explicit override is not fatal on a
# machine whose cap differs from this one.
scope = data.get("subagents", {}).get("modelScope")
if isinstance(scope, dict) and scope.get("strict") is not False:
    scope["strict"] = False
    print("settings ok: example ships subagents.modelScope.strict=false")

packages = data.get("packages")
if isinstance(packages, list):
    kept = []
    removed = 0
    for item in packages:
        source = item.get("source") if isinstance(item, dict) else item
        remove = False
        if isinstance(source, str) and not source.startswith(("npm:", "git:", "http://", "https://", "ssh://")):
            try:
                candidate = (src.parent / source).expanduser().resolve()
            except Exception:
                candidate = None
            remove = candidate == repo_root
        if remove:
            removed += 1
        else:
            kept.append(item)
    if removed:
        data["packages"] = kept
        print(f"settings ok: removed {removed} self-referential pi-setup package entry")

dst.parent.mkdir(parents=True, exist_ok=True)
dst.write_text(json.dumps(data, indent=2) + "\n")
PY
}

validate_json() {
  python3 - <<'PY' "$@"
import json, sys
for path in sys.argv[1:]:
    with open(path, 'r', encoding='utf-8') as f:
        json.load(f)
    print('json ok:', path)
PY
}

copy_pstack_adapter_example() {
  local src="$PI_HOME/pi-pstack-adapter.json"
  local dst="$ROOT/config/pi-pstack-adapter.example.json"
  if [[ ! -f "$src" ]]; then
    echo "pstack adapter config: no $src; leaving $dst untouched"
    return 0
  fi
  cp "$src" "$dst"
  echo "pstack adapter config: pinned roles/panels backed up into $dst"
}

# models.json is machine-specific (API keys, custom endpoints) so it is never
# copied wholesale. The portable part is providers.<name>.modelOverrides, and it
# drifts silently: a pin added live never reaches the example, so a restore
# brings back stale routing. Merge the live overrides into the example instead.
sync_models_overrides() {
  local live="$PI_HOME/models.json"
  local example="$ROOT/config/models.example.json"
  [[ -f "$live" && -f "$example" ]] || return 0
  python3 - <<'PY' "$live" "$example"
import json
import sys
from pathlib import Path

live_path, example_path = Path(sys.argv[1]), Path(sys.argv[2])
live = json.loads(live_path.read_text())
example = json.loads(example_path.read_text())

example.setdefault("$schema", live.get("$schema", "https://pi.dev/schemas/models.schema.json"))
target = example.setdefault("providers", {})
added = []
for name, provider in (live.get("providers") or {}).items():
    overrides = (provider or {}).get("modelOverrides")
    if not isinstance(overrides, dict) or not overrides:
        continue
    bucket = target.setdefault(name, {}).setdefault("modelOverrides", {})
    for model, rule in overrides.items():
        if bucket.get(model) != rule:
            added.append(f"{name}:{model}")
            bucket[model] = rule

if not added:
    print("models ok: example already carries every live modelOverride")
    raise SystemExit(0)
example_path.write_text(json.dumps(example, indent=2) + "\n")
print("models ok: example updated from live overrides: " + ", ".join(sorted(added)))
PY
}

# The allow list, the pstack role pinning and the AGENTS.md table are three
# copies of one fact: which model ids the provider actually serves. A restore
# from a stale copy is what loses a delegation run, so refuse to sync when they
# disagree.
validate_models() {
  python3 - <<'PY' "$ROOT"
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
settings_path = root / "config" / "settings.example.json"
adapter_path = root / "config" / "pi-pstack-adapter.example.json"
agents_path = root / "config" / "AGENTS.md"
errors = []

def normalize(model_id):
    for prefix in ("openrouter/", "routerai/"):
        if model_id.startswith(prefix):
            return model_id[len(prefix):]
    return model_id

if not settings_path.is_file():
    raise SystemExit("models: no config/settings.example.json to validate")
settings = json.loads(settings_path.read_text())
scope = (settings.get("subagents") or {}).get("modelScope") or {}
allow = list(scope.get("allow") or [])
if not allow:
    raise SystemExit("models: settings.example.json has no subagents.modelScope.allow")
allow_norm = {normalize(m) for m in allow}
print(f"models ok: modelScope.allow carries {len(allow)} ids")

for agent, rule in sorted((scope.get("agents") or {}).items()):
    extra = sorted(set(rule.get("allow") or []) - set(allow))
    if extra:
        errors.append(f"modelScope.agents.{agent} names ids outside modelScope.allow: {extra}")

if adapter_path.is_file():
    adapter = json.loads(adapter_path.read_text())
    ids = set()
    for role, spec in sorted((adapter.get("models") or {}).items()):
        for token in str(spec).split():
            model = token.split(":", 1)[0]
            if "/" not in model:
                continue
            ids.add(model)
    extra = sorted(ids - set(allow))
    if extra:
        errors.append(f"config/pi-pstack-adapter.example.json names ids outside modelScope.allow: {extra}")
    print(f"models ok: {len(ids)} adapter role/panel ids are inside the allow list")

if agents_path.is_file():
    table = set()
    for line in agents_path.read_text().splitlines():
        match = re.match(r"^\|\s*`([^`]+)`\s*\|", line)
        if match:
            table.add(normalize(match.group(1)))
    if not table:
        print("models warning: no `| `id` |` rows found in config/AGENTS.md; skipped table check")
    elif table != allow_norm:
        only_table = sorted(table - allow_norm)
        only_allow = sorted(allow_norm - table)
        errors.append(
            "config/AGENTS.md allowed table and modelScope.allow disagree; "
            f"only in AGENTS.md: {only_table}, only in modelScope: {only_allow}"
        )
    else:
        print(f"models ok: config/AGENTS.md table matches modelScope.allow ({len(table)} ids)")

if errors:
    print("\n".join(f"models error: {e}" for e in errors), file=sys.stderr)
    raise SystemExit(1)
PY
}

validate_themes() {
  python3 - <<'PY' "$ROOT"
import json, glob, sys
from pathlib import Path
root = Path(sys.argv[1])
schema_path = Path('/opt/pi-coding-agent/theme/theme-schema.json')
if schema_path.exists():
    schema = json.load(open(schema_path, encoding='utf-8'))
    required = set(schema['properties']['colors']['required'])
else:
    required = {
        'accent', 'border', 'borderAccent', 'borderMuted', 'success', 'error', 'warning', 'muted', 'dim', 'text', 'thinkingText',
        'selectedBg', 'userMessageBg', 'userMessageText', 'customMessageBg', 'customMessageText', 'customMessageLabel',
        'toolPendingBg', 'toolSuccessBg', 'toolErrorBg', 'toolTitle', 'toolOutput',
        'mdHeading', 'mdLink', 'mdLinkUrl', 'mdCode', 'mdCodeBlock', 'mdCodeBlockBorder', 'mdQuote', 'mdQuoteBorder', 'mdHr', 'mdListBullet',
        'toolDiffAdded', 'toolDiffRemoved', 'toolDiffContext',
        'syntaxComment', 'syntaxKeyword', 'syntaxFunction', 'syntaxVariable', 'syntaxString', 'syntaxNumber', 'syntaxType', 'syntaxOperator', 'syntaxPunctuation',
        'thinkingOff', 'thinkingMinimal', 'thinkingLow', 'thinkingMedium', 'thinkingHigh', 'thinkingXhigh', 'bashMode',
    }
for path in sorted((root / 'themes').glob('*.json')):
    data = json.load(open(path, encoding='utf-8'))
    colors = data.get('colors', {})
    missing = required - set(colors)
    extra = set(colors) - required
    vars_ = set(data.get('vars', {}))
    bad_refs = [v for v in colors.values() if isinstance(v, str) and v and not v.startswith('#') and v not in vars_]
    if missing or extra or bad_refs:
        raise SystemExit(f'theme validation failed: {path}\nmissing={sorted(missing)}\nextra={sorted(extra)}\nbad_refs={bad_refs}')
    print('theme ok:', path.name)
PY
}

validate_skills() {
  python3 - <<'PY' "$ROOT"
from pathlib import Path
root = Path(__import__('sys').argv[1]) / 'skills'
if not root.exists():
    print('skills ok: none')
    raise SystemExit(0)
for path in sorted(root.iterdir()):
    if path.is_dir():
        if not (path / 'SKILL.md').is_file():
            print(f'warning: skill directory missing SKILL.md: {path}')
        else:
            print('skill ok:', path.name)
    elif path.suffix == '.md':
        print('skill ok:', path.name)
    else:
        print(f'warning: unexpected file in skills/: {path}')
PY
}

cd "$ROOT"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run: would sync from $PI_HOME into $ROOT"
  echo "Files that may change: extensions/, themes/, skills/, config/settings.example.json, config/mcp.example.json, config/micme.example.json, config/models.example.json, config/AGENTS.md, config/pi-pstack-adapter.example.json"
  exit 0
fi

select_skills

copy_dir_contents "$PI_HOME/extensions" "$ROOT/extensions"
copy_dir_contents "$PI_HOME/themes" "$ROOT/themes"
copy_selected_skills
mkdir -p "$ROOT/config"
copy_settings_example
copy_pstack_adapter_example
sync_models_overrides
if [[ -f "$PI_HOME/mcp.json" ]]; then
  cp "$PI_HOME/mcp.json" "$ROOT/config/mcp.example.json"
fi
if [[ -f "$PI_HOME/micme.json" ]]; then
  cp "$PI_HOME/micme.json" "$ROOT/config/micme.example.json"
fi
if [[ -f "$PI_HOME/AGENTS.md" ]]; then
  cp "$PI_HOME/AGENTS.md" "$ROOT/config/AGENTS.md"
fi

validate_json "$ROOT/package.json" "$ROOT/config/settings.example.json"
if [[ -f "$ROOT/config/models.example.json" ]]; then
  validate_json "$ROOT/config/models.example.json"
fi
if [[ -f "$ROOT/config/pi-pstack-adapter.example.json" ]]; then
  validate_json "$ROOT/config/pi-pstack-adapter.example.json"
fi
validate_models
if [[ -f "$ROOT/config/mcp.example.json" ]]; then
  validate_json "$ROOT/config/mcp.example.json"
fi
if [[ -f "$ROOT/config/micme.example.json" ]]; then
  validate_json "$ROOT/config/micme.example.json"
fi
validate_json "$ROOT"/themes/*.json
validate_themes
validate_skills

git add bin extensions themes skills config docs tests package.json README.md install.sh uninstall.sh sync.sh setup_sync.sh .gitignore

if git diff --cached --quiet; then
  echo "No Pi setup changes to sync."
  exit 0
fi

git commit -m "$MESSAGE"

if [[ "$PUSH" == "1" ]]; then
  git push
else
  echo "Committed locally. Push later with: git push"
fi

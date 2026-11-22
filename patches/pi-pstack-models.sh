#!/usr/bin/env bash
# Strip the Cursor model slugs out of the pstack skill bodies.
#
# Upstream pstack was written for Cursor, so its bodies hand out concrete Cursor
# slugs (`claude-fable-5-2-high`, `claude-opus-5-5-high-fast`, `gemini-4-neon-xhigh`,
# `grok-*`, `gpt-*`, `composer-*`, `cursor-grok-*`) whenever the
# `~/.cursor/rules/pstack-models.mdc` rule does not exist. None of those ids exist
# in this Pi installation and Pi never has the rule, so the fallback always fires.
# This patch rewrites every such body, at generation time, to a `pstack:<role>`
# reference: the adapter then picks the role's model and thinking, so no skill
# names a model.
#
# The rewrite table lives in this script and is the single source of truth. It is
# sentence-precise, so it is tied to one upstream revision: the table below was
# derived against pstack 0.15.46 (commit aaeb0ea). The script regenerates the
# table inside `src/generate.ts` and verifies the result against the upstream
# checkout; when upstream rewords a body, the run fails and prints what still
# names a slug (or what no longer matches) — re-derive the table then, never
# loosen the check.
#
# It also replaces the Cursor model ids in the adapter's own `setup.md` examples
# with `<provider>/<model>` placeholders, so nothing teaches a blocked family.
#
# Pi reinstalls npm packages on `pi install` / `pi update --extensions`, so re-run
# this after either (install.sh calls it automatically).
#
# Usage:
#   ./patches/pi-pstack-models.sh            # patch the installed package
#   ./patches/pi-pstack-models.sh --check    # exit 1 if the patch is missing
#   ./patches/pi-pstack-models.sh --dry-run  # show what would change

set -euo pipefail

DRY_RUN=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PI_HOME="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PKG_DIR="$PI_HOME/npm/node_modules/pi-pstack-adapter"
CACHE_DIR="$PI_HOME/cache/pi-pstack-adapter"

if [[ ! -d "$PKG_DIR" ]]; then
  echo "pi-pstack-models: pi-pstack-adapter is not installed under $PKG_DIR; nothing to patch."
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "pi-pstack-models: python3 is required to patch; skipping." >&2
  exit 1
fi

status=0
python3 - "$PKG_DIR" "$CACHE_DIR" "$DRY_RUN" "$CHECK_ONLY" <<'PY' || status=$?
import json
import re
import shutil
import sys
from pathlib import Path

pkg = Path(sys.argv[1])
cache = Path(sys.argv[2])
dry_run = sys.argv[3] == "1"
check_only = sys.argv[4] == "1"

# --- the rewrite table ------------------------------------------------------
# (upstream text, Pi text). Applied to every generated body and every copied
# Markdown support file. Ordered: the specific sentences first, then the generic
# phrase cleanup.
# --- the rewrite table ------------------------------------------------------
# (upstream text, Pi text). Applied to every generated body and every copied
# Markdown support file. Derived against pstack 0.15.46 (commit aaeb0ea); the
# leftovers check below is what catches the next upstream rewording, so re-derive
# the table when it fails rather than loosening it.
REWRITES = [
    (
        "3. Pick the runners from the `arena runners` line in `~/.cursor/rules/pstack-models.mdc`, by default `claude-fable-5-2-high`, `claude-opus-5-5-high-fast`, and `gemini-4-neon-xhigh`. An `auto` or `inherit-parent` entry is the parent model, so omit `model` and spawn `generalPurpose`. If the Task tool rejects a slug, use the nearest valid slug of the same family or drop the seat, keep at least two runners, and say so. Families go by prefix, and the longest match wins: `claude-fable-*`, `claude-*`, and `gemini-*`, after dropping a leading `cursor-`. Any other slug's family is its text before the first hyphen. Spawn more for multiple design directions, and repeat one model when the work is generation-bound, not judgment-sensitive. Pick each subagent's reasoning level per the Subagents section of the **poteto-mode** skill.",
        "3. Use the `arena runners` seats. If the panel is unset, its seats are `pstack:judgment` and `pstack:general`. A role that inherits the parent model runs with no `model`, so omit it for that seat. If the delegation rejects a seat, drop it, keep at least two runners, and say so. Spawn more for multiple design directions, and repeat one role when the work is generation-bound, not judgment-sensitive. Pick each subagent's thinking level per the Subagents section of the **poteto-mode** skill.",
    ),
    (
        "After all Phase B candidates complete, spawn one readonly judge from the `arena cross-judge pool` line in `~/.cursor/rules/pstack-models.mdc`, by default `claude-opus-5-5-high-fast`, `gemini-4-neon-xhigh`. The judge is never from the parent's vendor, and Fable counts as Claude for that check, so use the first entry from another vendor. An `auto` or `inherit-parent` entry is the parent model. If you do not know the parent's model, use the first real slug and say that the vendor check did not run. If the Task tool rejects a slug, use the nearest valid slug of the same family, then the next such entry, or skip the judge, and say so. While you read in Phase D, the judge scores each candidate, by path label, on each rubric criterion and recommends a base.",
        "After all Phase B candidates complete, spawn one readonly judge from the `arena cross-judge pool` seats. If the pool is unset, its seats are `pstack:judgment` and `pstack:general`. The judge must not run on the parent's own model, so skip a seat that resolves to it and take the next seat. If a seat is rejected, move to the next seat; if no seat from another model runs, skip the judge, pick the base alone, and say so. If you do not know the parent's model, try the seats in order and say that the diversity check did not run. While you read in Phase D, the judge scores each candidate, by path label, on each rubric criterion and recommends a base.",
    ),
    (
        "3. Pick the worker model from the `swarm workers` line in `~/.cursor/rules/pstack-models.mdc`. If the rule or that line is missing, use `claude-opus-5-5-high-fast`. For `auto` or `inherit-parent`, omit `model` so the workers run on the parent model. If the Task tool rejects a slug, use the default and say so. If it rejects the default, use the closest valid slug of the same family from its error message. For a model race, name each arm's model up front. Pick each subagent's reasoning level for the job, per the Subagents section of the **poteto-mode** skill.",
        "3. Run the workers as `pstack:general`, or omit `model` when that role inherits so they run on the parent model. If a delegation rejects the role, report it instead of trying another model. For a role race, name each arm's role up front. Pick each subagent's thinking level for the job, per the Subagents section of the **poteto-mode** skill.",
    ),
    (
        "**Defaults for every `Task` call.** `run_in_background: true`, agent mode (readonly strips MCP), file pointers not inlined context, and an explicit model per role, Project workers included. `/setup-pstack` writes `~/.cursor/rules/pstack-models.mdc`, whose per-role lines override the defaults below and the role models in the routed skills (`arena`, `swarm`, `interrogate`). A role with no line keeps its default. A line of `inherit-parent` or `auto` runs the role on the parent model, so omit `model` and spawn `generalPurpose`, because `poteto-agent` defaults to Opus 5.5. Each code playbook reads its own line (`feature, refactoring`, `bug-fix`, `perf-issue`, or `hillclimb`), prose and judgment read `judgment and prose`, and trivial mechanical edits read `swarm workers`. If the rule has no `# defaults: 3` line, an older setup wrote it. Keep honoring its lines, and tell the user once per session to rerun `/setup-pstack`.",
        "**Defaults for every `Task` call.** `run_in_background: true`, agent mode (readonly strips MCP), file pointers not inlined context, and an explicit role for every subagent, Project workers included. `/skill:pistack-setup` writes the role table to `~/.pi/agent/pi-pstack-adapter.json`, and its entries override the defaults below and the roles named in the routed skills (`arena`, `swarm`, `interrogate`). A role with no entry inherits the parent session's model and thinking, so omit `model` for it. Each code playbook names its own role (`feature` or `refactoring`, `bug-fix`, `perf-issue`, `hillclimb`), prose and judgment use `judgment`, and trivial mechanical edits use `general`.",
    ),
    (
        "- Code, prose, and judgment: `claude-opus-5-5-xhigh-fast`.",
        "- Code, prose, and judgment: `pstack:judgment`.",
    ),
    (
        "- Trivial mechanical edits: `claude-opus-5-5-high-fast`.",
        "- Trivial mechanical edits: `pstack:general`.",
    ),
    (
        "- Diverse review and design panels: one runner each on `claude-fable-5-2-high`, `claude-opus-5-5-high-fast`, and `gemini-4-neon-xhigh`.",
        "- Diverse review and design panels: the `arena-runners` seats.",
    ),
    (
        "**Fable 5.2 is an exception.** It runs outside a panel only when the user named it for this task or two Opus 5.5 xhigh runs of the same brief failed its check. Say which. Difficulty alone never qualifies.",
        "**`strongest-judgment` is an exception.** It runs outside a panel only when the user asked for it on this task, or when two `judgment` runs of the same brief failed the check. Say which. Difficulty alone never qualifies.",
    ),
    (
        "**Match the model to the job.** Start from the role's line or default, keep its family, and set the level the job needs. The `/setup-pstack` budget sets each role's starting level. Panel seats keep their listed level. Raise any other role one step, up to xhigh, for the hardest or subtlest work, lower it one step for judgment, and two or more steps for routine work. No role runs above xhigh. Opus 5.5 always runs its `-fast` slug. Verification always runs on the `swarm workers` model, `claude-opus-5-5-high-fast` by default. A Gemini seat runs at `gemini-4-neon-xhigh` unless its line names another level. If the Task tool rejects a slug, never pass it again. Fall back to the role's line or default, then the calling skill's fallback, then the closest valid slug of the same family, then omit `model`. Say so.",
        "**Match the thinking level to the job.** Start from the role's configured thinking level, keep the role's model, and set the level the job needs. `/skill:pistack-setup` sets each role's starting level, and panel seats keep the level the table gives them. Raise it one step, up to `max`, for the hardest or subtlest work, and lower it for routine work. Verification always runs as `pstack:general`. If a delegation is rejected, do not try another model; report the failure and name the rejected role.",
    ),
    (
        "using your configured bug-fix model (default `claude-opus-5-5-xhigh-fast`)",
        "using `pstack:bug-fix`",
    ),
    (
        "using your configured feature model (default `claude-opus-5-5-xhigh-fast`)",
        "using `pstack:feature`",
    ),
    (
        "using your configured hillclimb model (default `claude-opus-5-5-xhigh-fast`)",
        "using `pstack:hillclimb`",
    ),
    (
        "using your configured perf-issue model (default `claude-opus-5-5-xhigh-fast`)",
        "using `pstack:perf-issue`",
    ),
    (
        "using your configured refactoring model (default `claude-opus-5-5-xhigh-fast`)",
        "using `pstack:refactoring`",
    ),
    (
        "runs on `claude-opus-5-5-medium-fast`.",
        "runs on `pstack:general`.",
    ),
]

# The adapter's own Pi-native skill bodies. Its examples must not teach a model id.
ADAPTER_REWRITES = [
    (
        "`PISTACK_MODELS=feature=anthropic/claude-sonnet-4-5:medium,bug-fix=openai/gpt-5:high`. The",
        "`PISTACK_MODELS=feature=<provider>/<model-a>:medium,bug-fix=<provider>/<model-b>:high`. The",
    ),
    (
        "`feature=anthropic/claude-sonnet-4-5:high|openai/gpt-5:high`. A panel's entries are separated by spaces, as",
        "`feature=<provider>/<model-a>:high|<provider>/<model-b>:high`. A panel's entries are separated by spaces, as",
    ),
    (
        "in `PISTACK_MODELS='arena-runners=anthropic/claude-sonnet-4-5:high openai/gpt-5:high'`. `PISTACK_MODELS` overrides",
        "in `PISTACK_MODELS='arena-runners=<provider>/<model-a>:high <provider>/<model-b>:high'`. `PISTACK_MODELS` overrides",
    ),
    (
        "- `include`, a list of patterns a model must match, such as `[\"gpt-*\"]` for GPT only.",
        "- `include`, a list of patterns a model must match, such as `[\"glm-*\"]` for one model family only.",
    ),
    (
        "- `exclude`, a list of patterns no model may match, such as `[\"*claude*\"]` for no Claude, including Bedrock-style ids.",
        "- `exclude`, a list of patterns no model may match, such as `[\"*gemini*\"]` for no Gemini, including provider-prefixed ids.",
    ),
]

# Upstream skills the adapter replaces wholesale, so their bodies never generate.
REPLACED_SKILLS = {"setup-pstack", "status"}

# A Cursor model slug left behind after the rewrite table.
SLUG = re.compile(r"\b(?:claude|grok|gpt|gemini|composer|cursor-grok)(?:-[a-z]+)*-[0-9][a-z0-9.-]*")

BLOCK_START = "// pi-pstack-models: start"
BLOCK_END = "// pi-pstack-models: end"

GENERATE = pkg / "src" / "generate.ts"
SETUP = pkg / "adapter-skills" / "setup.md"


def table_block() -> str:
    rows = ",\n".join(
        "  [" + json.dumps(old) + ", " + json.dumps(new) + "]" for old, new in REWRITES
    )
    head = """// pi-pstack-models: start
/**
 * Cursor model slugs in the upstream pstack bodies, replaced with Pi role references.
 * Upstream falls back to `claude-opus-5-5-xhigh` and `grok-4.7-xhigh-fast` when no Cursor rule
 * exists, and Pi never has that rule. A pstack role is passed as `pstack:<role>`, and the adapter
 * resolves it to the role's model and thinking, so no body names a model.
 * Generated by patches/pi-pstack-models.sh; edit that script, not this table.
 */
const PI_MODEL_REWRITES: ReadonlyArray<readonly [string, string]> = [
"""
    tail = """
];

/** Replaces Cursor model slugs and effort words with Pi role references. */
function piNeutralizeModels(text: string): string {
  let result = text;
  for (const [from, to] of PI_MODEL_REWRITES) result = result.split(from).join(to);
  return result;
}
// pi-pstack-models: end"""
    return head + rows + tail


def apply(path: Path, old: str, new: str, label: str) -> str:
    """Returns 'already', 'patched', 'dry', or 'missing'."""
    text = path.read_text()
    # `new` may contain `old` (the copy hook wraps the original two lines), so check
    # the post-patch marker first.
    if new in text:
        return "already"
    if old not in text:
        return "missing"
    if check_only:
        return "missing"
    if dry_run:
        return "dry"
    path.write_text(text.replace(old, new, 1))
    return "patched"


problems = []
changed = False

# 1. The rewrite table inside generate.ts, so every generated body and every copied
#    Markdown file goes through it.
if not GENERATE.is_file():
    print(f"pi-pstack-models: {GENERATE} is missing; the package layout changed.", file=sys.stderr)
    sys.exit(1)

text = GENERATE.read_text()
block = table_block()
if BLOCK_START in text and BLOCK_END in text:
    updated = re.sub(
        re.escape(BLOCK_START) + r".*?" + re.escape(BLOCK_END), lambda _m: block, text, count=1, flags=re.S
    )
    if updated == text:
        print("pi-pstack-models: generate.ts rewrite table already patched")
    elif check_only:
        print("pi-pstack-models: generate.ts rewrite table is NOT patched", file=sys.stderr)
        sys.exit(1)
    elif dry_run:
        print("pi-pstack-models: would update the rewrite table in generate.ts")
        changed = True
    else:
        GENERATE.write_text(updated)
        print("pi-pstack-models: updated the rewrite table in generate.ts")
        changed = True
else:
    anchor = "interface WrapperInput {"
    if anchor not in text:
        print("pi-pstack-models: could not find the WrapperInput anchor in generate.ts.", file=sys.stderr)
        sys.exit(1)
    if check_only:
        print("pi-pstack-models: generate.ts is NOT patched", file=sys.stderr)
        sys.exit(1)
    if dry_run:
        print("pi-pstack-models: would insert the rewrite table into generate.ts")
    else:
        GENERATE.write_text(text.replace(anchor, block + "\n\n" + anchor, 1))
        print("pi-pstack-models: inserted the rewrite table into generate.ts")
    changed = True

# 2. Route the body through it, and rewrite copied Markdown support files.
BODY_OLD = (
    '  return `${lines.join("\\n")}${BODY_START}\\n${input.body}'
    '${input.body.endsWith("\\n") ? "" : "\\n"}${footer(input)}`;'
)
BODY_NEW = (
    "  const body = piNeutralizeModels(input.body);\n"
    '  return `${lines.join("\\n")}${BODY_START}\\n${body}'
    '${body.endsWith("\\n") ? "" : "\\n"}${footer(input)}`;'
)
COPY_OLD = """      mkdirSync(dirname(to), { recursive: true });
      copyFileSync(from, to);"""
COPY_NEW = """      mkdirSync(dirname(to), { recursive: true });
      copyFileSync(from, to);
      if (to.endsWith(".md")) {
        const original = readFileSync(to, "utf8");
        const rewritten = piNeutralizeModels(original);
        if (rewritten !== original) writeFileSync(to, rewritten, "utf8");
      }"""
HEADER_COMMENT_OLD = "<!-- Generated by pi-pstack-adapter. Everything after this block is the upstream pstack body, unchanged. -->"
HEADER_COMMENT_NEW = "<!-- Generated by pi-pstack-adapter. Everything after this block is the upstream pstack body, with Cursor model slugs replaced by role references. -->"
HEADER_NOTE_OLD = "The body names Cursor tools, model slugs, and paths. Read [host mapping](../../adapter/host-mapping.md) for the Pi equivalent, and [skill names](../../adapter/skill-names.md) for the Pi name of any pstack skill it references."
HEADER_NOTE_NEW = (
    "The body names Cursor tools and paths, and Cursor effort and speed rules that Pi has no "
    "equivalent for. Its Cursor model slugs were replaced with \\`pstack:<role>\\` references, so "
    "pass the role and never a model slug. Read [host mapping](../../adapter/host-mapping.md) for "
    "the Pi equivalent of everything else, and [skill names](../../adapter/skill-names.md) for the "
    "Pi name of any pstack skill it references."
)

for label, old, new in (
    ("body rewrite hook", BODY_OLD, BODY_NEW),
    ("support-file rewrite hook", COPY_OLD, COPY_NEW),
    ("header comment", HEADER_COMMENT_OLD, HEADER_COMMENT_NEW),
    ("header note", HEADER_NOTE_OLD, HEADER_NOTE_NEW),
):
    state = apply(GENERATE, old, new, label)
    if state == "missing":
        problems.append(label)
    elif state in ("patched", "dry"):
        changed = True
        print(f"pi-pstack-models: {label} {state}")
    else:
        print(f"pi-pstack-models: {label} already patched")

# 3. The adapter's own setup examples.
for old, new in ADAPTER_REWRITES:
    state = apply(SETUP, old, new, "setup.md example")
    if state == "missing":
        problems.append("setup.md example: " + old[:48])
    elif state in ("patched", "dry"):
        changed = True
        print(f"pi-pstack-models: setup.md example {state}")
    else:
        print("pi-pstack-models: setup.md example already patched")

if problems:
    print(
        "pi-pstack-models: could not find the expected text for "
        + "; ".join(problems)
        + ". The upstream release or the adapter changed; re-derive patches/pi-pstack-models.sh.",
        file=sys.stderr,
    )
    sys.exit(1)

# 4. Verify the table against the content that will actually be generated: a slug the
#    table does not cover would ship as a concrete Cursor model id.
checkouts = sorted(cache.glob("checkouts/*/pstack/skills")) if cache.is_dir() else []
leftovers = []
stale = []
if checkouts:
    skills_root = checkouts[-1]
    scanned = []
    for path in sorted(skills_root.rglob("*.md")):
        if path.relative_to(skills_root).parts[0] in REPLACED_SKILLS:
            continue
        scanned.append(path.read_text())
    adapter_dir = pkg / "adapter-skills"
    if adapter_dir.is_dir():
        for path in sorted(adapter_dir.glob("*.md")):
            scanned.append(path.read_text())
    joined = "\n".join(scanned)
    for old, new in REWRITES:
        if old not in joined:
            stale.append(old[:64])
    for text in scanned:
        result = text
        for old, new in REWRITES + ADAPTER_REWRITES:
            result = result.replace(old, new)
        for match in SLUG.finditer(result):
            line_start = result.rfind("\n", 0, match.start()) + 1
            line_end = result.find("\n", match.end())
            line = result[line_start : line_end if line_end >= 0 else len(result)]
            leftovers.append(f"{match.group(0)}: {line.strip()[:140]}")
if leftovers:
    print("pi-pstack-models: these model slugs survive the rewrite table:", file=sys.stderr)
    for item in sorted(set(leftovers)):
        print("  " + item, file=sys.stderr)
    print(
        "pi-pstack-models: add a rewrite entry for each before trusting the generated skills.",
        file=sys.stderr,
    )
    sys.exit(1)
if stale:
    print(
        "pi-pstack-models: warning: "
        + str(len(stale))
        + " rewrite entries matched nothing (upstream rewording); no slug is left, so this is informational",
        file=sys.stderr,
    )

if check_only:
    print("pi-pstack-models: patch is applied")
    sys.exit(0)

if dry_run:
    print("pi-pstack-models: dry run, nothing written")
    sys.exit(0)

# The generated wrappers are content-addressed over the package source, so a patched
# generate.ts makes a fresh directory on the next Pi start. Drop the stale ones.
if changed and cache.is_dir() and (cache / "generated").is_dir():
    for entry in (cache / "generated").iterdir():
        if entry.is_dir():
            shutil.rmtree(entry)
        else:
            entry.unlink()
    print("pi-pstack-models: cleared generated wrappers; they regenerate on the next Pi start.")
PY

if [[ $status -ne 0 ]]; then
  exit $status
fi

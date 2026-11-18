# Session logs: reading them without writing a script

Every pi session leaves one JSONL file. A retro reads those files to answer three questions: *which
session took this work*, *what did it actually do*, and *how expensive was it*. Those questions are
answered by the recipes below — the retro that produced this page wrote four ad-hoc python scripts for
them, and the neighbouring retros wrote the same ones again.

Path: `~/.pi/agent/sessions/<project-slug>/<timestamp>_<uuid>.jsonl`, where the slug is the project
cwd with `/` replaced by `-` (`/home/denis/p/msl/msb-lk` → `--home-denis-p-msl-msb-lk--`). Subagent
artifacts sit next to it in `<uuid>/subagent-artifacts/`.

Record shape: one JSON object per line with `type`, `id`, `timestamp`, `parentId` and — for
`type: "message"` — `message.role` (`user`, `assistant`, `toolResult`, `system`) and
`message.content`, a list of parts: `text`, `thinking`, `toolCall` (`name`, `arguments`). Bookkeeping
lines carry other `type` values (`session`, `model_change`, `thinking_level_change`, `custom`,
`custom_message`) and have no `message`.

Set `SESSION` once per investigation and reuse it:

```bash
SESSIONS="$HOME/.pi/agent/sessions/--home-denis-p-msl-msb-lk--"
SESSION="$SESSIONS/2026-11-18T20-21-23-485Z_01a1f052-3b9c-71b3-9890-ccb1f0469185.jsonl"
```

## 1. Find the session

```bash
rg -l '#15807' "$SESSIONS"            # sessions that mention a task number
rg -l 'фраза из разговора' "$SESSIONS" # sessions that contain a phrase only this conversation had
wc -l "$SESSION"                       # size before reading — never read a whole log in one call
```

Two traps, both measured:

- **`ls -t` does not identify the current session.** Files get the same mtime when a tree is copied or
  restored, so newest-first names an arbitrary log and the retro measures someone else's work. An
  anchor does identify it: a phrase only this conversation contains, confirmed against `session.id`
  from the environment.
- **`rg -c ''` is not a line count.** The `bin/rg` wrapper refuses an empty pattern, and the refusal
  reads like an empty file. Use `wc -l`.

## 2. What the session did — dialogue only

User and assistant text, no thinking, no tool output:

```bash
python3 - "$SESSION" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding='utf-8'):
    rec = json.loads(line)
    if rec.get('type') != 'message':
        continue
    msg = rec.get('message') or {}
    if msg.get('role') not in ('user', 'assistant'):
        continue
    content = msg.get('content') if isinstance(msg.get('content'), list) else []
    for part in content:
        if isinstance(part, dict) and part.get('type') == 'text' and part.get('text', '').strip():
            print(f"[{rec['timestamp'][11:19]}] {msg['role']}: {part['text'][:400]}")
PY
```

Swap `'text'` for `'thinking'` (and read `part['thinking']`) to see why a decision was made — useful
when the retro asks "why did the agent choose that", useless as a summary.

## 3. Tool calls with time — what the session actually ran

```bash
python3 - "$SESSION" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding='utf-8'):
    rec = json.loads(line)
    if rec.get('type') != 'message':
        continue
    msg = rec.get('message') or {}
    content = msg.get('content') if isinstance(msg.get('content'), list) else []
    for part in content:
        if isinstance(part, dict) and part.get('type') == 'toolCall':
            args = json.dumps(part.get('arguments') or {}, ensure_ascii=False)
            print(f"[{rec['timestamp'][11:19]}] {part.get('name')}: {args[:160]}")
PY
```

## 4. Tool economy — counts by tool

```bash
python3 - "$SESSION" <<'PY'
import collections, json, sys
counts = collections.Counter()
for line in open(sys.argv[1], encoding='utf-8'):
    rec = json.loads(line)
    msg = rec.get('message') or {}
    content = msg.get('content') if isinstance(msg.get('content'), list) else []
    for part in content:
        if isinstance(part, dict) and part.get('type') == 'toolCall':
            counts[part.get('name')] += 1
print(sum(counts.values()), 'tool calls')
for name, count in counts.most_common():
    print(f'  {count:4d} {name}')
PY
```

This is the number a retro quotes ("456 calls, 330 bash") — and the split that shows which tool to
attack. Add `if 'T14:5' in rec.get('timestamp', '')` style filters to measure one window.

## 5. One time window — what happened between two moments

`$2` and `$3` are `HH:MM` in UTC; tool results are skipped unless `all` is passed as `$4`.

```bash
python3 - "$SESSION" 14:58 15:05 <<'PY'
import json, sys
session, start, end = sys.argv[1], sys.argv[2], sys.argv[3]
with_results = len(sys.argv) > 4 and sys.argv[4] == 'all'
for line in open(session, encoding='utf-8'):
    rec = json.loads(line)
    stamp = (rec.get('timestamp') or '')[11:16]
    if not (start <= stamp <= end) or rec.get('type') != 'message':
        continue
    msg = rec.get('message') or {}
    role = msg.get('role')
    if role == 'toolResult' and not with_results:
        continue
    content = msg.get('content') if isinstance(msg.get('content'), list) else []
    for part in content:
        if not isinstance(part, dict):
            continue
        if part.get('type') == 'toolCall':
            print(f'[{stamp}] {part.get("name")}')
        elif part.get('type') == 'text' and part.get('text', '').strip():
            print(f'[{stamp}] {role}: {part["text"][:160]}')
PY
```

## 6. When did the session last write anything

`mtime` is the moment the log stopped growing; the last record's `timestamp` is the last event. They
usually agree, and a gap between them means the session died or was interrupted.

```bash
python3 - "$SESSION" <<'PY'
import json, os, sys, time
last = None
for line in open(sys.argv[1], encoding='utf-8'):
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    last = rec.get('timestamp') or last
print('last record:', last)
print('file mtime: ', time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(os.path.getmtime(sys.argv[1]))))
PY
```

## 7. All sessions of a project, cheapest first

Start time, last event, line count and tool calls — enough to pick a candidate before reading it:

```bash
python3 - "$SESSIONS" <<'PY'
import glob, json, os, sys
for path in sorted(glob.glob(os.path.join(sys.argv[1], '*.jsonl'))):
    first = last = None
    tools = lines = 0
    for line in open(path, encoding='utf-8'):
        lines += 1
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        first = first or rec.get('timestamp')
        last = rec.get('timestamp') or last
        msg = rec.get('message') or {}
        content = msg.get('content') if isinstance(msg.get('content'), list) else []
        tools += sum(1 for part in content if isinstance(part, dict) and part.get('type') == 'toolCall')
    print(f"{os.path.basename(path)[:32]}  {first} → {last}  строк {lines:5d}  вызовов {tools:4d}")
PY
```

## Counting and arithmetic

Numbers over these logs are `python3`, not `jq`: `jq` is for picking fields, `python3` for sums,
shares and groupings. Same rule as in the project `AGENTS.md`.

## Related

- `skills/retro/SKILL.md` — the retro loop that consumes these recipes.
- `docs/delegation-models.md` — what a fan-out may cost, when the retro asks about spending.

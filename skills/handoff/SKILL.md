---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "What will the next session be used for?"
disable-model-invocation: true
---

Write a handoff document summarising the current conversation so a fresh agent can continue the work. Save to the temporary directory of the user's OS (`$TMPDIR`, else `/tmp`; `%TEMP%` on Windows) - not the current workspace.

Name it so it can be found without asking: `handoff-<issue-or-slug>-<YYYY-MM-DD-HHMM>.md` (e.g. `handoff-15620-2026-11-16-1340.md`). A temp directory is invisible to the next session, so end your reply with the ready-to-paste first line — `Read /tmp/handoff-… and continue` — and nothing else on that line.

Include a "suggested skills" section in the document, naming which skills the next agent should call the Skill tool for.

Do not duplicate content already captured in other artifacts (specs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead.

State the environment as it is now, not as it was when the work started: run the repo's status command (`make epic-status` in msb-lk) and read Redmine/PR state before writing, because other sessions may have landed or superseded parts of this work.

Redact any sensitive information, such as API keys, passwords, or personally identifiable information.

If the user passed arguments, treat them as a description of what the next session will focus on and tailor the doc accordingly.

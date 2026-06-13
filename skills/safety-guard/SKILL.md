---
name: safety-guard
description: Ask for permission before destructive actions and use a concise ACTION/COMMAND/REASON confirmation template. Use when planning deletes, unrecoverable modifications, destructive system changes, git history rewrites/amends, force pushes, or other risky operations.
---

# Safety Guard

Use this skill when a planned action may be destructive and the user has not explicitly requested that destructive action.

## Core Rule

Do not over-ask. Normal recoverable work in a git-tracked codebase can proceed without confirmation.

Ask for permission before destructive actions when recovery is unclear or unavailable, including:

- Deleting files/directories or data.
- Large-scale modifications without a commit, checkpoint, git tracking, or other recovery point.
- Destructive system actions such as uninstalling packages, stopping services, wiping caches outside the project, or privileged system changes.
- Rewriting git history, including `git commit --amend`, rebases, hard resets, and history-filtering commands.
- Force pushes, including `git push --force` and `git push --force-with-lease`.

If the user explicitly and unambiguously asks for the destructive action, proceed without an extra confirmation.

## Confirmation Template

Use `ask_user_question` and coalesce related confirmations into as few questions as possible.

The confirmation text must follow this shape:

```text
ACTION: one-line short but understandable description of the action
COMMAND (if applicable): `<command here>`
REASON (if applicable): One-line reason for performing this action
```

## Disable / Enable

Safety Guard is enforced by the companion Pi extension when installed.

- `/safety enable` turns enforcement on.
- `/safety disable` turns enforcement off.
- `/safety status` shows current state.

Compatibility aliases are also available:

- `/permissions enable`
- `/permissions disable`
- `/permissions status`

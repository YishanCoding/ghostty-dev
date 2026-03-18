---
name: progress-update
description: Automatically update the Ghostty progress log when tasks change status
triggers:
  - when starting a task or major step
  - when completing a task or major step
---

# Progress Update Skill

When working inside a Ghostty Dev terminal session, report task status changes to the progress log so the Swift UI can display them in real time.

## How to Report Progress

Use the `ghostty_progress.py` CLI to append entries. The session name comes from the `$AGENT_BROWSER_TABNAME` environment variable.

```bash
python3 ~/.claude/scripts/ghostty_progress.py append "$AGENT_BROWSER_TABNAME" "<emoji> <message>"
```

## When to Report

- **Starting a task or major step:** append with 🔄 emoji
- **Completing a task or major step:** append with ✅ emoji

## Format

Each entry is automatically timestamped by the CLI. Just provide the emoji and a concise description:

```bash
# Starting work
python3 ~/.claude/scripts/ghostty_progress.py append "$AGENT_BROWSER_TABNAME" "🔄 Implementing user authentication"

# Completed work
python3 ~/.claude/scripts/ghostty_progress.py append "$AGENT_BROWSER_TABNAME" "✅ User authentication complete"
```

## Guard

Only call the script when `$AGENT_BROWSER_TABNAME` is set (i.e., running inside a Ghostty Dev CC session). Skip silently if the variable is empty.

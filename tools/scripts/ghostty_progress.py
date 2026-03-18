#!/usr/bin/env python3
"""Ghostty progress log CLI.

Usage:
    ghostty_progress.py append <session> <message>
    ghostty_progress.py clear <session>
    ghostty_progress.py list <session>
    ghostty_progress.py sessions
"""
import sys, os, time
from pathlib import Path

DIR = Path("/tmp/ghostty-progress")


def get_file(session: str) -> Path:
    DIR.mkdir(parents=True, exist_ok=True)
    return DIR / f"{session}.log"


def append(session: str, message: str):
    ts = time.strftime("%H:%M")
    line = f"{ts} | {message}\n"
    with open(get_file(session), "a") as f:
        f.write(line)


def clear(session: str):
    f = get_file(session)
    if f.exists():
        f.write_text("")


def list_entries(session: str):
    f = get_file(session)
    if f.exists():
        print(f.read_text(), end="")


def sessions():
    if DIR.exists():
        for f in sorted(DIR.glob("*.log")):
            print(f.stem)


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] == "help":
        print(__doc__)
        sys.exit(0)
    cmd = args[0]
    if cmd == "append" and len(args) >= 3:
        append(args[1], " ".join(args[2:]))
    elif cmd == "clear" and len(args) >= 2:
        clear(args[1])
    elif cmd == "list" and len(args) >= 2:
        list_entries(args[1])
    elif cmd == "sessions":
        sessions()
    else:
        print(__doc__)
        sys.exit(1)

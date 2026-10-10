#!/usr/bin/env python3
"""Cline PreToolUse guard (global hook).

On 2026-10-06 a Cline run in a project worktree killed every eslint,
vitest, tsc and prettier process it found with `ps | grep … | xargs kill -9`.
That included other jobs' gate runs. This hook refuses any shell command that
signals processes or touches the shared git stash, before it runs.

Contract (verified against @cline/core 3.0.68 dist):
- stdin: JSON with `tool_call: { name, input }` (real types) and
  `preToolUse: { toolName, parameters }` (every value stringified).
- The shell tool is `run_commands` with `input.commands: [str, ...]`.
- stdout `{"cancel": true}` maps to `stop` and aborts the whole run, so this hook
  returns `overrideInput` instead: the batch becomes a command that prints the
  refusal and exits 1, and the run continues.

Fails open on unreadable input, so a payload change never wedges Cline.
"""
import json
import re
import shlex
import sys

# A command word in command position: start of line, or after ; & | ( ` $( or
# a wrapper such as xargs/sudo/nohup/timeout/exec/env/nice. Plain mentions of
# the word inside a search string (rg "kill" …) do not match, and neither does a
# grep alternation such as `\|skill-scope` (an escaped pipe is not a pipe).
_LEAD = r"(?:^|(?<!\\)[;&|(`\n]|\$\()\s*(?:(?:sudo|nohup|exec|env|nice|time|command|xargs(?:\s+-\S+)*|timeout\s+\S+)\s+)*"
_KILL = re.compile(_LEAD + r"(?:/usr/bin/|/bin/)?(?:kill|pkill|killall|xkill)\b")
_FUSER_KILL = re.compile(_LEAD + r"fuser\b[^;&|\n]*\s-[a-zA-Z]*k")
_GIT_STASH = re.compile(_LEAD + r"git(?:\s+-\S+(?:\s+\S+)?)*\s+stash\b")

RULES = (
    (_KILL, "Signalling processes (kill/pkill/killall) is not allowed: other jobs on this machine "
            "run vitest, tsc and eslint too, and killing them breaks their work. Wait for your own "
            "command to finish instead, even if a test suite takes several minutes."),
    (_FUSER_KILL, "fuser -k kills processes and is not allowed. Wait for your own command instead."),
    (_GIT_STASH, "git stash is not allowed: the stash stack is shared by every worktree of the "
                 "repository. Commit work in progress instead."),
)


def _strings(value):
    """Command strings from a list, a plain string, or a JSON-encoded list.

    `preToolUse.parameters` stringifies every value (`commands` arrives as
    '["kill -0 1"]'), while `tool_call.input` keeps the real list. Both are read.
    """
    if isinstance(value, list):
        return [v for v in value if isinstance(v, str)]
    if isinstance(value, str):
        text = value.strip()
        if text.startswith("["):
            try:
                decoded = json.loads(text)
            except ValueError:
                return [value]
            if isinstance(decoded, list):
                return [v for v in decoded if isinstance(v, str)]
        return [value]
    return []


def _commands(payload):
    sources = []
    call = payload.get("tool_call") or {}
    if isinstance(call.get("input"), dict):
        sources.append(call["input"])
    pre = payload.get("preToolUse") or {}
    if isinstance(pre.get("parameters"), dict):
        sources.append(pre["parameters"])
    found = []
    for params in sources:
        for key in ("commands", "command", "cmd"):
            found.extend(_strings(params.get(key)))
    return found


def main():
    raw = sys.stdin.read() or "{}"
    try:
        payload = json.loads(raw)
    except ValueError:
        return
    if not isinstance(payload, dict):
        return
    for command in _commands(payload):
        for pattern, message in RULES:
            if pattern.search(command):
                text = f"BLOCKED by PreToolUse guard: {message} Blocked command: {command[:200]}"
                # Not `cancel`: in cline 3.0.68 that maps to `stop` and aborts the whole
                # run. `overrideInput` replaces the batch with a harmless command that
                # prints the refusal and fails, so the model reads why and carries on;
                # `errorMessage` (without cancel) is appended to the model's context.
                replacement = f"printf '%s\\n' {shlex.quote(text)} >&2; exit 1"
                print(json.dumps({"overrideInput": {"commands": [replacement]}, "errorMessage": text}))
                return


if __name__ == "__main__":
    main()

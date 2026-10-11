# cline-delegate

A Claude Code plugin for handing implementation and review work to the
[Cline CLI](https://github.com/cline/cline). Claude writes the plan and every
brief, then `cline --yolo --json` does the typing in a git worktree. Claude
reads a one-screen verdict of the run, re-runs the project's gates itself, and
merges.

It is the `opencode-driven-development` loop from
[opencode-delegate](https://github.com/Sighton-GH/opencode-delegate) with
Cline in the implementer and reviewer seats. Use it when you'd rather spend a
free Cline model's quota than Claude's, or when opencode is rate-limited.

This repo is also a Claude Code plugin marketplace.

## What's in it

| Piece | What it does |
|---|---|
| `cline-delegate` skill | When and how to dispatch Cline: the launch command, how to route on the result, what to check after every run, and how it differs from `oc-task`. |
| `cline-summary <log> --cwd <dir>` | Reads a `cline --json` NDJSON log and prints one JSON object: `status`, `result_status`, `review`, `cost`, `model`, edited files, files edited **outside** the worktree, risky commands it ran, and more. Read-only: it never starts Cline. Exit 0 = completed, 1 = finished some other way, 2 = no result (crash, sign-in failure, network). |
| `cline-guard check\|install` | Installs a **Cline** `PreToolUse` hook (`cline-hooks/PreToolUse.py`) that refuses `kill`, `pkill`, `killall`, `fuser -k` and `git stash` before Cline runs them. The run carries on with a refusal message instead of aborting. |

Why the guard exists: a Cline run waiting on slow tests once ran
`ps | grep … | xargs kill -9` and took out every vitest, tsc and eslint
process on the machine, other jobs' included. `git stash` is refused because
every worktree of a repo shares one stash stack.

## Requirements

- **Cline CLI 3.x**, installed and signed in: `npm i -g cline`, then
  `cline auth`. Verified on 3.0.68 with the free ClinePass model.
- **python3** (3.10 or newer) for `cline-summary` and `cline-guard`.
- **[opencode-delegate](https://github.com/Sighton-GH/opencode-delegate)**,
  recommended. The skill reuses its plan and brief templates and its review
  loop.

## Install

From inside Claude Code 2.1.275 or later, one command adds the marketplace
and installs the plugin:

```
/plugin install cline-delegate --marketplace Sighton-GH/cline-delegate
```

On an older Claude Code, run these two commands one at a time — paste the
first, wait for it to finish, then paste the second.

1. Add the marketplace:

   ```
   /plugin marketplace add Sighton-GH/cline-delegate
   ```

2. Install the plugin:

   ```
   /plugin install cline-delegate
   ```

Start a new session so the plugin loads, then install the Cline guard:

```
cline-guard install
```

It writes `~/Documents/Cline/Hooks/PreToolUse.py`. Set `$CLINE_HOOKS_DIR` to
use a different hooks directory. If a different `PreToolUse.py` is already
there, it stops instead of overwriting it; `--force` replaces it and keeps the
old one as `PreToolUse.py.bak`. Run `cline-guard check` any time: exit 0 means
the guard is installed and current.

### Let auto mode run Cline

Claude Code's auto mode correctly blocks `cline --yolo`, because it starts a
third-party agent with per-action approval turned off. To opt in, add a scoped
rule to `autoMode.allow` in `~/.claude/settings.json`, keeping `"$defaults"`:

```json
"autoMode": {
  "allow": [
    "$defaults",
    "Cline delegation: running the Cline CLI (`cline --yolo --json -c <dir> ...`), a third-party coding agent with per-action approval disabled, is allowed when -c names a git worktree under a repo's .claude/worktrees/ or a scratch directory under ~/.claude/jobs/, and the prompt only tells it to read a brief file. The owner delegates implementation to Cline deliberately; Claude reviews every diff and runs the gates before anything merges. Never with -c at a main checkout or the home directory."
  ]
}
```

The rule has to be in `autoMode.allow`: the **Auto mode** tab in
`/permissions`, not the regular Allow tab. Check that it landed with
`claude auto-mode config | jq '.allow[-1]'`.

Without the rule, the skill tells Claude to stop and hand you the command to
run yourself as `! <command>`.

## Use

Ask Claude to have Cline do the work, for example: "use Cline to implement
task 3 of the plan", or "have Cline review this branch". The skill covers
the rest: making the worktree, writing the brief file, launching Cline with a
clean environment, summarising the log, checking cost and stray edits,
re-running the gates and merging.

## Safety notes

- `--yolo` auto-approves every shell command. The skill only ever points
  `-c` at a git worktree or a scratch directory, never a main checkout.
- Cline inherits its caller's environment. The skill launches it through
  `env -i` (or `unset` in an isolated session), so Claude Code's tokens don't
  reach Cline.
- Briefs are sent to Cline's model provider. Keep secrets out of them.
- Never trust Cline's own report. Claude re-runs the tests itself.

## Develop

```
git clone https://github.com/Sighton-GH/cline-delegate.git
cd cline-delegate
```

Then, from the clone, register it (one command at a time):

```
claude plugin marketplace add "$PWD"
```

```
claude plugin install cline-delegate@cline-delegate
```

Before committing:

```
bash plugins/cline-delegate/tests/run.sh
```

```
claude plugin validate ./plugins/cline-delegate --strict
```

```
claude plugin validate . --strict
```

To ship a change, bump `version` in both
`plugins/cline-delegate/.claude-plugin/plugin.json` and
`.claude-plugin/marketplace.json`. `claude plugin update` only refetches when
the version changes. Users then run these one at a time:

```
claude plugin marketplace update cline-delegate
```

```
claude plugin update cline-delegate
```

## License

MIT

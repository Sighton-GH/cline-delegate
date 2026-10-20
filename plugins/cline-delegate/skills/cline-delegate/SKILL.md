---
name: cline-delegate
description: Use when the user asks to have Cline (the cline CLI) implement, fix or review something, or wants Cline used as the implementer or reviewer in a plan-driven workflow like opencode-driven-development, including when opencode or its model is rate-limited or unavailable.
---

# cline-delegate

Cline CLI 3.x has a real headless mode: `cline --yolo --json` runs one task with every tool auto-approved, streams NDJSON events, and exits when the model calls `submit_and_exit`. You write the brief, Cline does the typing, you verify and merge. This plugin puts two commands on the Bash tool's PATH:

- `cline-summary <log> --cwd <dir>` turns the event log into a one-screen verdict. It only reads the log and never starts Cline.
- `cline-guard check|install` checks or installs the Cline kill guard (see Rules).

**Prerequisites:** the `cline` CLI (3.x) installed and signed in with `cline auth`, and the `opencode-delegate` plugin for the brief templates.

**REQUIRED BACKGROUND:** `opencode-delegate:opencode-driven-development`. For plan-sized work, follow that skill's whole loop (plan, ledger, brief templates, review, fix rounds, final review, finish). Swap the seat as described in "Differences from oc-task" below.

## Permission: auto mode blocks this until the user allows it

The auto-mode classifier blocks `cline --yolo` as **[Create Unsafe Agents]**: a third-party agent with per-action approval turned off. That block is correct until the user opts in. The opt-in is an `autoMode.allow` entry in `~/.claude/settings.json`, keeping `"$defaults"` in the list:

```json
"autoMode": {
  "allow": [
    "$defaults",
    "Cline delegation: running the Cline CLI (`cline --yolo --json -c <dir> ...`), a third-party coding agent with per-action approval disabled, is allowed when -c names a git worktree under a repo's .claude/worktrees/ or a scratch directory under ~/.claude/jobs/, and the prompt only tells it to read a brief file. The owner delegates implementation to Cline deliberately; Claude reviews every diff and runs the gates before anything merges. Never with -c at a main checkout or the home directory."
  ]
}
```

If a `cline` call is denied:
1. Stop. Do not reach the same outcome another way: no `--auto-approve true`, no `--zen`, no wrapper script, no subagent that runs it.
2. Give the user the exact command to run themselves as `! <command>`, and point them at the block above.
3. After they run it, carry on from the summary step.

## Run one task

```bash
CLEAN_ENV=(env -i HOME="$HOME" PATH="$PATH" USER="$USER" TERM=dumb LANG="${LANG:-C.UTF-8}")
"${CLEAN_ENV[@]}" cline --yolo --json -c <worktree-abs-path> -m <model> -t <seconds> \
  "Your working directory is <worktree-abs-path>; never cd anywhere else. Read <brief-abs-path> and do exactly what it says. Your submit_and_exit summary must contain the brief's ## RESULT block verbatim." \
  > <job-tmp>/<task>.ndjson 2>&1
cline-summary <job-tmp>/<task>.ndjson --cwd <worktree-abs-path>

# review runs: the same act-mode command (not -p), pointed at a review brief (see "Differences from oc-task")
"${CLEAN_ENV[@]}" cline --yolo --json -c <worktree-abs-path> -m <model> -t <seconds> \
  "Your working directory is <worktree-abs-path>; never cd anywhere else. This is a read-only review: do not create, edit or delete any file, and do not commit. Read <review-brief-abs-path> and do exactly what it says. Finish by calling submit_and_exit; its summary must contain the brief's ## RESULT block verbatim." \
  > <log> 2>&1
```

- **Always pass `-m <model>`.** `-m` (with or without `-P`) is saved as that provider's default in `~/.cline/data/settings/providers.json`, so a later launch without it silently runs whatever the last run picked. After a run with paid `-P cline -m meta/muse-spark-1.3-contributor`, a launch with no `-m` ran paid Muse ($0.17). After a smoke test of every model, the default was whichever model came last. Check `model` and `cost` in the summary after every run.
- **Pin the working directory in the prompt** (the first sentence above). On 2026-10-17, with only "Read <main-checkout>/.oc-runs/.../brief.md and do exactly what it says", two runs `cd`'d into the main checkout, where the brief lived, and ran `git add -A && git commit` there, committing the owner's untracked files. Two other runs with the same prompt stayed put. If the brief lives in another checkout, add: "<that checkout> is a different checkout: read the brief there, touch nothing else." After every run, check `edited_outside_cwd`, plus `git -C <main-checkout> status --short` and `log -1`.
- **Launch long runs with the Bash tool's `run_in_background`, not a trailing `&`.** A run started with `&` inside a foreground call sends no completion notification. If one is already running that way, start a background waiter: `until ! pgrep -f "<unique part of its command line, e.g. the worktree name>" >/dev/null; do sleep 30; done`.

- **Always launch through `env -i`.** Cline's shell inherits the caller's whole environment. Launched from Claude Code that includes `CLAUDE_CODE_MESSAGING_TOKEN` and `VSCODE_CLI_REQUIRE_TOKEN` (62 variables in all), handed to an agent with every command auto-approved. Under `env -i` it sees 11 and still signs in, because its auth lives in `~/.cline`. Verified 2026-10-04.
- **If the session is itself worktree-isolated, use `unset` instead.** There the approver refuses `env -i HOME=… cline …` (setting `HOME` looks like injecting git configuration, and the expansions are "too complex") and `env -u A -u B cline …`. This shape is accepted: `unset <NAME> <NAME> … && cline --yolo --json -c <worktree> -t <s> "<prompt>" > <log> 2>&1`. Get the names, never the values, from `env | cut -d= -f1 | grep -i -E 'token|key|secret|claude|vscode|session'`. Cline keeps the real `HOME`, which it needs for `~/.cline`.
- **Ask for the RESULT block inside the summary.** Cline ends with `submit_and_exit({summary, verified})`, and `report` is that summary, not its last message. Without the sentence above, a model that follows the brief can still submit a prose summary with no `## RESULT`, and `result_status` comes back null.

- Put the brief and the log outside the worktree, in `.oc-runs/<slug>/` (or `$CLAUDE_JOB_DIR/tmp` for a one-off), never the shared `/tmp`. Inside the worktree they would show up in the diff.
- Run it with the Bash tool's maximum timeout (600000 ms), or in the background for long tasks, and set `-t` below that.

The summary prints `status`, `result_status` (the `## RESULT` `Status:` line), `review` (`Verdict:`/`Spec:`/`Quality:` from a review's RESULT block), `submit_verified` (Cline's own claim that it verified; false means it said it didn't), `flagged_commands` (risky commands it ran: `git stash`, `git push`, `git reset --hard`, installs, `curl`, `rm -rf`), `model`, `provider`, `cost`, `edited`, `edited_outside_cwd`, `commands`, `errors`, `stray` and `report`.

| exit | `status` | action |
|---|---|---|
| 0 | `completed` | Route on `result_status` exactly as opencode-driven-development routes `Status:`; for review runs route on `review`. If both are null, the model skipped the RESULT block: read `git diff` and treat it as DONE_WITH_CONCERNS. |
| 1 | anything else | Read `report` and `errors`. Partial edits may exist; inspect the tree before re-dispatching. |
| 2 | `no_result` | Cline crashed, was killed, or never started. Read `stray`: sign-in errors mean the user runs `! cline auth`; `fetch failed` or timeouts mean a network problem, often a far VPN server. |

**After every run, check these whatever the exit code:**
- `cost` is above 0 or `model` isn't a free model → stop and tell the user.
- `edited_outside_cwd` isn't empty → stop and tell the user.
- `flagged_commands` isn't empty → read each one. A `git stash` touches the stash stack every worktree of the repo shares: run `git stash list` and make sure nothing was left behind or taken from another session.
- Read `commands` for anything else outside the brief (network calls, edits through shell redirection).

## Models and daily caps

ClinePass offers several free models, and **each has its own daily cap**. All four of these ran a smoke test at cost 0 with `-m` (2026-10-19, cline 3.0.73):

- `cline-free/muse-spark-1.3-contributor`
- `cline-free/minimax-m3.1-flash`
- `cline-free/mimo-v2.6-flash`
- `cline-free/nemotron-3.5-super-vl`

- **The cap signal.** The run ends `status: error`, exit 1, with no RESULT block and this in `errors`/`report`: `INFERENCE_CAP_ERROR: Error 429: Daily free limit reached on model <model>. Try again in <time>`. A run dispatched after the cap fails within a second, with no edits.
- **On a cap,** tell the user right away, as its own line at the top of your message: they may want to reset or swap the account. Commit any uncommitted edits in the worktree as a WIP checkpoint. Then either move the task to another free model, using the original brief plus "a prior run committed steps 1–N; continue from step N+1", or wait for the reset.
- **The cap seems to count input tokens.** One heavy implement run used 2.2 M input tokens and spent a whole day's Muse allowance in 14 minutes. A whole-branch review of a 900 KB diff read 6.5 M. A reset lasts roughly 25–40 minutes of heavy work. Keep briefs token-lean: `rg` plus `sed -n` line ranges, no whole-file reads of large files, and a commit after every step so a cap mid-task loses nothing. Send whole-branch reviews to a model whose cap you can spare.
- **Paid models** run with `-P cline -m <model>`, for example `meta/muse-spark-1.3-contributor` at about $0.10 per million input tokens. `cline-summary`'s `cost` undercounts: a $0.50 credit ran out at $0.31 of logged cost. Budget about 60% of the stated credit, and use paid runs only for tight fix briefs. Then pass the free `-m` again explicitly on the next launch (see "Always pass `-m`").

## Differences from oc-task

| opencode-driven-development | with Cline |
|---|---|
| `oc-task` creates `.oc-worktrees/<branch>` | You create it: `git -C <repo> worktree add <repo>/.claude/worktrees/cline-<slug> -b cline/<slug> [<start>]`. If the repo doesn't ignore `.claude/worktrees/`, add it to `<repo>/.git/info/exclude` rather than editing the tracked `.gitignore`. Link `node_modules` if the gates need it. To take over a plan an opencode run started, pass its branch (`oc/<slug>`) as `<start>`: the allow rule names `.claude/worktrees/`, so the `.oc-worktrees/` checkout can't be reused. Worktree copies inside the repo get picked up by `eslint .` and the like; add `.claude` and `.oc-worktrees` to the linter's ignores. |
| `--session ID` resumes a fix round | No resume flag exists in 3.0.68. Every dispatch is fresh: fix briefs carry the original brief path plus the findings verbatim. |
| `--role review` (read-only agent) | Its own brief, written from `task-reviewer-brief.md` (or `re-review-brief.md` / `final-reviewer-brief.md`) with the absolute path of a diff file you write with `git -C <wt> diff <base>..HEAD > .oc-runs/<slug>/task-N.diff`. Never re-send the implementer brief. Dispatch it in act mode with the review prompt above (a read-only line plus "finish by calling submit_and_exit"), not `-p`. On 2026-10-19, a `-p` whole-branch review read everything over 58 iterations, then ended `completed` with "composing the final report with the required RESULT block". It never called `submit_and_exit`, so `result_status` and `review` were null and the findings existed only in its reasoning. Neither mode is enforced read-only, so run `git -C <wt> status --short` before and after. If a review changed files, stop and tell the user. |
| `oc-task --merge` audits files against each brief | You audit: `git -C <wt> diff --name-only <base>..HEAD` must sit inside the briefs' `# Files` lists. Then run the gates and merge with `superpowers:finishing-a-development-branch`. |
| `oc-models --free` | Pick from the free list in "Models and daily caps" and pass it with `-m` on every launch. The summary's `model` is the record. Ledger it. |
| Exit 5 rate limit | `INFERENCE_CAP_ERROR` … "Daily free limit reached on model …" in `errors` (see "Models and daily caps"). Stop and tell the user. Another free model has its own cap; don't retry the same one on your own. Any other `no_result` or error that mentions quota or rate: stop and tell the user. |

Brief templates live in `~/.claude/plugins/cache/opencode-delegate/opencode-delegate/*/skills/opencode-driven-development/`. Use them unchanged, including the commit-per-step and `## RESULT` blocks.

## Rules

- **One Cline run per worktree at a time.** Parallel runs on separate worktrees are untested, so run one at a time until a test shows they're safe.
- **The kill guard must be installed.** Run `cline-guard check` before a plan-sized dispatch; exit 1 means run `cline-guard install`. Exit 3 means a locally edited copy is installed: diff the two files it names, and carry on if only messages differ; if a rule is missing, tell the user. It puts this plugin's `cline-hooks/PreToolUse.py` at `~/Documents/Cline/Hooks/PreToolUse.py` (or `$CLINE_HOOKS_DIR`), a global Cline hook that refuses `kill`, `pkill`, `killall`, `fuser -k` and `git stash` before they run. On 2026-10-06 a Cline run, waiting on slow gates, `kill -9`'d every vitest, tsc and eslint process on the box, including other jobs' gate runs.
  - The hook answers with `overrideInput`: the command becomes a printed refusal that exits 1, and the run continues.
  - It never returns `cancel: true`, because in 3.0.68 that aborts the whole run.
  - Hooks read `tool_call.input`. `preToolUse.parameters` stringifies its values.
  - Keep one copy only; `~/.cline/hooks` is also searched, and two copies run twice (`cline-guard check` exits 4).
  - After upgrading Cline, re-run a one-line smoke ("run `kill -0 1`, then `echo after`") and confirm the refusal shows and the run completes.
- **Every brief also forbids killing processes and writing to `/tmp`.** This is the soft layer behind the hook: other jobs share this machine, and `/tmp` is shared.
- **Briefs are files.** No secrets, tokens or server data in a brief: the content goes to Cline's provider.
- **You verify.** Re-run the brief's verification command and the project's gates yourself, where the project's notes say gates are valid. Never trust `report`.
- **Every brief forbids `git stash`.** Add this line to the brief's Constraints: `Never run git stash; commit work in progress instead (the stash stack is shared by every worktree).` Muse ran `git stash -u` / `git stash pop` on its own in a worktree to check whether a failing test predated its change.
- **Don't trust Cline's explanations.** It reported a test failure as "pre-existing, GEMINI_API_KEY present in env"; that variable was never in its environment, and the suite passed when re-run. Reviewer prose also slips (it said a removed prop was "kept" and named a helper that doesn't exist). Spot-check any claim the verdict leans on, and re-run anything it calls pre-existing.
- **No `--zen`** (it exits before the work finishes, so there's no result to read) and **no `--data-dir`** (untested; it switches to isolated state).

## Common mistakes

| Mistake | Fix |
|---|---|
| Re-routing around a denied `cline` call | Stop, hand the user the `!` command, point at the permission block. |
| `-c` at the main checkout | Always a worktree or scratch directory: `--yolo` approves every shell command. |
| Trusting "2 pass, 0 fail" in `report` | Run the tests yourself. |
| Brief and log inside the worktree | Keep them outside, or they land in the diff and the file audit. |
| Launching `cline` without `env -i` or `unset` | Tokens in the caller's environment reach an auto-approved agent. Use `CLEAN_ENV`, or the `unset … &&` form in an isolated session. |
| Bare "Read X and do exactly what it says" prompt | Add the working-directory sentence and the RESULT-in-summary sentence, or the run may commit in another checkout and `result_status` may come back null. |
| Launching without `-m` | The last `-m` used is the saved default, which may be paid or a different model. Pass it every time. |
| Review dispatched with `-p` | Plan mode may end without `submit_and_exit`. Use act mode with the read-only line. |
| Retrying a capped model | Its cap lasts until the reset time in the error. Tell the user, then use another free model. |

## Smoke test (after changing `cline-summary` or upgrading cline)

Make a scratch git repo under `~/.claude/jobs/` with a `brief.md` asking for `add.mjs` plus a `node:test` file, two cases, no commit, and a step `printenv | cut -d= -f1 | sort > envnames.txt` (names only). Run the command above, then the summary. Expect exit 0, `status: completed`, `result_status: DONE`, `submit_verified: true`, nothing in `edited_outside_cwd` or `flagged_commands`, no `KEY`/`TOKEN`/`SECRET` names in `envnames.txt`, and `node --test` passing when you run it yourself.

Last verified 2026-10-04 on cline 3.0.68, run by Claude in auto mode with the `autoMode.allow` entry in place: the smoke test above passed both with and without `env -i` (model `cline-free/muse-spark-1.3-contributor`, provider `cline-pass`, cost 0, `result_status: DONE`). Without `env -i` the agent saw 2 token variables; with it, none.

Field record (2026-10-04): a fix round finished in 77 s over 9 iterations and a 2,880-line whole-branch review in 166 s over 22, both free. Plan mode stayed read-only (same HEAD, clean tree). Muse Spark through Cline kept working while Muse through opencode was rate limited, so the two appear to use separate quotas.

The rule must sit in `autoMode.allow` (the `/permissions` **Auto mode** tab). Added on the regular Allow tab, it lands in `permissions.allow`, where prose is treated as a tool pattern and does nothing. Check with `claude auto-mode config | jq '.allow[-1]'`.

Field record (2026-10-17 to 2026-10-19, cline 3.0.73): the free Muse cap was hit four times, each after 14–40 minutes of heavy work. The four free models in "Models and daily caps" each passed a no-cost smoke test with `-m`. A `-p` review ended without `submit_and_exit`; the act-mode re-run with the read-only line produced its RESULT block and left the tree clean.

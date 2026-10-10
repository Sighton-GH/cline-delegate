#!/usr/bin/env bash
# No-network tests for cline-summary, cline-guard and the Cline PreToolUse guard.
# Usage: bash plugins/cline-delegate/tests/run.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
FIX="$HERE/fixtures"
SUMMARY="$ROOT/bin/cline-summary"
GUARD_CLI="$ROOT/bin/cline-guard"
HOOK="$ROOT/cline-hooks/PreToolUse.py"
pass=0 fail=0

check() { # check NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
field() { python3 -c 'import json,sys; v=json.load(sys.stdin); [v:=v[k] if isinstance(v,dict) else v[int(k)] for k in sys.argv[1].split(".") if k]; print(json.dumps(v))' "$1"; }

# --- cline-summary ---------------------------------------------------------
out="$("$SUMMARY" "$FIX/completed.ndjson" --cwd /work)"; code=$?
check "completed exit" 0 "$code"
check "completed status" '"completed"' "$(field status <<<"$out")"
check "completed result_status" '"DONE"' "$(field result_status <<<"$out")"
check "completed submit_verified" 'true' "$(field submit_verified <<<"$out")"
check "completed flagged" '[]' "$(field flagged_commands <<<"$out")"
check "completed outside" '[]' "$(field edited_outside_cwd <<<"$out")"
check "completed cost" '0' "$(field cost <<<"$out")"

out="$("$SUMMARY" "$FIX/risky.ndjson" --cwd /work)"; code=$?
check "risky exit" 1 "$code"
check "risky flagged" '["git stash -u"]' "$(field flagged_commands <<<"$out")"
check "risky outside" '["/etc/hosts"]' "$(field edited_outside_cwd <<<"$out")"
check "risky review" '{"Verdict": "CHANGES_REQUESTED", "Spec": "FAIL", "Quality": "PASS"}' "$(field review <<<"$out")"
check "risky errors" '1' "$(field errors <<<"$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

out="$("$SUMMARY" "$FIX/crashed.ndjson")"; code=$?
check "crashed exit" 2 "$code"
check "crashed status" '"no_result"' "$(field status <<<"$out")"
check "crashed stray" '["Error: Not authenticated. Run `cline auth`."]' "$(field stray <<<"$out")"

"$SUMMARY" >/dev/null 2>&1; check "summary usage exit" 64 "$?"

# --- PreToolUse guard ------------------------------------------------------
hook() { printf '%s' "$1" | python3 "$HOOK"; }
blocked() { [ -n "$(hook "$1")" ] && echo blocked || echo allowed; }
call() { python3 -c 'import json,sys; print(json.dumps({"tool_call":{"name":"run_commands","input":{"commands":[sys.argv[1]]}}}))' "$1"; }

check "kill blocked" blocked "$(blocked "$(call 'kill -9 1234')")"
check "pkill blocked" blocked "$(blocked "$(call 'pkill vitest')")"
check "xargs kill blocked" blocked "$(blocked "$(call 'ps aux | grep tsc | xargs kill -9')")"
check "fuser -k blocked" blocked "$(blocked "$(call 'fuser -k 3000/tcp')")"
check "git stash blocked" blocked "$(blocked "$(call 'git -C /w stash -u')")"
check "rg kill allowed" allowed "$(blocked "$(call 'rg "kill" src')")"
check "grep alternation allowed" allowed "$(blocked "$(call 'grep -n "a\|skill-scope" f')")"
check "npm test allowed" allowed "$(blocked "$(call 'npm test')")"
check "bad json allowed" allowed "$(blocked 'not json')"
check "stringified params blocked" blocked "$(blocked '{"preToolUse":{"toolName":"run_commands","parameters":{"commands":"[\"killall node\"]"}}}')"
reply="$(hook "$(call 'kill 1')")"
check "reply uses overrideInput, never cancel" 'yes' "$(python3 -c 'import json,sys; r=json.loads(sys.argv[1]); print("yes" if "overrideInput" in r and "cancel" not in r else "no")' "$reply")"
sh -c "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["overrideInput"]["commands"][0])' "$reply")" 2>/dev/null
check "override command exits 1" 1 "$?"

# --- cline-guard -----------------------------------------------------------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CLINE_HOOKS_DIR="$tmp/hooks" HOME="$tmp/home"
"$GUARD_CLI" check >/dev/null 2>&1; check "guard missing" 1 "$?"
"$GUARD_CLI" install >/dev/null 2>&1; check "guard install" 0 "$?"
"$GUARD_CLI" check >/dev/null 2>&1; check "guard ok" 0 "$?"
echo '# local edit' >> "$tmp/hooks/PreToolUse.py"
"$GUARD_CLI" check >/dev/null 2>&1; check "guard differs" 3 "$?"
"$GUARD_CLI" install >/dev/null 2>&1; check "guard refuses overwrite" 3 "$?"
"$GUARD_CLI" install --force >/dev/null 2>&1; check "guard force" 0 "$?"
check "guard backup kept" yes "$([ -f "$tmp/hooks/PreToolUse.py.bak" ] && echo yes || echo no)"
mkdir -p "$tmp/home/.cline/hooks" && cp "$HOOK" "$tmp/home/.cline/hooks/PreToolUse.py"
"$GUARD_CLI" check >/dev/null 2>&1; check "guard duplicate" 4 "$?"
"$GUARD_CLI" bogus >/dev/null 2>&1; check "guard usage" 64 "$?"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

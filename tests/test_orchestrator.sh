#!/usr/bin/env bash
# test_orchestrator.sh — Tests fuer devil-advocate-swarms orchestrator.sh
# Aufruf: bash devil-advocate-swarms/tests/test_orchestrator.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_SCRIPT="$SCRIPT_DIR/../scripts/orchestrator.sh"
PASS=0
FAIL=0
TOTAL=0

assert_exit() {
    local desc="$1" expected_exit="$2"
    shift 2
    local actual_exit=0
    "$@" > /dev/null 2>&1 || actual_exit=$?
    TOTAL=$((TOTAL + 1))
    if [[ "$expected_exit" == "$actual_exit" ]]; then
        echo "[PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $desc — expected exit $expected_exit, got $actual_exit"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "[PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $desc — '$needle' not found in output"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if ! echo "$haystack" | grep -qF -- "$needle"; then
        echo "[PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $desc — unexpected '$needle' found in output"
        FAIL=$((FAIL + 1))
    fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== test_orchestrator.sh (devil-advocate-swarms) ==="
echo "Temp dir: $TMPDIR"
echo ""

# Test 1: No arguments shows error and exits 1
OUTPUT=$(bash "$ORCH_SCRIPT" 2>&1 || true)
assert_contains "no args shows error" "--target and --goal are required" "$OUTPUT"
assert_exit "no args exits 1" 1 bash "$ORCH_SCRIPT"

# Test 2: --help exits 0
assert_exit "--help exits 0" 0 bash "$ORCH_SCRIPT" --help

# Test 3: --help shows usage and examples
OUTPUT=$(bash "$ORCH_SCRIPT" --help 2>&1)
assert_contains "--help shows usage" "Usage:" "$OUTPUT"
assert_contains "--help shows examples" "Examples:" "$OUTPUT"

# Test 4: Unknown argument exits 1
assert_exit "unknown arg exits 1" 1 bash "$ORCH_SCRIPT" --bogus

# Test 5: --target without --goal exits 1
assert_exit "target without goal exits 1" 1 bash "$ORCH_SCRIPT" --target /tmp

# Test 6: --goal without --target exits 1
assert_exit "goal without target exits 1" 1 bash "$ORCH_SCRIPT" --goal "test"

# Test 7: --scanners capped at 5 (timeout 5s — will try to run claude after banner)
OUTPUT=$(timeout 5 bash "$ORCH_SCRIPT" --target /tmp --goal "test" --scanners 10 2>&1 || true)
assert_contains "scanners capped at 5" "Capping scanners at 5" "$OUTPUT"

# Test 8: --no-fix flag accepted (timeout 5s — reaches orchestrator banner)
OUTPUT=$(timeout 5 bash "$ORCH_SCRIPT" --target /tmp --goal "test" --no-fix 2>&1 || true)
assert_contains "no-fix reaches orchestrator" "Devil's Advocate Swarm" "$OUTPUT"

# Test 9: extract_json unwraps claude wrapper
EXTRACTED=$(echo '{"result": "{\"key\": \"value\"}"}' | python3 -c "
import json, re, sys
text = sys.stdin.read()
try:
    wrapper = json.loads(text)
    if 'result' in wrapper:
        text = wrapper['result']
except (json.JSONDecodeError, TypeError):
    pass
text = re.sub(r'\x60{3}json\s*', '', text)
text = re.sub(r'\x60{3}\s*', '', text)
match = re.search(r'\{.*\}', text, re.DOTALL)
if match:
    try:
        obj = json.loads(match.group())
        print(json.dumps(obj, indent=2))
        sys.exit(0)
    except json.JSONDecodeError:
        pass
sys.exit(1)
" 2>/dev/null || echo "FAILED")

TOTAL=$((TOTAL + 1))
if echo "$EXTRACTED" | grep -qF '"key"'; then
    echo "[PASS] extract_json unwraps claude wrapper"
    PASS=$((PASS + 1))
else
    echo "[FAIL] extract_json failed to unwrap"
    FAIL=$((FAIL + 1))
fi

# Test 10: extract_json handles markdown fences
EXTRACTED=$(printf '```json\n{"findings": []}\n```' | python3 -c "
import json, re, sys
text = sys.stdin.read()
try:
    wrapper = json.loads(text)
    if 'result' in wrapper:
        text = wrapper['result']
except (json.JSONDecodeError, TypeError):
    pass
text = re.sub(r'\x60{3}json\s*', '', text)
text = re.sub(r'\x60{3}\s*', '', text)
match = re.search(r'\{.*\}', text, re.DOTALL)
if match:
    try:
        obj = json.loads(match.group())
        print(json.dumps(obj, indent=2))
        sys.exit(0)
    except json.JSONDecodeError:
        pass
sys.exit(1)
" 2>/dev/null || echo "FAILED")

TOTAL=$((TOTAL + 1))
if echo "$EXTRACTED" | grep -qF '"findings"'; then
    echo "[PASS] extract_json strips markdown fences"
    PASS=$((PASS + 1))
else
    echo "[FAIL] extract_json failed with markdown fences"
    FAIL=$((FAIL + 1))
fi

# Test 11: fix mode is explicit and separately approval-gated
HELP_OUTPUT=$(bash "$ORCH_SCRIPT" --help 2>&1)
assert_contains "help documents explicit fix mode" "--fix" "$HELP_OUTPUT"
assert_contains "help documents explicit fix approval" "--approve-fixes" "$HELP_OUTPUT"

# Integration-style control-flow tests use deterministic fake CLIs.
MOCK_BIN="$TMPDIR/bin"
MOCK_TARGET="$TMPDIR/target"
CODEX_LOG="$TMPDIR/codex.log"
CLAUDE_LOG="$TMPDIR/claude.log"
mkdir -p "$MOCK_BIN" "$MOCK_TARGET"

cat > "$MOCK_BIN/codex" <<'MOCK_CODEX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CODEX_LOG"
if [[ "$*" == *"workspace-write"* ]]; then
    printf '%s\n' '{"finding_id":"F001","status":"fixed","changes":[],"notes":"mock"}'
    exit 0
fi
if [[ "${MOCK_CODEX_SCANNER_FAIL:-false}" == true ]]; then
    exit 1
fi
printf '%s\n' '{"scanner_id":1,"scope":"safety","findings":[{"id":"raw","severity":"high","confidence":1,"location":"mock:1","description":"mock finding","evidence":"mock","suggested_fix":"mock"}],"summary":"one finding"}'
MOCK_CODEX

cat > "$MOCK_BIN/claude" <<'MOCK_CLAUDE'
#!/usr/bin/env bash
printf 'ARGS=%s\n' "$*" >> "$CLAUDE_LOG"
if [[ " $* " == *" --help "* ]]; then
    if [[ "${MOCK_CLAUDE_READ_ONLY_CAPABLE:-true}" == true ]]; then
        printf '%s\n' 'usage: claude --permission-mode <mode> --tools <tools> --setting-sources <sources> --strict-mcp-config --settings <json>'
    else
        printf '%s\n' 'usage: claude -p'
    fi
    exit 0
fi
prompt=$(cat)
case "$prompt" in
    *"team lead for an adversarial analysis swarm"*)
        printf '%s\n' '{"assignments":[{"scanner_id":1,"scope":"safety","instructions":"inspect"}]}' ;;
    *"scanner agent #"*)
        printf '%s\n' 'PROMPT_KIND=scanner' >> "$CLAUDE_LOG"
        printf '%s\n' '{"scanner_id":1,"scope":"safety","findings":[{"id":"raw","severity":"high","confidence":1,"location":"mock:1","description":"mock finding","evidence":"mock","suggested_fix":"mock"}],"summary":"fallback finding"}' ;;
    *"PROSECUTOR in an adversarial"*)
        printf '%s\n' '{"role":"prosecutor","round":1,"arguments":[],"verdict_proposal":{"accept":["F001"],"reject":[],"undecided":[]}}' ;;
    *"DEFENDER in an adversarial"*)
        printf '%s\n' '{"role":"defender","round":1,"arguments":[],"verdict_proposal":{"accept":["F001"],"reject":[],"undecided":[]}}' ;;
    *"final judge synthesizing"*)
        printf '%s\n' '{"accepted":[{"id":"F001","severity":"high","reasoning":"confirmed","priority":1}],"rejected":[],"stats":{"total_findings":1,"accepted":1,"rejected":0,"debate_rounds":1}}' ;;
    *) printf '%s\n' '{}' ;;
esac
MOCK_CLAUDE
chmod +x "$MOCK_BIN/codex" "$MOCK_BIN/claude"

run_mocked() {
    : > "$CODEX_LOG"
    : > "$CLAUDE_LOG"
    PATH="$MOCK_BIN:$PATH" \
        CODEX_LOG="$CODEX_LOG" \
        CLAUDE_LOG="$CLAUDE_LOG" \
        MOCK_CODEX_SCANNER_FAIL="${MOCK_CODEX_SCANNER_FAIL:-false}" \
        MOCK_CLAUDE_READ_ONLY_CAPABLE="${MOCK_CLAUDE_READ_ONLY_CAPABLE:-true}" \
        bash "$ORCH_SCRIPT" --target "$MOCK_TARGET" --goal "safety review" --scanners 1 --rounds 1 "$@"
}

# Test 12: default scan/review-only mode must never invoke a fixer
MOCK_CODEX_SCANNER_FAIL=false
MOCK_CLAUDE_READ_ONLY_CAPABLE=true
OUTPUT=$(run_mocked 2>&1)
CODEX_CALLS=$(cat "$CODEX_LOG")
assert_contains "default reports fix phase skipped" "Skipped (scan/review-only default)" "$OUTPUT"
assert_not_contains "default never invokes write-capable fixer" "workspace-write" "$CODEX_CALLS"

# Test 13: --fix alone is insufficient; approval is a separate gate
OUTPUT=$(run_mocked --fix 2>&1)
CODEX_CALLS=$(cat "$CODEX_LOG")
assert_contains "fix without approval is skipped" "explicit approval required" "$OUTPUT"
assert_not_contains "fix without approval never invokes fixer" "workspace-write" "$CODEX_CALLS"

# Test 14: fixer runs only when both explicit gates are present
OUTPUT=$(run_mocked --fix --approve-fixes 2>&1)
CODEX_CALLS=$(cat "$CODEX_LOG")
assert_contains "approved fix reaches fixer" "Codex fixing 1 accepted findings" "$OUTPUT"
assert_contains "approved fix invokes write-capable fixer" "workspace-write" "$CODEX_CALLS"

# Test 15: Codex failure uses a capability-verified, hook-free, read-only fallback
MOCK_CODEX_SCANNER_FAIL=true
MOCK_CLAUDE_READ_ONLY_CAPABLE=true
OUTPUT=$(run_mocked 2>&1)
CLAUDE_CALLS=$(cat "$CLAUDE_LOG")
assert_contains "fallback uses plan permission mode" "--permission-mode plan" "$CLAUDE_CALLS"
assert_contains "fallback restricts tools to readers" "--tools Read,Glob,Grep" "$CLAUDE_CALLS"
assert_contains "fallback disables inherited hooks" 'disableAllHooks' "$CLAUDE_CALLS"
assert_contains "fallback disables inherited setting sources" "--setting-sources" "$CLAUDE_CALLS"
assert_contains "fallback excludes inherited MCP servers" "--strict-mcp-config" "$CLAUDE_CALLS"
assert_not_contains "fallback removes dangerous permission bypass" "--dangerously-skip-permissions" "$CLAUDE_CALLS"

# Test 16: if Claude cannot prove read-only controls, scanner fails closed
MOCK_CLAUDE_READ_ONLY_CAPABLE=false
OUTPUT=$(run_mocked 2>&1)
CLAUDE_CALLS=$(cat "$CLAUDE_LOG")
assert_contains "unverified fallback aborts scanner" "cannot guarantee read-only execution" "$OUTPUT"
assert_not_contains "unverified fallback is not invoked" "PROMPT_KIND=scanner" "$CLAUDE_CALLS"

# --- Summary ---
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

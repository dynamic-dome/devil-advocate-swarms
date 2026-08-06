#!/usr/bin/env bash
# Devil's Advocate Swarm Orchestrator
# Multi-model adversarial agent pipeline: Scan → Debate → Consensus → Fix
#
# Models:
#   Scanner:     Codex (GPT 5.2) — fast, low reasoning, cheap
#   Advocates:   Claude Sonnet 4.6 — argumentation, mid-tier
#   Synthesizer: Claude Opus — consensus evaluation, high precision
#   Fixer:       Codex (GPT 5.2) — minimal code fixes, cheap
#
# Usage:
#   ./orchestrator.sh --target ~/projects/myapp --goal "Security audit"
#   ./orchestrator.sh --target . --goal "Code quality review" --scanners 3
#   ./orchestrator.sh --target . --goal "Architecture review" --fix --approve-fixes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MEMORY_DIR="$PROJECT_ROOT/.agent-memory"
SCRATCH_DIR="$MEMORY_DIR/scratch"
CONSENSUS_DIR="$MEMORY_DIR/consensus"
DEBATES_DIR="$MEMORY_DIR/debates"

# Defaults
TARGET_DIR=""
GOAL=""
NUM_SCANNERS=3
MAX_DEBATE_ROUNDS=3
FIX_MODE=false
FIX_APPROVED=false
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# --- Helper: extract JSON object from CLI output ---
# Handles: claude -p --output-format json wrapper, markdown fences, raw JSON, codex output
extract_json() {
    python3 -c "
import json, re, sys
text = sys.stdin.read()

# 1) Try claude -p --output-format json wrapper: extract .result field
try:
    wrapper = json.loads(text)
    if 'result' in wrapper:
        text = wrapper['result']
except (json.JSONDecodeError, TypeError):
    pass

# 2) Strip markdown fences
text = re.sub(r'\x60{3}json\s*', '', text)
text = re.sub(r'\x60{3}\s*', '', text)

# 3) Extract first JSON object
match = re.search(r'\{.*\}', text, re.DOTALL)
if match:
    try:
        obj = json.loads(match.group())
        print(json.dumps(obj, indent=2))
        sys.exit(0)
    except json.JSONDecodeError:
        pass

# 4) Try to find any JSON by greedy matching braces
for m in re.finditer(r'\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}', text):
    try:
        obj = json.loads(m.group())
        print(json.dumps(obj, indent=2))
        sys.exit(0)
    except json.JSONDecodeError:
        continue

sys.exit(1)
"
}

# --- Helper: run claude -p and extract JSON ---
# Uses a temp file for large prompts to avoid CLI argument length limits
run_claude_json() {
    local model_flag="$1"
    local prompt="$2"
    local tmpfile
    tmpfile=$(mktemp)
    printf '%s' "$prompt" > "$tmpfile"
    local cmd=(claude -p --output-format json)
    [[ -n "$model_flag" ]] && cmd+=(--model "$model_flag")
    "${cmd[@]}" < "$tmpfile" 2>/dev/null | extract_json
    local rc=$?
    rm -f "$tmpfile"
    return $rc
}

# --- Helper: run scanner in target directory (codex first, then sonnet fallback) ---
run_scanner_json() {
    local work_dir="$1"
    local prompt="$2"
    local result

    # Try Codex first with an explicit read-only sandbox and no approval probing.
    result=$( (cd "$work_dir" && printf '%s' "$prompt" | codex exec --sandbox read-only -c 'approval_policy="never"' -) 2>&1 | extract_json ) && {
        echo "$result"
        return 0
    }

    # Fallback only when this Claude CLI exposes all controls needed to make the
    # non-interactive scanner read-only and to disable inherited hooks.
    local claude_help
    if ! claude_help=$(claude --help 2>&1) ||
       ! grep -qF -- "--permission-mode" <<< "$claude_help" ||
       ! grep -qF -- "--tools" <<< "$claude_help" ||
       ! grep -qF -- "--settings" <<< "$claude_help" ||
       ! grep -qF -- "--setting-sources" <<< "$claude_help" ||
       ! grep -qF -- "--strict-mcp-config" <<< "$claude_help"; then
        echo "    ERROR: Codex failed and Claude CLI cannot guarantee read-only execution; scanner aborted." >&2
        return 1
    fi

    echo "    (Codex failed, falling back to verified read-only Sonnet in $work_dir)" >&2
    local tmpfile
    tmpfile=$(mktemp)
    printf '%s' "$prompt" > "$tmpfile"
    (cd "$work_dir" && claude -p --model claude-sonnet-4-6 --output-format json \
        --permission-mode plan \
        --tools "Read,Glob,Grep" \
        --setting-sources "" \
        --strict-mcp-config \
        --settings '{"disableAllHooks":true}' \
        < "$tmpfile") 2>/dev/null | extract_json
    local rc=$?
    rm -f "$tmpfile"
    return $rc
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)   TARGET_DIR="$2"; shift 2 ;;
        --goal)     GOAL="$2"; shift 2 ;;
        --scanners) NUM_SCANNERS="$2"; shift 2 ;;
        --rounds)   MAX_DEBATE_ROUNDS="$2"; shift 2 ;;
        --fix)      FIX_MODE=true; shift ;;
        --approve-fixes) FIX_APPROVED=true; shift ;;
        --no-fix)   FIX_MODE=false; shift ;;
        -h|--help)
            cat <<'USAGE'
Usage: orchestrator.sh --target <dir> --goal "description"

Options:
  --target <dir>     Directory/repo to analyze (required)
  --goal <text>      What to analyze/review (required)
  --scanners <n>     Number of scanner agents (default: 3, max: 5)
  --rounds <n>       Max debate rounds (default: 3)
  --fix              Enable the fix phase (default: scan/review only)
  --approve-fixes    Explicitly approve write-capable fixer execution; requires --fix
  --no-fix           Explicitly retain scan/review-only mode (legacy-compatible)

Examples:
  ./orchestrator.sh --target ~/myapp --goal "Security audit"
  ./orchestrator.sh --target . --goal "Find performance bottlenecks" --scanners 2
  ./orchestrator.sh --target . --goal "Apply approved fixes" --fix --approve-fixes
USAGE
            exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$TARGET_DIR" || -z "$GOAL" ]]; then
    echo "ERROR: --target and --goal are required. Use --help for usage."
    exit 1
fi

if [[ "$FIX_APPROVED" == true && "$FIX_MODE" != true ]]; then
    echo "ERROR: --approve-fixes requires --fix."
    exit 1
fi

TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

if [[ $NUM_SCANNERS -gt 5 ]]; then
    echo "WARN: Capping scanners at 5 (was $NUM_SCANNERS)"
    NUM_SCANNERS=5
fi

# --- Setup workspace ---
rm -rf "$SCRATCH_DIR" "$CONSENSUS_DIR" "$DEBATES_DIR"
mkdir -p "$SCRATCH_DIR" "$CONSENSUS_DIR" "$DEBATES_DIR"

echo "================================================================"
echo " Devil's Advocate Swarm Orchestrator"
echo " Target:   $TARGET_DIR"
echo " Goal:     $GOAL"
echo " Scanners: $NUM_SCANNERS | Debate rounds: $MAX_DEBATE_ROUNDS"
echo " Models:   Codex (scan/fix) + Sonnet (debate) + Opus (synthesis)"
echo "================================================================"
echo ""

# ==================================================================
# PHASE 1: DECOMPOSE — Opus splits the goal into scanner assignments
# ==================================================================
echo "[Phase 1/5] Decomposing goal into scanner assignments..."

DECOMPOSE_PROMPT="You are a team lead for an adversarial analysis swarm.

GOAL: $GOAL
TARGET DIRECTORY: $TARGET_DIR
NUMBER OF SCANNERS: $NUM_SCANNERS

Split this goal into $NUM_SCANNERS non-overlapping scanner assignments.
Each scanner should cover a distinct aspect of the analysis.

Output ONLY valid JSON (no markdown fences, no explanation):
{
  \"goal\": \"...\",
  \"assignments\": [
    {\"scanner_id\": 1, \"scope\": \"specific area to scan\", \"instructions\": \"what to look for\"},
    ...
  ]
}"

ASSIGNMENTS_FILE="$SCRATCH_DIR/scan-assignments.json"
if ! run_claude_json "" "$DECOMPOSE_PROMPT" > "$ASSIGNMENTS_FILE"; then
    echo "  ERROR: Could not get valid assignments JSON. Aborting."
    exit 1
fi

NUM_ACTUAL=$(jq '.assignments | length' "$ASSIGNMENTS_FILE")
echo "  Created $NUM_ACTUAL scanner assignments."
echo ""

# ==================================================================
# PHASE 2: SCAN — Codex scanners run in sequence (no parallel on Win)
# ==================================================================
echo "[Phase 2/5] Running $NUM_ACTUAL Codex scanners..."

for i in $(seq 1 "$NUM_ACTUAL"); do
    SCOPE=$(jq -r ".assignments[$((i-1))].scope" "$ASSIGNMENTS_FILE")
    INSTRUCTIONS=$(jq -r ".assignments[$((i-1))].instructions" "$ASSIGNMENTS_FILE")
    SCANNER_OUT="$SCRATCH_DIR/scanner-${i}.json"

    echo "  Scanner $i/$NUM_ACTUAL: $SCOPE"

    SCANNER_PROMPT="You are scanner agent #$i in an adversarial analysis swarm.

YOUR SCOPE: $SCOPE
INSTRUCTIONS: $INSTRUCTIONS
TARGET DIRECTORY: $TARGET_DIR

Analyze the target thoroughly within your scope. Report ALL findings, even uncertain ones.

Output ONLY valid JSON (no markdown, no explanation):
{
  \"scanner_id\": $i,
  \"scope\": \"$SCOPE\",
  \"findings\": [
    {
      \"id\": \"F${i}01\",
      \"severity\": \"high|medium|low\",
      \"confidence\": 0.0-1.0,
      \"location\": \"file:line or area\",
      \"description\": \"what was found\",
      \"evidence\": \"concrete code/text as proof\",
      \"suggested_fix\": \"optional fix suggestion\"
    }
  ],
  \"summary\": \"one-line summary\"
}"

    if ! run_scanner_json "$TARGET_DIR" "$SCANNER_PROMPT" > "$SCANNER_OUT"; then
        echo "{\"scanner_id\": $i, \"findings\": [], \"summary\": \"Scanner failed to produce valid JSON\"}" > "$SCANNER_OUT"
    fi

    FINDING_COUNT=$(jq '.findings | length' "$SCANNER_OUT" 2>/dev/null || echo 0)
    echo "    → $FINDING_COUNT findings"
done

# Merge all scanner findings
echo ""
echo "  Merging scanner results..."
ALL_FINDINGS="$SCRATCH_DIR/all-findings.json"
jq -s '{
  total_scanners: length,
  all_findings: [.[].findings[]?] | to_entries | map(.value + {id: ("F" + (.key + 1 | tostring | if length < 3 then "0" * (3 - length) + . else . end))}),
  summaries: [.[] | {scanner_id, summary}]
}' "$SCRATCH_DIR"/scanner-*.json > "$ALL_FINDINGS" 2>/dev/null || echo '{"all_findings":[],"summaries":[]}' > "$ALL_FINDINGS"

TOTAL_FINDINGS=$(jq '.all_findings | length' "$ALL_FINDINGS")
echo "  Total findings across all scanners: $TOTAL_FINDINGS"

if [[ "$TOTAL_FINDINGS" -eq 0 ]]; then
    echo ""
    echo "  No findings to debate. Done."
    jq -n '{accepted: [], rejected: [], reasoning: "No findings from scanners"}' > "$CONSENSUS_DIR/result.json"
    exit 0
fi

echo ""

# ==================================================================
# PHASE 3: DEBATE — Sonnet advocates argue for/against findings
# ==================================================================
echo "[Phase 3/5] Adversarial debate ($MAX_DEBATE_ROUNDS rounds max)..."

FINDINGS_TEXT=$(jq -r '.all_findings[] | "- \(.id) [\(.severity)/\(.confidence)] \(.location): \(.description)"' "$ALL_FINDINGS")

for round in $(seq 1 "$MAX_DEBATE_ROUNDS"); do
    echo "  Round $round/$MAX_DEBATE_ROUNDS"

    # Build context from previous rounds
    PREV_ARGS=""
    if [[ $round -gt 1 ]]; then
        PREV_PROSECUTOR="$DEBATES_DIR/round-$((round-1))-prosecutor.json"
        PREV_DEFENDER="$DEBATES_DIR/round-$((round-1))-defender.json"
        PREV_ARGS="

PREVIOUS ROUND — Prosecutor argued:
$(cat "$PREV_PROSECUTOR" 2>/dev/null || echo '(none)')

PREVIOUS ROUND — Defender argued:
$(cat "$PREV_DEFENDER" 2>/dev/null || echo '(none)')

Respond to their arguments. Update your verdict based on new evidence."
    fi

    # --- Prosecutor (Sonnet) ---
    PROSECUTOR_OUT="$DEBATES_DIR/round-${round}-prosecutor.json"
    PROSECUTOR_TMP=$(mktemp)
    cat > "$PROSECUTOR_TMP" <<PROSECUTOR_EOF
You are the PROSECUTOR in an adversarial code review debate (round $round/$MAX_DEBATE_ROUNDS).

FINDINGS TO EVALUATE:
$FINDINGS_TEXT
$PREV_ARGS

Your job: argue that these findings are REAL and CRITICAL.
- Provide additional evidence where possible
- Challenge any false-positive claims
- Assess impact if findings are ignored

Output ONLY valid JSON (no markdown fences, no text outside the JSON):
{"role": "prosecutor", "round": $round, "arguments": [{"finding_id": "F001", "position": "real", "argument": "...", "evidence": "..."}], "verdict_proposal": {"accept": [...], "reject": [...], "undecided": [...]}}
PROSECUTOR_EOF

    if ! claude -p --model claude-sonnet-4-6 --output-format json < "$PROSECUTOR_TMP" 2>/dev/null | extract_json > "$PROSECUTOR_OUT"; then
        echo '{"role":"prosecutor","round":'$round',"arguments":[],"verdict_proposal":{"accept":[],"reject":[],"undecided":[]}}' > "$PROSECUTOR_OUT"
    fi
    rm -f "$PROSECUTOR_TMP"

    echo "    Prosecutor: $(jq '.arguments | length' "$PROSECUTOR_OUT" 2>/dev/null || echo 0) arguments"

    # --- Defender (Sonnet) ---
    DEFENDER_OUT="$DEBATES_DIR/round-${round}-defender.json"
    DEFENDER_TMP=$(mktemp)
    PROSECUTOR_ARGS=$(cat "$PROSECUTOR_OUT" 2>/dev/null || echo "(none)")
    cat > "$DEFENDER_TMP" <<DEFENDER_EOF
You are the DEFENDER in an adversarial code review debate (round $round/$MAX_DEBATE_ROUNDS).

FINDINGS TO EVALUATE:
$FINDINGS_TEXT

PROSECUTOR ARGUES (this round):
$PROSECUTOR_ARGS
$PREV_ARGS

Your job: argue that these findings are FALSE POSITIVES or NON-CRITICAL.
- Find counter-evidence and context that explains away findings
- Challenge severity ratings
- Show where scanners over-reported

Output ONLY valid JSON (no markdown fences, no text outside the JSON):
{"role": "defender", "round": $round, "arguments": [{"finding_id": "F001", "position": "false_positive", "argument": "...", "evidence": "..."}], "verdict_proposal": {"accept": [...], "reject": [...], "undecided": [...]}}
DEFENDER_EOF

    if ! claude -p --model claude-sonnet-4-6 --output-format json < "$DEFENDER_TMP" 2>/dev/null | extract_json > "$DEFENDER_OUT"; then
        echo '{"role":"defender","round":'$round',"arguments":[],"verdict_proposal":{"accept":[],"reject":[],"undecided":[]}}' > "$DEFENDER_OUT"
    fi
    rm -f "$DEFENDER_TMP"

    echo "    Defender:   $(jq '.arguments | length' "$DEFENDER_OUT" 2>/dev/null || echo 0) arguments"

    # Check for early consensus
    P_ACCEPT=$(jq -r '[.verdict_proposal.accept[]?] | sort | join(",")' "$PROSECUTOR_OUT" 2>/dev/null || echo "")
    D_ACCEPT=$(jq -r '[.verdict_proposal.accept[]?] | sort | join(",")' "$DEFENDER_OUT" 2>/dev/null || echo "")
    if [[ -n "$P_ACCEPT" && "$P_ACCEPT" == "$D_ACCEPT" ]]; then
        echo "    → Early consensus reached!"
        break
    fi
done

echo ""

# ==================================================================
# PHASE 4: CONSENSUS — Opus synthesizes the debate into a verdict
# ==================================================================
echo "[Phase 4/5] Opus synthesizing consensus..."

# Collect all debate rounds
DEBATE_HISTORY=""
for f in "$DEBATES_DIR"/round-*.json; do
    [[ -f "$f" ]] && DEBATE_HISTORY="$DEBATE_HISTORY
--- $(basename "$f") ---
$(cat "$f")"
done

CONSENSUS_PROMPT="You are the final judge synthesizing an adversarial debate about code findings.

ORIGINAL FINDINGS:
$FINDINGS_TEXT

DEBATE HISTORY:
$DEBATE_HISTORY

Evaluate each finding based on BOTH sides' arguments. Be conservative: when in doubt, accept the finding (better safe than sorry).

Output ONLY valid JSON:
{
  \"accepted\": [
    {\"id\": \"F001\", \"severity\": \"high\", \"reasoning\": \"why accepted\", \"priority\": 1}
  ],
  \"rejected\": [
    {\"id\": \"F002\", \"reasoning\": \"why rejected\"}
  ],
  \"stats\": {
    \"total_findings\": $TOTAL_FINDINGS,
    \"accepted\": 0,
    \"rejected\": 0,
    \"debate_rounds\": $round
  }
}"

CONSENSUS_FILE="$CONSENSUS_DIR/result.json"
if ! run_claude_json "" "$CONSENSUS_PROMPT" > "$CONSENSUS_FILE"; then
    echo "  WARN: Consensus failed, using conservative fallback (accept all)..."
    jq -n --argjson total "$TOTAL_FINDINGS" '{accepted: [], rejected: [], stats: {total_findings: $total, accepted: 0, rejected: 0}}' > "$CONSENSUS_FILE"
fi

ACCEPTED=$(jq '.accepted | length' "$CONSENSUS_FILE" 2>/dev/null || echo 0)
REJECTED=$(jq '.rejected | length' "$CONSENSUS_FILE" 2>/dev/null || echo 0)
echo "  Verdict: $ACCEPTED accepted, $REJECTED rejected"
echo ""

# ==================================================================
# PHASE 5: FIX — Codex applies fixes for accepted findings
# ==================================================================
if [[ "$FIX_MODE" != true ]]; then
    echo "[Phase 5/5] Skipped (scan/review-only default)"
elif [[ "$FIX_APPROVED" != true ]]; then
    echo "[Phase 5/5] Skipped (explicit approval required: rerun with --fix --approve-fixes)"
elif [[ "$ACCEPTED" -eq 0 ]]; then
    echo "[Phase 5/5] No accepted findings to fix."
else
    echo "[Phase 5/5] Codex fixing $ACCEPTED accepted findings..."

    ACCEPTED_LIST=$(jq -r '.accepted[] | "\(.id) [P\(.priority // 9)]: \(.reasoning)"' "$CONSENSUS_FILE" 2>/dev/null)
    ACCEPTED_DETAILS=$(jq -c '.accepted[]' "$CONSENSUS_FILE" 2>/dev/null)

    # Get original finding details for accepted items
    ACCEPTED_IDS=$(jq -r '.accepted[].id' "$CONSENSUS_FILE" 2>/dev/null)

    for fid in $ACCEPTED_IDS; do
        echo "  Fixing $fid..."

        FINDING_DETAIL=$(jq -r ".all_findings[] | select(.id == \"$fid\")" "$ALL_FINDINGS" 2>/dev/null)
        CONSENSUS_DETAIL=$(jq -r ".accepted[] | select(.id == \"$fid\")" "$CONSENSUS_FILE" 2>/dev/null)

        FIX_PROMPT="You are a fixer agent. Apply a minimal, targeted fix for this finding.

FINDING:
$FINDING_DETAIL

CONSENSUS REASONING:
$CONSENSUS_DETAIL

Rules:
- Fix ONLY this specific finding, nothing else
- Make the smallest possible change
- If tests exist, run them after fixing
- If the fix would break other things, skip it

After fixing (or deciding to skip), create a file at: $CONSENSUS_DIR/fix-${fid}.json
with this content:
{
  \"finding_id\": \"$fid\",
  \"status\": \"fixed|skipped|failed\",
  \"changes\": [{\"file\": \"...\", \"description\": \"...\"}],
  \"notes\": \"...\"
}"

        FIX_FILE="$CONSENSUS_DIR/fix-${fid}.json"
        if ! (cd "$TARGET_DIR" && codex exec --sandbox workspace-write "$FIX_PROMPT") 2>&1 | extract_json > "$FIX_FILE"; then
            echo "{\"finding_id\": \"$fid\", \"status\": \"attempted\", \"changes\": [], \"notes\": \"Codex did not return valid JSON\"}" \
                > "$FIX_FILE"
        fi

        STATUS=$(jq -r '.status' "$CONSENSUS_DIR/fix-${fid}.json" 2>/dev/null || echo "unknown")
        echo "    → $STATUS"
    done
fi

echo ""

# ==================================================================
# SUMMARY
# ==================================================================
echo "================================================================"
echo " Swarm Complete — $TIMESTAMP"
echo "================================================================"
echo ""
echo " Scanners:       $NUM_ACTUAL (Codex GPT-5.2)"
echo " Debate rounds:  ${round:-0} (Sonnet 4.6)"
echo " Total findings: $TOTAL_FINDINGS"
echo " Accepted:       $ACCEPTED"
echo " Rejected:       $REJECTED"
echo ""
echo " Files:"
echo "   Assignments:  .agent-memory/scratch/scan-assignments.json"
echo "   Findings:     .agent-memory/scratch/all-findings.json"
echo "   Debates:      .agent-memory/debates/round-*.json"
echo "   Consensus:    .agent-memory/consensus/result.json"
[[ "$FIX_MODE" == true && "$FIX_APPROVED" == true && "$ACCEPTED" -gt 0 ]] && \
echo "   Fixes:        .agent-memory/consensus/fix-*.json"
echo ""
echo " Review consensus:  cat .agent-memory/consensus/result.json | jq ."
echo "================================================================"

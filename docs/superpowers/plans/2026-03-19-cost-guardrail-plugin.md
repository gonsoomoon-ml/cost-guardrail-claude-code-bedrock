# Cost Guardrail Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Claude Code plugin that monitors per-IAM-user Bedrock API costs via CloudWatch Logs Insights and hard-blocks usage when a local spending threshold is reached.

**Architecture:** Shell script (`check-cost.sh`) runs as a hook on `SessionStart` and every Nth `UserPromptSubmit`. It queries CloudWatch Logs Insights for the current IAM user's Bedrock token usage, calculates cost using local pricing config, and exits non-zero to block if threshold is exceeded. Fail-open on all errors. Two markdown commands (`/cost-status`, `/cost-config`) let users check spend and modify settings. One skill provides cost-awareness context to the AI.

**Tech Stack:** Bash, AWS CLI v2 (`sts`, `logs`), jq, bc, Claude Code plugin system (markdown/JSON)

**Spec:** `docs/superpowers/specs/2026-03-19-cost-guardrail-plugin-design.md`

---

## File Structure

```
cost-guardrail/
├── .claude-plugin/
│   └── plugin.json              # Plugin metadata
├── commands/
│   ├── cost-status.md           # /cost-status slash command
│   └── cost-config.md           # /cost-config slash command
├── skills/
│   └── cost-awareness/
│       └── SKILL.md             # Auto-injected cost context
├── hooks/
│   ├── hooks.json               # Hook event registrations
│   └── check-cost.sh            # Main cost check script
├── config.json                  # Threshold, pricing, settings
└── README.md                    # Installation guide
```

---

### Task 1: Plugin Scaffold — plugin.json and config.json

**Files:**
- Create: `cost-guardrail/.claude-plugin/plugin.json`
- Create: `cost-guardrail/config.json`

- [ ] **Step 1: Create directory structure**

```bash
cd /home/ubuntu/Self-Study-Generative-AI/lab/25_claude_code_plugin
mkdir -p cost-guardrail/.claude-plugin
mkdir -p cost-guardrail/commands
mkdir -p cost-guardrail/skills/cost-awareness
mkdir -p cost-guardrail/hooks
```

- [ ] **Step 2: Create plugin.json**

```json
{
  "name": "cost-guardrail",
  "version": "1.0.0",
  "description": "Per-user Bedrock cost monitoring with automatic usage blocking when spending threshold is reached",
  "author": {
    "name": "gonsoomoon-ml"
  }
}
```

- [ ] **Step 3: Validate plugin.json**

Run: `jq . cost-guardrail/.claude-plugin/plugin.json`
Expected: Valid JSON output, no errors. `author` must be an object (not a string).

- [ ] **Step 4: Create config.json**

```json
{
  "threshold_usd": 50,
  "period": "monthly",
  "check_interval": 10,
  "log_group": "aws/bedrock/model-invocations",
  "timezone": "UTC",
  "default_input_per_1k": 0.003,
  "default_output_per_1k": 0.015,
  "pricing": {
    "anthropic.claude-sonnet-4-6-v1": {
      "input_per_1k": 0.003,
      "output_per_1k": 0.015
    },
    "anthropic.claude-haiku-4-5-20251001-v1:0": {
      "input_per_1k": 0.001,
      "output_per_1k": 0.005
    }
  }
}
```

- [ ] **Step 5: Validate config.json**

Run: `jq . cost-guardrail/config.json`
Expected: Valid JSON, no parse errors.

- [ ] **Step 6: Commit**

```bash
git add cost-guardrail/.claude-plugin/plugin.json cost-guardrail/config.json
git commit -m "feat(cost-guardrail): scaffold plugin with plugin.json and config.json"
```

---

### Task 2: check-cost.sh — Core Cost Check Script

**Files:**
- Create: `cost-guardrail/hooks/check-cost.sh`

This is the most complex file. It handles three modes (`session_start`, `prompt_submit`, `report`), counter management, AWS API calls, cost calculation, caching, and fail-open error handling.

- [ ] **Step 1: Create check-cost.sh with argument parsing and config loading**

```bash
#!/usr/bin/env bash
# NOTE: No `set -euo pipefail` — this script uses a fail-open pattern.
# Any unexpected error must result in exit 0 (allow usage), never a non-zero exit.
# `set -e` would conflict with this by terminating the script on command failures
# before our `|| { exit 0; }` guards can execute.

# Resolve plugin root (directory containing .claude-plugin/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_FILE="${PLUGIN_ROOT}/config.json"
COUNTER_FILE="/tmp/claude-cost-guardrail-${USER:-unknown}-counter"
CACHE_FILE="/tmp/claude-cost-guardrail-${USER:-unknown}-cache.json"

# --- Initialize variables (prevent unset variable issues) ---
QUERY_ID=""
TOTAL_COST=""
CACHED_COST=""

# --- Argument Parsing ---
EVENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --event) EVENT="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 0 ;;
  esac
done

if [[ -z "$EVENT" ]]; then
  echo "Usage: check-cost.sh --event <session_start|prompt_submit|report>" >&2
  exit 0
fi

# --- Guard: threshold_usd=0 means always block ---
# (handled after config load below)

# --- Load Config (fail-open on error) ---
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[cost-guardrail] config.json not found, skipping check" >&2
  exit 0
fi

THRESHOLD_USD=$(jq -r '.threshold_usd // 50' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
PERIOD=$(jq -r '.period // "monthly"' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
CHECK_INTERVAL=$(jq -r '.check_interval // 10' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
LOG_GROUP=$(jq -r '.log_group // "aws/bedrock/model-invocations"' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
TIMEZONE=$(jq -r '.timezone // "UTC"' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
DEFAULT_INPUT=$(jq -r '.default_input_per_1k // 0.003' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
DEFAULT_OUTPUT=$(jq -r '.default_output_per_1k // 0.015' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }

# Guard: if threshold is 0 or non-numeric, fail-open
if ! echo "$THRESHOLD_USD" | grep -qE '^[0-9]+\.?[0-9]*$' || [[ "$THRESHOLD_USD" == "0" ]]; then
  echo "[cost-guardrail] Invalid or zero threshold_usd, skipping check" >&2
  exit 0
fi
```

- [ ] **Step 2: Add counter logic for prompt_submit throttling**

Append to `check-cost.sh`:

```bash
# --- Counter Logic (prompt_submit only) ---
if [[ "$EVENT" == "prompt_submit" ]]; then
  COUNTER=0
  if [[ -f "$COUNTER_FILE" ]]; then
    COUNTER=$(cat "$COUNTER_FILE" 2>/dev/null) || COUNTER=0
    # Validate it's a number
    if ! [[ "$COUNTER" =~ ^[0-9]+$ ]]; then
      COUNTER=0
    fi
  fi
  COUNTER=$((COUNTER + 1))
  if [[ "$COUNTER" -lt "$CHECK_INTERVAL" ]]; then
    echo "$COUNTER" > "$COUNTER_FILE"
    exit 0  # Skip this check
  fi
  # Reset counter and proceed with check
  echo "0" > "$COUNTER_FILE"
fi

if [[ "$EVENT" == "session_start" ]]; then
  echo "0" > "$COUNTER_FILE"
fi
```

- [ ] **Step 3: Add IAM identity lookup with fail-open**

Append to `check-cost.sh`:

```bash
# --- Get IAM User ARN (fail-open) ---
USER_ARN=$(aws sts get-caller-identity --query "Arn" --output text 2>/dev/null) || {
  echo "[cost-guardrail] Failed to get IAM identity, skipping check" >&2
  exit 0
}
```

- [ ] **Step 4: Add cache check logic**

Append to `check-cost.sh`:

```bash
# --- Check Cache ---
use_cache() {
  if [[ -f "$CACHE_FILE" ]]; then
    local cache_ts
    cache_ts=$(jq -r '.timestamp // 0' "$CACHE_FILE" 2>/dev/null) || { return 1; }
    local now_ts
    now_ts=$(date +%s)
    local age=$(( now_ts - cache_ts ))
    if [[ "$age" -lt 300 ]]; then  # 5 minutes
      CACHED_COST=$(jq -r '.cost_usd // 0' "$CACHE_FILE" 2>/dev/null) || { return 1; }
      return 0
    fi
  fi
  return 1
}

CACHED_COST=""
# Both session_start and report always perform a fresh query (bypass cache)
if [[ "$EVENT" == "prompt_submit" ]] && use_cache; then
  TOTAL_COST="$CACHED_COST"
else
  # Will be set by CloudWatch query below
  TOTAL_COST=""
fi
```

- [ ] **Step 5: Add CloudWatch Logs Insights query and cost calculation**

Append to `check-cost.sh`:

```bash
# --- CloudWatch Logs Insights Query ---
if [[ -z "$TOTAL_COST" ]]; then
  # Calculate time range
  if [[ "$PERIOD" == "daily" ]]; then
    START_TIME=$(TZ="$TIMEZONE" date -d "today 00:00:00" +%s 2>/dev/null) || START_TIME=$(date +%s)
  else
    START_TIME=$(TZ="$TIMEZONE" date -d "$(date +%Y-%m-01) 00:00:00" +%s 2>/dev/null) || START_TIME=$(date +%s)
  fi
  END_TIME=$(date +%s)

  # Start query
  QUERY_STRING="filter identity.arn = \"${USER_ARN}\"
| stats sum(input.inputTokenCount) as totalInput, sum(output.outputTokenCount) as totalOutput by modelId"

  QUERY_ID=$(aws logs start-query \
    --log-group-name "$LOG_GROUP" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --query-string "$QUERY_STRING" \
    --query "queryId" --output text 2>/dev/null) || {
    # Query failed — use cache or fail-open
    if use_cache; then
      TOTAL_COST="$CACHED_COST"
    else
      echo "[cost-guardrail] CloudWatch query failed, skipping check" >&2
      exit 0
    fi
  }

  # Poll for results (max 5 attempts, 3s intervals)
  if [[ -n "$QUERY_ID" && -z "$TOTAL_COST" ]]; then
    RESULTS=""
    for i in 1 2 3 4 5; do
      sleep 3
      STATUS=$(aws logs get-query-results --query-id "$QUERY_ID" --query "status" --output text 2>/dev/null) || break
      if [[ "$STATUS" == "Complete" ]]; then
        RESULTS=$(aws logs get-query-results --query-id "$QUERY_ID" --output json 2>/dev/null) || break
        break
      elif [[ "$STATUS" == "Failed" || "$STATUS" == "Cancelled" ]]; then
        break
      fi
    done

    if [[ -z "$RESULTS" ]]; then
      # Timed out or failed — use cache or fail-open
      if use_cache; then
        TOTAL_COST="$CACHED_COST"
      else
        echo "[cost-guardrail] CloudWatch query timed out, skipping check" >&2
        exit 0
      fi
    else
      # Calculate cost from results
      TOTAL_COST="0"
      while IFS= read -r row; do
        # Parse by field name (not positional index) for robustness
        MODEL_ID=$(echo "$row" | jq -r '.[] | select(.field == "modelId") | .value // ""' 2>/dev/null) || continue
        INPUT_TOKENS=$(echo "$row" | jq -r '.[] | select(.field == "totalInput") | .value // "0"' 2>/dev/null) || continue
        OUTPUT_TOKENS=$(echo "$row" | jq -r '.[] | select(.field == "totalOutput") | .value // "0"' 2>/dev/null) || continue

        # Look up model pricing, fall back to defaults
        INPUT_PRICE=$(jq -r ".pricing[\"${MODEL_ID}\"].input_per_1k // ${DEFAULT_INPUT}" "$CONFIG_FILE" 2>/dev/null) || INPUT_PRICE="$DEFAULT_INPUT"
        OUTPUT_PRICE=$(jq -r ".pricing[\"${MODEL_ID}\"].output_per_1k // ${DEFAULT_OUTPUT}" "$CONFIG_FILE" 2>/dev/null) || OUTPUT_PRICE="$DEFAULT_OUTPUT"

        MODEL_COST=$(echo "scale=4; (${INPUT_TOKENS} / 1000 * ${INPUT_PRICE}) + (${OUTPUT_TOKENS} / 1000 * ${OUTPUT_PRICE})" | bc 2>/dev/null) || MODEL_COST="0"
        TOTAL_COST=$(echo "scale=4; ${TOTAL_COST} + ${MODEL_COST}" | bc 2>/dev/null) || TOTAL_COST="0"
      done < <(echo "$RESULTS" | jq -c '.results[]' 2>/dev/null)

      # Write cache
      echo "{\"cost_usd\": ${TOTAL_COST}, \"timestamp\": $(date +%s)}" > "$CACHE_FILE" 2>/dev/null || true
    fi
  fi
fi
```

- [ ] **Step 6: Add threshold comparison and output**

Append to `check-cost.sh`:

```bash
# --- Threshold Check ---
# Ensure TOTAL_COST is set
TOTAL_COST="${TOTAL_COST:-0}"

# Calculate percentage
PERCENT=$(echo "scale=1; ${TOTAL_COST} * 100 / ${THRESHOLD_USD}" | bc 2>/dev/null) || PERCENT="0"

# Report mode — always print, never block
if [[ "$EVENT" == "report" ]]; then
  echo "User: ${USER_ARN}"
  echo "Period: $(date +%Y-%m) (${PERIOD})"
  echo "Estimated cost: \$${TOTAL_COST} / \$${THRESHOLD_USD} (${PERCENT}%)"
  if (( $(echo "${TOTAL_COST} >= ${THRESHOLD_USD}" | bc -l 2>/dev/null || echo 0) )); then
    echo "Status: BLOCKED"
  else
    echo "Status: Active"
  fi
  exit 0
fi

# Check threshold
EXCEEDED=$(echo "${TOTAL_COST} >= ${THRESHOLD_USD}" | bc -l 2>/dev/null) || EXCEEDED="0"
if [[ "$EXCEEDED" == "1" ]]; then
  echo "[cost-guardrail] BLOCKED: Estimated Bedrock cost \$${TOTAL_COST} has reached threshold \$${THRESHOLD_USD} (${PERCENT}%)" >&2
  echo "[cost-guardrail] Run /cost-status for details or /cost-config to adjust threshold" >&2
  exit 2
fi

exit 0
```

- [ ] **Step 7: Make script executable and test syntax**

Run: `chmod +x cost-guardrail/hooks/check-cost.sh && bash -n cost-guardrail/hooks/check-cost.sh`
Expected: No syntax errors.

- [ ] **Step 8: Test argument parsing with dry run**

Run: `bash cost-guardrail/hooks/check-cost.sh --event report 2>&1 || true`
Expected: Script runs, likely fails on AWS call and exits 0 (fail-open). No crash.

- [ ] **Step 9: Commit**

```bash
git add cost-guardrail/hooks/check-cost.sh
git commit -m "feat(cost-guardrail): add check-cost.sh with CW Logs Insights query and fail-open"
```

---

### Task 3: hooks.json — Event Registration

**Files:**
- Create: `cost-guardrail/hooks/hooks.json`

- [ ] **Step 1: Create hooks.json**

```json
{
  "description": "Check Bedrock cost per IAM user and block when threshold exceeded",
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/check-cost.sh --event session_start",
            "timeout": 60
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/check-cost.sh --event prompt_submit",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Validate hooks.json**

Run: `jq . cost-guardrail/hooks/hooks.json`
Expected: Valid JSON. Top-level keys: `description`, `hooks`. Event keys: `SessionStart`, `UserPromptSubmit`.

- [ ] **Step 3: Commit**

```bash
git add cost-guardrail/hooks/hooks.json
git commit -m "feat(cost-guardrail): add hooks.json for SessionStart and UserPromptSubmit"
```

---

### Task 4: Commands — /cost-status and /cost-config

**Files:**
- Create: `cost-guardrail/commands/cost-status.md`
- Create: `cost-guardrail/commands/cost-config.md`

- [ ] **Step 1: Create cost-status.md**

```markdown
---
name: cost-status
description: Check current Bedrock cost for the active IAM user
---

# /cost-status — Current Cost Status

Show the current estimated Bedrock API cost for the active IAM user.

## Instructions

1. Run the cost check script in report mode:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/check-cost.sh --event report
   ```
2. Parse the output lines and present to the user in a clear format:
   - User ARN
   - Current period (monthly or daily)
   - Estimated cost vs threshold with percentage
   - Status (Active or BLOCKED)
3. If the script fails or produces no output, inform the user that cost data is temporarily unavailable and suggest checking AWS credentials.
```

- [ ] **Step 2: Create cost-config.md**

```markdown
---
name: cost-config
description: View or modify cost guardrail settings
---

# /cost-config — Guardrail Configuration

View or modify the cost guardrail plugin settings.

## Usage

```
/cost-config show
/cost-config set <key> <value>
```

## Instructions

### show
1. Read `${CLAUDE_PLUGIN_ROOT}/config.json`
2. Display all settings in a formatted table:
   - threshold_usd, period, check_interval, timezone
   - List all models in the pricing table with their rates

### set
1. Read `${CLAUDE_PLUGIN_ROOT}/config.json`
2. Only allow modification of these keys:
   - `threshold_usd` (number) — spending limit in USD
   - `check_interval` (integer) — check every Nth prompt
   - `period` ("monthly" or "daily") — cost accumulation window
   - `timezone` (string) — timezone for daily period boundary
3. Validate the value type before writing
4. Write back the complete updated JSON file (preserve all other fields)
5. Confirm the change to the user

### Restrictions
- Do NOT allow modification of `pricing`, `log_group`, `default_input_per_1k`, or `default_output_per_1k` via this command
- For pricing changes, instruct the user to edit config.json directly
```

- [ ] **Step 3: Commit**

```bash
git add cost-guardrail/commands/cost-status.md cost-guardrail/commands/cost-config.md
git commit -m "feat(cost-guardrail): add /cost-status and /cost-config commands"
```

---

### Task 5: Skill — cost-awareness SKILL.md

**Files:**
- Create: `cost-guardrail/skills/cost-awareness/SKILL.md`

- [ ] **Step 1: Create SKILL.md**

```markdown
---
name: cost-awareness
description: Context about active cost guardrail for AI responses
autoContext:
  - always: true
---

# Cost Guardrail — Active

This project has a cost guardrail plugin that monitors Amazon Bedrock API spending per IAM user.

## What It Does

- Checks estimated Bedrock cost at session start and periodically during use
- Blocks usage (hard block) when the configured spending threshold is reached
- Tracks costs per IAM user using CloudWatch Logs Insights

## User Commands

- `/cost-status` — Check current estimated cost, threshold, and status
- `/cost-config show` — View current settings
- `/cost-config set threshold_usd <amount>` — Change spending limit

## Cost Efficiency

When this plugin is active, be mindful of cost:
- Prefer concise, focused responses
- Avoid unnecessary tool calls when a direct answer suffices
- If the user asks about costs or budget, direct them to `/cost-status`
```

- [ ] **Step 2: Commit**

```bash
git add cost-guardrail/skills/cost-awareness/SKILL.md
git commit -m "feat(cost-guardrail): add cost-awareness skill for auto-context"
```

---

### Task 6: README.md — Installation and Setup Guide

**Files:**
- Create: `cost-guardrail/README.md`

- [ ] **Step 1: Create README.md**

Write a README covering:
1. **Overview** — what the plugin does (1 paragraph)
2. **Prerequisites** — Bedrock Model Invocation Logging enabled, AWS CLI v2, jq, bc
3. **Installation** — copy to local-marketplace, register, install (same pattern as translate-toolkit)
4. **Configuration** — explain each config.json field with examples
5. **Usage** — `/cost-status`, `/cost-config` examples
6. **How It Works** — brief explanation of the hook → CW Logs Insights → cost calculation → block flow
7. **Error Handling** — fail-open policy explanation
8. **Troubleshooting** — common issues (logging not enabled, permissions missing, stale cache)

- [ ] **Step 2: Commit**

```bash
git add cost-guardrail/README.md
git commit -m "docs(cost-guardrail): add installation and setup README"
```

---

### Task 7: Local Marketplace Integration

**Files:**
- Copy: `cost-guardrail/` → `local-marketplace/plugins/cost-guardrail/`
- Modify: `local-marketplace/.claude-plugin/marketplace.json`

- [ ] **Step 1: Copy plugin to marketplace**

```bash
cp -r cost-guardrail/ local-marketplace/plugins/cost-guardrail/
```

- [ ] **Step 2: Update marketplace.json**

Add the cost-guardrail entry to the `plugins` array:

```json
{
  "name": "cost-guardrail",
  "description": "Per-user Bedrock cost monitoring with automatic usage blocking",
  "source": "./plugins/cost-guardrail"
}
```

- [ ] **Step 3: Validate marketplace.json**

Run: `jq . local-marketplace/.claude-plugin/marketplace.json`
Expected: Valid JSON with both `translate-toolkit` and `cost-guardrail` in the plugins array.

- [ ] **Step 4: Commit**

```bash
git add local-marketplace/plugins/cost-guardrail/ local-marketplace/.claude-plugin/marketplace.json
git commit -m "feat(marketplace): add cost-guardrail plugin to local marketplace"
```

---

### Task 8: Final Validation

- [ ] **Step 1: Verify complete directory structure**

Run: `find cost-guardrail -type f | sort`
Expected:
```
cost-guardrail/.claude-plugin/plugin.json
cost-guardrail/README.md
cost-guardrail/commands/cost-config.md
cost-guardrail/commands/cost-status.md
cost-guardrail/config.json
cost-guardrail/hooks/check-cost.sh
cost-guardrail/hooks/hooks.json
cost-guardrail/skills/cost-awareness/SKILL.md
```

- [ ] **Step 2: Validate all JSON files**

Run: `find cost-guardrail -name "*.json" -exec jq . {} \;`
Expected: All files parse without errors.

- [ ] **Step 3: Verify check-cost.sh has no syntax errors**

Run: `bash -n cost-guardrail/hooks/check-cost.sh`
Expected: No output (clean syntax).

- [ ] **Step 4: Verify check-cost.sh is executable**

Run: `ls -la cost-guardrail/hooks/check-cost.sh`
Expected: `-rwxr-xr-x` permissions.

- [ ] **Step 5: Dry-run check-cost.sh in report mode**

Run: `bash cost-guardrail/hooks/check-cost.sh --event report 2>&1 || true`
Expected: Either cost report output (if AWS credentials are configured) or fail-open message and exit 0.

- [ ] **Step 6: Final commit if any fixes were needed**

```bash
git add -A cost-guardrail/
git commit -m "fix(cost-guardrail): final validation fixes"
```

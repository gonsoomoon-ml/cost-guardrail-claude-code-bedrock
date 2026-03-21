# Cost Guardrail v2 — Implementation Plan

**Goal:** Make the CloudWatch Logs Insights approach viable for 500 users by reducing scan cost ~31×, adding cross-platform support, and restructuring config for admin/employee separation.

**Architecture:** Daily accumulation (query only today's logs, cache previous days' totals) + progressive checking (adaptive intervals based on proximity to threshold) + portable arithmetic (awk instead of bc) + portable date (math-based epoch instead of `date -d`).

**Current monthly CW cost at 500 users: ~$22,000. Target: ~$150.**

---

## Scope — 5 independent changes

| # | Change | Files | Risk |
|---|--------|-------|------|
| 1 | Cross-platform fixes (bc→awk, date portability) | `hooks/check-cost.sh` | Low — swap commands, same logic |
| 2 | Daily accumulation | `hooks/check-cost.sh` | Medium — new state file, day/month boundary logic |
| 3 | Progressive checking | `hooks/check-cost.sh`, `config.json` | Low — interval lookup table |
| 4 | Config/folder restructure | `config.json`, `admin/`, `scripts/release.sh` | Low — file moves, no logic change |
| 5 | Preflight script | `scripts/preflight.sh` | Low — new file, read-only checks |

Recommended order: 1 → 2 → 3 → 4 → 5 (each builds on the previous, each is independently committable).

---

## Task 1: Cross-Platform Fixes

**Files:**
- Modify: `hooks/check-cost.sh`

### 1a. Replace all `bc` with `awk`

6 occurrences in check-cost.sh. Replace each:

```bash
# Line 206 — MODEL_COST calculation
# Before:
MODEL_COST=$(echo "scale=4; (${INPUT_TOKENS} / 1000 * ${INPUT_PRICE}) + ..." | bc 2>/dev/null) || MODEL_COST="0"
# After:
MODEL_COST=$(awk "BEGIN {printf \"%.5f\", (${INPUT_TOKENS} / 1000 * ${INPUT_PRICE}) + (${CACHE_READ_TOKENS} / 1000 * ${CACHE_READ_PRICE}) + (${CACHE_WRITE_TOKENS} / 1000 * ${CACHE_WRITE_PRICE}) + (${OUTPUT_TOKENS} / 1000 * ${OUTPUT_PRICE})}" 2>/dev/null) || MODEL_COST="0"

# Line 207 — TOTAL_COST accumulation
# Before:
TOTAL_COST=$(echo "scale=4; ${TOTAL_COST} + ${MODEL_COST}" | bc 2>/dev/null) || TOTAL_COST="0"
# After:
TOTAL_COST=$(awk "BEGIN {printf \"%.5f\", ${TOTAL_COST} + ${MODEL_COST}}" 2>/dev/null) || TOTAL_COST="0"

# Line 221 — PERCENT calculation
# Before:
PERCENT=$(echo "scale=1; ${TOTAL_COST} * 100 / ${THRESHOLD_USD}" | bc 2>/dev/null) || PERCENT="0"
# After:
PERCENT=$(awk "BEGIN {printf \"%.1f\", ${TOTAL_COST} * 100 / ${THRESHOLD_USD}}" 2>/dev/null) || PERCENT="0"

# Line 228 — report mode threshold comparison
# Before:
if (( $(echo "${TOTAL_COST} >= ${THRESHOLD_USD}" | bc -l 2>/dev/null || echo 0) )); then
# After:
if [ "$(awk "BEGIN {print (${TOTAL_COST} >= ${THRESHOLD_USD}) ? 1 : 0}")" = "1" ]; then

# Line 237 — blocking threshold comparison
# Before:
EXCEEDED=$(echo "${TOTAL_COST} >= ${THRESHOLD_USD}" | bc -l 2>/dev/null) || EXCEEDED="0"
# After:
EXCEEDED=$(awk "BEGIN {print (${TOTAL_COST} >= ${THRESHOLD_USD}) ? 1 : 0}" 2>/dev/null) || EXCEEDED="0"
```

### 1b. Replace `date -d` with math-based epoch

Replace lines 110-114:

```bash
# Before:
if [[ "$PERIOD" == "daily" ]]; then
  START_TIME=$(TZ="$TIMEZONE" date -d "today 00:00:00" +%s 2>/dev/null) || START_TIME=$(date +%s)
else
  START_TIME=$(TZ="$TIMEZONE" date -d "$(date +%Y-%m-01) 00:00:00" +%s 2>/dev/null) || START_TIME=$(date +%s)
fi

# After:
NOW_EPOCH=$(date +%s)
HOUR=$(TZ="$TIMEZONE" date +%H)
MIN=$(TZ="$TIMEZONE" date +%M)
SEC=$(TZ="$TIMEZONE" date +%S)
TODAY_START=$(( NOW_EPOCH - (10#$HOUR * 3600) - (10#$MIN * 60) - 10#$SEC ))

if [[ "$PERIOD" == "daily" ]]; then
  START_TIME=$TODAY_START
else
  DAY=$(TZ="$TIMEZONE" date +%d)
  START_TIME=$(( TODAY_START - (10#$DAY - 1) * 86400 ))
fi
```

### 1c. Fix report display for daily period

Replace line 226:

```bash
# Before:
echo "Period: $(date +%Y-%m) (${PERIOD})"
# After:
if [[ "$PERIOD" == "daily" ]]; then
  echo "Period: $(TZ="$TIMEZONE" date +%Y-%m-%d) (${PERIOD})"
else
  echo "Period: $(TZ="$TIMEZONE" date +%Y-%m) (${PERIOD})"
fi
```

### Test

```bash
# Syntax check
bash -n hooks/check-cost.sh

# Functional test
bash hooks/check-cost.sh --event report
```

### Commit

```
feat: cross-platform fixes — replace bc with awk, portable date calculation
```

---

## Task 2: Daily Accumulation

**Files:**
- Modify: `hooks/check-cost.sh`

### Design

New state file: `/tmp/claude-cost-guardrail-${USER}-daily.json`

```json
{
  "month": "2026-03",
  "days": {
    "2026-03-01": 5.20,
    "2026-03-15": 3.10
  },
  "previous_total": 87.60,
  "last_reconcile": 1774310400
}
```

Logic:
- `previous_total` = sum of all finalized days
- Monthly cost = `previous_total` + today's live CW query (today only)
- CW query window: **today 00:00 → now** (~130 MB scan at 500 users vs 4 GB)

### 2a. Add daily state file management functions

Insert after the cache functions (after line 100), before the CloudWatch query section:

```bash
DAILY_FILE="/tmp/claude-cost-guardrail-${USER:-unknown}-daily.json"
CURRENT_MONTH=$(TZ="$TIMEZONE" date +%Y-%m)
CURRENT_DATE=$(TZ="$TIMEZONE" date +%Y-%m-%d)

# Load daily accumulation state; returns previous_total or "0"
load_daily_state() {
  if [[ ! -f "$DAILY_FILE" ]]; then
    echo "0"
    return
  fi
  local file_month
  file_month=$(jq -r '.month // ""' "$DAILY_FILE" 2>/dev/null) || { echo "0"; return; }
  if [[ "$file_month" != "$CURRENT_MONTH" ]]; then
    # New month — reset
    echo "0"
    return
  fi
  jq -r '.previous_total // 0' "$DAILY_FILE" 2>/dev/null || echo "0"
}

# Finalize yesterday: query CW for yesterday's full day, update daily state
finalize_yesterday() {
  local yesterday yesterday_start yesterday_end
  yesterday=$(TZ="$TIMEZONE" date -d "yesterday" +%Y-%m-%d 2>/dev/null) || \
    yesterday=$(TZ="$TIMEZONE" date +%Y-%m-%d -d "-1 day" 2>/dev/null) || return
  # Portable: calculate yesterday boundaries from today's start
  yesterday_start=$(( TODAY_START - 86400 ))
  yesterday_end=$TODAY_START

  # Check if yesterday is already finalized
  local already
  already=$(jq -r ".days[\"$yesterday\"] // \"null\"" "$DAILY_FILE" 2>/dev/null) || already="null"
  if [[ "$already" != "null" ]]; then
    return  # Already finalized
  fi

  # Query CW for yesterday only (small scan)
  local yq_id yq_status yq_results yesterday_cost
  yq_id=$(aws logs start-query \
    --log-group-name "$LOG_GROUP" \
    --start-time "$yesterday_start" \
    --end-time "$yesterday_end" \
    --query-string "$QUERY_STRING" \
    --query "queryId" --output text 2>/dev/null) || return

  for i in 1 2 3 4 5; do
    sleep 2
    yq_status=$(aws logs get-query-results --query-id "$yq_id" --query "status" --output text 2>/dev/null) || break
    if [[ "$yq_status" == "Complete" ]]; then
      yq_results=$(aws logs get-query-results --query-id "$yq_id" --output json 2>/dev/null) || break
      yesterday_cost=$(calculate_cost_from_results "$yq_results")
      # Update daily file
      local prev_total
      prev_total=$(jq -r '.previous_total // 0' "$DAILY_FILE" 2>/dev/null) || prev_total="0"
      local new_total
      new_total=$(awk "BEGIN {printf \"%.5f\", ${prev_total} + ${yesterday_cost}}" 2>/dev/null) || return
      jq --arg d "$yesterday" --argjson c "$yesterday_cost" --argjson t "$new_total" \
        '.days[$d] = $c | .previous_total = $t' "$DAILY_FILE" > "${DAILY_FILE}.tmp" 2>/dev/null && \
        mv "${DAILY_FILE}.tmp" "$DAILY_FILE"
      break
    elif [[ "$yq_status" == "Failed" || "$yq_status" == "Cancelled" ]]; then
      break
    fi
  done
}

# Save initial daily state file if it doesn't exist or month changed
init_daily_state() {
  local file_month=""
  if [[ -f "$DAILY_FILE" ]]; then
    file_month=$(jq -r '.month // ""' "$DAILY_FILE" 2>/dev/null) || file_month=""
  fi
  if [[ "$file_month" != "$CURRENT_MONTH" ]]; then
    echo "{\"month\": \"${CURRENT_MONTH}\", \"days\": {}, \"previous_total\": 0, \"last_reconcile\": $(date +%s)}" > "$DAILY_FILE" 2>/dev/null || true
  fi
}

# Weekly reconciliation: full-month query to correct any drift
maybe_reconcile() {
  if [[ ! -f "$DAILY_FILE" ]]; then return; fi
  local last_rec
  last_rec=$(jq -r '.last_reconcile // 0' "$DAILY_FILE" 2>/dev/null) || return
  local now_ts=$(date +%s)
  local age=$(( now_ts - last_rec ))
  # Reconcile every 7 days (604800 seconds)
  if [[ "$age" -lt 604800 ]]; then return; fi
  # Will fall through to full-month query below (START_TIME = month start)
  # Set flag to use full month query
  USE_FULL_MONTH="true"
  jq --argjson t "$now_ts" '.last_reconcile = $t' "$DAILY_FILE" > "${DAILY_FILE}.tmp" 2>/dev/null && \
    mv "${DAILY_FILE}.tmp" "$DAILY_FILE"
}
```

### 2b. Extract cost calculation into a function

Currently lines 161-208 calculate cost inline. Extract as `calculate_cost_from_results()` function so both the daily query and yesterday's finalization can reuse it.

```bash
# Takes JSON results from get-query-results, outputs total cost
calculate_cost_from_results() {
  local results="$1"
  local total="0"
  while IFS= read -r row; do
    # (existing parsing logic from lines 163-207, using awk instead of bc)
    # ... extract MODEL_ID_RAW, tokens, prices, compute model cost ...
    local model_cost
    model_cost=$(awk "BEGIN {printf \"%.5f\", ...}" 2>/dev/null) || model_cost="0"
    total=$(awk "BEGIN {printf \"%.5f\", ${total} + ${model_cost}}" 2>/dev/null) || true
  done < <(echo "$results" | jq -c '.results[]' 2>/dev/null)
  echo "$total"
}
```

### 2c. Modify the main query flow

Replace the CloudWatch query section (lines 108-213) to use daily accumulation:

```bash
if [[ -z "$TOTAL_COST" ]]; then
  USE_FULL_MONTH=""
  init_daily_state
  PREV_TOTAL=$(load_daily_state)

  # On session_start, finalize yesterday
  if [[ "$EVENT" == "session_start" ]]; then
    finalize_yesterday
    PREV_TOTAL=$(load_daily_state)  # Reload after finalization
  fi

  # Check if weekly reconciliation needed
  maybe_reconcile

  if [[ "$USE_FULL_MONTH" == "true" ]]; then
    # Full month query for reconciliation
    DAY=$(TZ="$TIMEZONE" date +%d)
    QUERY_START=$(( TODAY_START - (10#$DAY - 1) * 86400 ))
  else
    # Normal: query only today
    QUERY_START=$TODAY_START
  fi
  END_TIME=$(date +%s)

  # Start CW query with QUERY_START instead of START_TIME
  QUERY_ID=$(aws logs start-query \
    --log-group-name "$LOG_GROUP" \
    --start-time "$QUERY_START" \
    --end-time "$END_TIME" \
    --query-string "$QUERY_STRING" \
    --query "queryId" --output text 2>/dev/null) || { ... fail-open ... }

  # (existing poll loop)
  # ...

  # After getting results:
  if [[ -n "$RESULTS" ]]; then
    TODAY_COST=$(calculate_cost_from_results "$RESULTS")
    if [[ "$USE_FULL_MONTH" == "true" ]]; then
      TOTAL_COST="$TODAY_COST"  # Full month result — IS the total
      # Update daily state: reset previous_total to (total - today's portion)
      # (reconciliation overwrites accumulated state)
    else
      TOTAL_COST=$(awk "BEGIN {printf \"%.5f\", ${PREV_TOTAL} + ${TODAY_COST}}" 2>/dev/null) || TOTAL_COST="0"
    fi
    # Update cache
    echo "{\"cost_usd\": ${TOTAL_COST}, \"timestamp\": $(date +%s)}" > "$CACHE_FILE" 2>/dev/null || true
  fi
fi
```

### Test

```bash
bash -n hooks/check-cost.sh
bash hooks/check-cost.sh --event report
# Verify daily file was created:
cat /tmp/claude-cost-guardrail-${USER}-daily.json
```

### Commit

```
feat: daily accumulation — query only today's logs, cache previous days
```

---

## Task 3: Progressive Checking

**Files:**
- Modify: `hooks/check-cost.sh` (counter logic, lines 58-74)
- Modify: `config.json` (add progressive thresholds)

### 3a. Add progressive config to config.json

```json
{
  "check_interval": 10,
  "progressive_intervals": {
    "low": { "below_percent": 50, "interval": 50, "cache_ttl": 1800 },
    "medium": { "below_percent": 80, "interval": 20, "cache_ttl": 600 },
    "high": { "interval": 5, "cache_ttl": 300 }
  },
  ...
}
```

If `progressive_intervals` is absent, fall back to flat `check_interval` (backward compatible).

### 3b. Modify counter logic

Replace lines 58-74 (counter section) with progressive-aware version:

```bash
if [[ "$EVENT" == "prompt_submit" ]]; then
  # Determine effective interval based on last known cost
  EFFECTIVE_INTERVAL="$CHECK_INTERVAL"
  EFFECTIVE_CACHE_TTL=300  # default 5 min

  PROG=$(jq -r '.progressive_intervals // null' "$CONFIG_FILE" 2>/dev/null)
  if [[ "$PROG" != "null" && -f "$CACHE_FILE" ]]; then
    CACHED_COST_FOR_PROG=$(jq -r '.cost_usd // 0' "$CACHE_FILE" 2>/dev/null) || CACHED_COST_FOR_PROG="0"
    COST_PERCENT=$(awk "BEGIN {printf \"%.0f\", ${CACHED_COST_FOR_PROG} * 100 / ${THRESHOLD_USD}}" 2>/dev/null) || COST_PERCENT="0"

    LOW_PCT=$(jq -r '.progressive_intervals.low.below_percent // 50' "$CONFIG_FILE" 2>/dev/null) || LOW_PCT="50"
    MED_PCT=$(jq -r '.progressive_intervals.medium.below_percent // 80' "$CONFIG_FILE" 2>/dev/null) || MED_PCT="80"

    if [[ "$COST_PERCENT" -lt "$LOW_PCT" ]]; then
      EFFECTIVE_INTERVAL=$(jq -r '.progressive_intervals.low.interval // 50' "$CONFIG_FILE" 2>/dev/null) || true
      EFFECTIVE_CACHE_TTL=$(jq -r '.progressive_intervals.low.cache_ttl // 1800' "$CONFIG_FILE" 2>/dev/null) || true
    elif [[ "$COST_PERCENT" -lt "$MED_PCT" ]]; then
      EFFECTIVE_INTERVAL=$(jq -r '.progressive_intervals.medium.interval // 20' "$CONFIG_FILE" 2>/dev/null) || true
      EFFECTIVE_CACHE_TTL=$(jq -r '.progressive_intervals.medium.cache_ttl // 600' "$CONFIG_FILE" 2>/dev/null) || true
    else
      EFFECTIVE_INTERVAL=$(jq -r '.progressive_intervals.high.interval // 5' "$CONFIG_FILE" 2>/dev/null) || true
      EFFECTIVE_CACHE_TTL=$(jq -r '.progressive_intervals.high.cache_ttl // 300' "$CONFIG_FILE" 2>/dev/null) || true
    fi
  fi

  # Counter check with effective interval
  COUNTER=0
  if [[ -f "$COUNTER_FILE" ]]; then
    COUNTER=$(cat "$COUNTER_FILE" 2>/dev/null) || COUNTER=0
    [[ "$COUNTER" =~ ^[0-9]+$ ]] || COUNTER=0
  fi
  COUNTER=$((COUNTER + 1))
  if [[ "$COUNTER" -lt "$EFFECTIVE_INTERVAL" ]]; then
    echo "$COUNTER" > "$COUNTER_FILE"
    exit 0
  fi
  echo "0" > "$COUNTER_FILE"
fi
```

Also modify the `use_cache()` function to accept `EFFECTIVE_CACHE_TTL`:

```bash
use_cache() {
  local ttl="${1:-300}"
  if [[ -f "$CACHE_FILE" ]]; then
    local cache_ts
    cache_ts=$(jq -r '.timestamp // 0' "$CACHE_FILE" 2>/dev/null) || { return 1; }
    local now_ts=$(date +%s)
    local age=$(( now_ts - cache_ts ))
    if [[ "$age" -lt "$ttl" ]]; then
      CACHED_COST=$(jq -r '.cost_usd // 0' "$CACHE_FILE" 2>/dev/null) || { return 1; }
      return 0
    fi
  fi
  return 1
}
```

Update cache call (line 103):

```bash
if [[ "$EVENT" == "prompt_submit" ]] && use_cache "$EFFECTIVE_CACHE_TTL"; then
```

### Test

```bash
bash -n hooks/check-cost.sh
bash hooks/check-cost.sh --event report
# Test prompt_submit with different cache states
bash hooks/check-cost.sh --event prompt_submit
```

### Commit

```
feat: progressive checking — adaptive intervals based on cost proximity to threshold
```

---

## Task 4: Config & Folder Restructure

**Files:**
- Create: `admin/config.admin.json`
- Create: `admin/config.dist.json`
- Modify: `config.json` (remove policy fields, keep shared facts only)
- Modify: `hooks/check-cost.sh` (merge base + admin config at runtime)
- Modify: `scripts/release.sh` (merge base + dist config instead of heredoc)

### 4a. Split config.json

**`config.json`** (shared base — pricing and infrastructure):

```json
{
  "log_group": "bedrock/model-invocations",
  "default_input_per_1k": 0.003,
  "default_output_per_1k": 0.015,
  "default_cache_read_per_1k": 0.0003,
  "default_cache_write_per_1k": 0.00375,
  "pricing": {
    "anthropic.claude-opus-4-6-v1": {
      "input_per_1k": 0.015,
      "output_per_1k": 0.075,
      "cache_read_per_1k": 0.0015,
      "cache_write_per_1k": 0.01875
    },
    "anthropic.claude-sonnet-4-6-v1": {
      "input_per_1k": 0.003,
      "output_per_1k": 0.015,
      "cache_read_per_1k": 0.0003,
      "cache_write_per_1k": 0.00375
    },
    "anthropic.claude-haiku-4-5-20251001-v1:0": {
      "input_per_1k": 0.0008,
      "output_per_1k": 0.004,
      "cache_read_per_1k": 0.00008,
      "cache_write_per_1k": 0.001
    }
  }
}
```

**`admin/config.admin.json`** (admin policy):

```json
{
  "threshold_usd": 1000,
  "period": "monthly",
  "check_interval": 10,
  "timezone": "Asia/Seoul",
  "progressive_intervals": {
    "low": { "below_percent": 50, "interval": 50, "cache_ttl": 1800 },
    "medium": { "below_percent": 80, "interval": 20, "cache_ttl": 600 },
    "high": { "interval": 5, "cache_ttl": 300 }
  }
}
```

**`admin/config.dist.json`** (employee defaults):

```json
{
  "threshold_usd": 50,
  "period": "monthly",
  "check_interval": 10,
  "timezone": "UTC",
  "progressive_intervals": {
    "low": { "below_percent": 50, "interval": 50, "cache_ttl": 1800 },
    "medium": { "below_percent": 80, "interval": 20, "cache_ttl": 600 },
    "high": { "interval": 5, "cache_ttl": 300 }
  }
}
```

### 4b. Modify check-cost.sh config loading

Replace lines 36-49 (config loading):

```bash
# --- Load Config (merge base + admin override, fail-open) ---
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[cost-guardrail] config.json not found, skipping check" >&2
  exit 0
fi

ADMIN_CONFIG="${PLUGIN_ROOT}/admin/config.admin.json"
if [[ -f "$ADMIN_CONFIG" ]]; then
  MERGED_CONFIG=$(jq -s '.[0] * .[1]' "$CONFIG_FILE" "$ADMIN_CONFIG" 2>/dev/null) || MERGED_CONFIG=$(cat "$CONFIG_FILE")
else
  MERGED_CONFIG=$(cat "$CONFIG_FILE")
fi

# Parse from merged config
THRESHOLD_USD=$(echo "$MERGED_CONFIG" | jq -r '.threshold_usd // 50' 2>/dev/null) || { exit 0; }
PERIOD=$(echo "$MERGED_CONFIG" | jq -r '.period // "monthly"' 2>/dev/null) || { exit 0; }
# ... (all other fields read from $MERGED_CONFIG instead of $CONFIG_FILE)
```

Note: For pricing lookups later in the script, continue reading from `$CONFIG_FILE` (base config) since pricing is always in the base.

### 4c. Modify release.sh

Replace the heredoc (lines 51-85) with a jq merge:

```bash
# Generate distribution config.json by merging base + dist overrides
echo "[release] Generating distribution config.json..."
DIST_OVERRIDE="${SOURCE_ROOT}/admin/config.dist.json"
if [[ -f "$DIST_OVERRIDE" ]]; then
  jq -s '.[0] * .[1]' "$SOURCE_ROOT/config.json" "$DIST_OVERRIDE" > "$PLUGIN_DIR/config.json"
else
  echo "Error: admin/config.dist.json not found" >&2
  exit 1
fi
```

### 4d. Update cost-config.md

The `set` command should write to `admin/config.admin.json` (not config.json) when the admin/ directory exists. Update `commands/cost-config.md` instructions accordingly.

### Test

```bash
# Validate JSON
jq . config.json
jq . admin/config.admin.json
jq . admin/config.dist.json

# Test merged config
jq -s '.[0] * .[1]' config.json admin/config.admin.json

# Syntax check
bash -n hooks/check-cost.sh

# Functional test
bash hooks/check-cost.sh --event report

# Test release
bash scripts/release.sh /path/to/marketplace-repo
```

### Commit

```
refactor: split config into base + admin/dist overrides, add admin/ directory
```

---

## Task 5: Preflight Script

**Files:**
- Create: `scripts/preflight.sh`

### 5a. Create preflight.sh

```bash
#!/usr/bin/env bash
# preflight.sh — Check prerequisites for the cost guardrail plugin
# Usage: bash scripts/preflight.sh

PASS=0
FAIL=0
WARN=0

check() {
  local label="$1" result="$2" fix="$3"
  if [[ "$result" == "ok" ]]; then
    echo "[PASS] $label"
    PASS=$((PASS + 1))
  elif [[ "$result" == "warn" ]]; then
    echo "[WARN] $label"
    [[ -n "$fix" ]] && echo "       → $fix"
    WARN=$((WARN + 1))
  else
    echo "[FAIL] $label"
    [[ -n "$fix" ]] && echo "       → $fix"
    FAIL=$((FAIL + 1))
  fi
}

# Detect platform
OS="unknown"
case "$(uname -s)" in
  Darwin)  OS="macos" ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      OS="wsl"
    else
      OS="linux"
    fi ;;
  MINGW*|MSYS*|CYGWIN*) OS="gitbash" ;;
esac
echo "Platform: $OS ($(uname -m))"
echo ""

# Bash version
BASH_VER="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
  check "Bash $BASH_VER" "ok"
elif [[ "${BASH_VERSINFO[0]}" -ge 3 ]]; then
  check "Bash $BASH_VER (3.x works, 4+ recommended)" "warn" \
    "$([ "$OS" = "macos" ] && echo 'brew install bash' || echo 'Update bash via package manager')"
else
  check "Bash $BASH_VER (too old)" "fail" "Install bash 4+"
fi

# jq
if command -v jq &>/dev/null; then
  check "jq $(jq --version 2>&1)" "ok"
else
  case "$OS" in
    macos)   FIX="brew install jq" ;;
    linux|wsl) FIX="sudo apt install jq  OR  sudo yum install jq" ;;
    gitbash) FIX="Download from https://jqlang.github.io/jq/download/" ;;
    *)       FIX="Install jq" ;;
  esac
  check "jq not found" "fail" "$FIX"
fi

# awk
if command -v awk &>/dev/null; then
  check "awk available" "ok"
else
  check "awk not found" "fail" "Install gawk or mawk"
fi

# AWS CLI
if command -v aws &>/dev/null; then
  AWS_VER=$(aws --version 2>&1 | head -1)
  check "AWS CLI: $AWS_VER" "ok"
else
  check "AWS CLI not found" "fail" "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
fi

# AWS credentials
if aws sts get-caller-identity --query "Arn" --output text &>/dev/null; then
  ARN=$(aws sts get-caller-identity --query "Arn" --output text 2>/dev/null)
  check "AWS identity: $ARN" "ok"
else
  check "AWS credentials not configured or expired" "fail" "Run: aws configure  OR  aws sso login"
fi

# CloudWatch log group
LOG_GROUP="bedrock/model-invocations"
if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query "logGroups[?logGroupName=='$LOG_GROUP'].logGroupName" --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
  check "Log group: $LOG_GROUP" "ok"
else
  check "Log group '$LOG_GROUP' not found" "fail" \
    "Enable Bedrock Model Invocation Logging → CloudWatch Logs (log group: $LOG_GROUP)"
fi

# Summary
echo ""
echo "─────────────────────────────"
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Fix the failures above before using the cost guardrail plugin."
  exit 1
else
  echo "All checks passed. Plugin is ready to use."
  exit 0
fi
```

### Test

```bash
bash scripts/preflight.sh
```

### Commit

```
feat: add preflight.sh — prerequisite checker with platform-specific guidance
```

---

## Task 6: Update Documentation

**Files:**
- Modify: `CLAUDE.md` (update file structure, new config fields, new files)
- Modify: `docs/how-cost-query-works.md` (add daily accumulation section)
- Modify: `docs/beginners-guide.md` (add progressive checking, daily accumulation terms)
- Modify: `README.md` (update structure, mention preflight.sh) — keep in Korean

### Commit

```
docs: update for v2 — daily accumulation, progressive checking, admin/ structure
```

---

## Summary of changes

| File | Action | Task |
|------|--------|------|
| `hooks/check-cost.sh` | Modify (major) | 1, 2, 3, 4 |
| `config.json` | Modify (split) | 4 |
| `admin/config.admin.json` | Create | 4 |
| `admin/config.dist.json` | Create | 4 |
| `scripts/release.sh` | Modify | 4 |
| `scripts/preflight.sh` | Create | 5 |
| `commands/cost-config.md` | Modify | 4 |
| `CLAUDE.md` | Modify | 6 |
| `docs/how-cost-query-works.md` | Modify | 6 |
| `docs/beginners-guide.md` | Modify | 6 |
| `README.md` | Modify | 6 |

## Expected outcome at 500 users

| Metric | Before | After |
|--------|--------|-------|
| CW scan per query | 4 GB (month end) | ~130 MB (today only) |
| Queries/user/hour (low spend) | 3.0 | 0.6 |
| Monthly CW cost | ~$22,000 | ~$150 |
| Works on macOS | No (silent fail) | Yes |
| Works on Win Git Bash | No (bc missing) | Yes |
| Admin/employee config | Mixed in one file | Clearly separated |

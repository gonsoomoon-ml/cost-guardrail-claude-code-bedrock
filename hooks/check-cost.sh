#!/usr/bin/env bash
# cost-guardrail: check-cost.sh
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

# --- Load Config (fail-open on error) ---
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[cost-guardrail] config.json not found, skipping check" >&2
  exit 0
fi

THRESHOLD_USD=$(jq -r '.threshold_usd // 50' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
PERIOD=$(jq -r '.period // "monthly"' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
CHECK_INTERVAL=$(jq -r '.check_interval // 10' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
LOG_GROUP=$(jq -r '.log_group // "bedrock/model-invocations"' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
TIMEZONE=$(jq -r '.timezone // "UTC"' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
DEFAULT_INPUT=$(jq -r '.default_input_per_1k // 0.003' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
DEFAULT_OUTPUT=$(jq -r '.default_output_per_1k // 0.015' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
DEFAULT_CACHE_READ=$(jq -r '.default_cache_read_per_1k // 0.0003' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
DEFAULT_CACHE_WRITE=$(jq -r '.default_cache_write_per_1k // 0.00375' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }

# Guard: if threshold is 0 or non-numeric, fail-open
if ! echo "$THRESHOLD_USD" | grep -qE '^[0-9]+\.?[0-9]*$' || [[ "$THRESHOLD_USD" == "0" ]]; then
  echo "[cost-guardrail] Invalid or zero threshold_usd, skipping check" >&2
  exit 0
fi

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

# --- Get IAM User ARN (fail-open) ---
USER_ARN=$(aws sts get-caller-identity --query "Arn" --output text 2>/dev/null) || {
  echo "[cost-guardrail] Failed to get IAM identity, skipping check" >&2
  exit 0
}

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

# Both session_start and report always perform a fresh query (bypass cache)
if [[ "$EVENT" == "prompt_submit" ]] && use_cache; then
  TOTAL_COST="$CACHED_COST"
fi

# --- CloudWatch Logs Insights Query ---
if [[ -z "$TOTAL_COST" ]]; then
  # Calculate time range
  if [[ "$PERIOD" == "daily" ]]; then
    START_TIME=$(TZ="$TIMEZONE" date -d "today 00:00:00" +%s 2>/dev/null) || START_TIME=$(date +%s)
  else
    START_TIME=$(TZ="$TIMEZONE" date -d "$(date +%Y-%m-01) 00:00:00" +%s 2>/dev/null) || START_TIME=$(date +%s)
  fi
  END_TIME=$(date +%s)

  # Start query (separate token types for accurate pricing)
  QUERY_STRING="filter identity.arn = \"${USER_ARN}\"
| stats sum(input.inputTokenCount) as inputTokens, sum(input.cacheReadInputTokenCount) as cacheReadTokens, sum(input.cacheWriteInputTokenCount) as cacheWriteTokens, sum(output.outputTokenCount) as outputTokens by modelId"

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
        MODEL_ID_RAW=$(echo "$row" | jq -r '.[] | select(.field == "modelId") | .value // ""' 2>/dev/null) || continue
        INPUT_TOKENS=$(echo "$row" | jq -r '[.[] | select(.field == "inputTokens") | .value] | first // "0"' 2>/dev/null) || INPUT_TOKENS="0"
        CACHE_READ_TOKENS=$(echo "$row" | jq -r '[.[] | select(.field == "cacheReadTokens") | .value] | first // "0"' 2>/dev/null) || CACHE_READ_TOKENS="0"
        CACHE_WRITE_TOKENS=$(echo "$row" | jq -r '[.[] | select(.field == "cacheWriteTokens") | .value] | first // "0"' 2>/dev/null) || CACHE_WRITE_TOKENS="0"
        OUTPUT_TOKENS=$(echo "$row" | jq -r '[.[] | select(.field == "outputTokens") | .value] | first // "0"' 2>/dev/null) || OUTPUT_TOKENS="0"

        # Ensure numeric (empty string → 0)
        INPUT_TOKENS="${INPUT_TOKENS:-0}"; [[ "$INPUT_TOKENS" =~ ^[0-9]+$ ]] || INPUT_TOKENS="0"
        CACHE_READ_TOKENS="${CACHE_READ_TOKENS:-0}"; [[ "$CACHE_READ_TOKENS" =~ ^[0-9]+$ ]] || CACHE_READ_TOKENS="0"
        CACHE_WRITE_TOKENS="${CACHE_WRITE_TOKENS:-0}"; [[ "$CACHE_WRITE_TOKENS" =~ ^[0-9]+$ ]] || CACHE_WRITE_TOKENS="0"
        OUTPUT_TOKENS="${OUTPUT_TOKENS:-0}"; [[ "$OUTPUT_TOKENS" =~ ^[0-9]+$ ]] || OUTPUT_TOKENS="0"

        # Skip rows with no token data
        if [[ "$INPUT_TOKENS" == "0" && "$CACHE_READ_TOKENS" == "0" && "$CACHE_WRITE_TOKENS" == "0" && "$OUTPUT_TOKENS" == "0" ]]; then
          continue
        fi

        # Extract model ID from ARN if needed
        # e.g. "arn:aws:bedrock:us-west-2:123:inference-profile/us.anthropic.claude-opus-4-6-v1" → "us.anthropic.claude-opus-4-6-v1"
        MODEL_ID="$MODEL_ID_RAW"
        if [[ "$MODEL_ID" == arn:* ]]; then
          MODEL_ID="${MODEL_ID##*/}"
        fi

        # Look up model pricing: try exact match, then try without "us." prefix
        LOOKUP_ID="$MODEL_ID"
        INPUT_PRICE=$(jq -r ".pricing[\"${LOOKUP_ID}\"].input_per_1k // null" "$CONFIG_FILE" 2>/dev/null)
        if [[ "$INPUT_PRICE" == "null" || -z "$INPUT_PRICE" ]]; then
          LOOKUP_ID="${MODEL_ID#us.}"
          INPUT_PRICE=$(jq -r ".pricing[\"${LOOKUP_ID}\"].input_per_1k // null" "$CONFIG_FILE" 2>/dev/null)
        fi
        # If still not found, use defaults
        if [[ "$INPUT_PRICE" == "null" || -z "$INPUT_PRICE" ]]; then
          INPUT_PRICE="$DEFAULT_INPUT"
          OUTPUT_PRICE="$DEFAULT_OUTPUT"
          CACHE_READ_PRICE="$DEFAULT_CACHE_READ"
          CACHE_WRITE_PRICE="$DEFAULT_CACHE_WRITE"
        else
          OUTPUT_PRICE=$(jq -r ".pricing[\"${LOOKUP_ID}\"].output_per_1k // ${DEFAULT_OUTPUT}" "$CONFIG_FILE" 2>/dev/null) || OUTPUT_PRICE="$DEFAULT_OUTPUT"
          CACHE_READ_PRICE=$(jq -r ".pricing[\"${LOOKUP_ID}\"].cache_read_per_1k // ${DEFAULT_CACHE_READ}" "$CONFIG_FILE" 2>/dev/null) || CACHE_READ_PRICE="$DEFAULT_CACHE_READ"
          CACHE_WRITE_PRICE=$(jq -r ".pricing[\"${LOOKUP_ID}\"].cache_write_per_1k // ${DEFAULT_CACHE_WRITE}" "$CONFIG_FILE" 2>/dev/null) || CACHE_WRITE_PRICE="$DEFAULT_CACHE_WRITE"
        fi

        MODEL_COST=$(echo "scale=4; (${INPUT_TOKENS} / 1000 * ${INPUT_PRICE}) + (${CACHE_READ_TOKENS} / 1000 * ${CACHE_READ_PRICE}) + (${CACHE_WRITE_TOKENS} / 1000 * ${CACHE_WRITE_PRICE}) + (${OUTPUT_TOKENS} / 1000 * ${OUTPUT_PRICE})" | bc 2>/dev/null) || MODEL_COST="0"
        TOTAL_COST=$(echo "scale=4; ${TOTAL_COST} + ${MODEL_COST}" | bc 2>/dev/null) || TOTAL_COST="0"
      done < <(echo "$RESULTS" | jq -c '.results[]' 2>/dev/null)

      # Write cache
      echo "{\"cost_usd\": ${TOTAL_COST}, \"timestamp\": $(date +%s)}" > "$CACHE_FILE" 2>/dev/null || true
    fi
  fi
fi

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

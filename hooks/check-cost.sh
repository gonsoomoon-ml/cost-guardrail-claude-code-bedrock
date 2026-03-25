#!/usr/bin/env bash
# cost-guardrail: check-cost.sh
# NOTE: No `set -euo pipefail` — this script uses a fail-closed pattern.
# Any unexpected error results in exit 2 (block usage) to prevent
# unmonitored spending. Only verified cost < threshold allows exit 0.

# Resolve plugin root (directory containing .claude-plugin/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_FILE="${PLUGIN_ROOT}/config.json"
COUNTER_FILE="/tmp/claude-cost-guardrail-${USER:-unknown}-counter"
CACHE_FILE="/tmp/claude-cost-guardrail-${USER:-unknown}-cache.json"
DAILY_FILE="/tmp/claude-cost-guardrail-${USER:-unknown}-daily.json"

# 함수 라이브러리 로드
source "${SCRIPT_DIR}/lib-cost.sh" 2>/dev/null || { echo "[cost-guardrail] BLOCKED: lib-cost.sh not found" >&2; exit 2; }

# --- 변수 초기화 ---
TOTAL_COST=""
CACHED_COST=""

# --- Argument Parsing ---
EVENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --event) EVENT="${2:-}"; shift 2 ;;
    *) echo "[cost-guardrail] BLOCKED: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$EVENT" ]]; then
  echo "[cost-guardrail] BLOCKED: Missing --event argument" >&2
  exit 2
fi

# --- 설정 로드 (base + admin 오버라이드 병합) ---
# config.json: 공유 설정 (가격, log_group, 기본 단가)
# admin/config.admin.json: 관리자 정책 (threshold, period, interval 등)
# jq -s '.[0] * .[1]' 로 deep merge — admin 값이 base를 덮어씁니다.
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[cost-guardrail] BLOCKED: config.json not found" >&2
  exit 2
fi

ADMIN_CONFIG="${PLUGIN_ROOT}/admin/config.admin.json"
if [[ -f "$ADMIN_CONFIG" ]]; then
  MERGED_CONFIG=$(jq -s '.[0] * .[1]' "$CONFIG_FILE" "$ADMIN_CONFIG" 2>/dev/null) || { echo "[cost-guardrail] BLOCKED: config merge failed" >&2; exit 2; }
else
  MERGED_CONFIG=$(cat "$CONFIG_FILE") || { echo "[cost-guardrail] BLOCKED: config read failed" >&2; exit 2; }
fi

THRESHOLD_USD=$(echo "$MERGED_CONFIG" | jq -r '.threshold_usd // 50' 2>/dev/null) || { echo "[cost-guardrail] BLOCKED: config parse error" >&2; exit 2; }
PERIOD=$(echo "$MERGED_CONFIG" | jq -r '.period // "monthly"' 2>/dev/null) || { echo "[cost-guardrail] BLOCKED: config parse error" >&2; exit 2; }
CHECK_INTERVAL=$(echo "$MERGED_CONFIG" | jq -r '.check_interval // 10' 2>/dev/null) || { echo "[cost-guardrail] BLOCKED: config parse error" >&2; exit 2; }
LOG_GROUP=$(echo "$MERGED_CONFIG" | jq -r '.log_group // "bedrock/model-invocations"' 2>/dev/null) || { echo "[cost-guardrail] BLOCKED: config parse error" >&2; exit 2; }
TIMEZONE=$(echo "$MERGED_CONFIG" | jq -r '.timezone // "UTC"' 2>/dev/null) || { echo "[cost-guardrail] BLOCKED: config parse error" >&2; exit 2; }
DEFAULT_INPUT=$(echo "$MERGED_CONFIG" | jq -r '.default_input_per_1k // 0.003' 2>/dev/null) || { echo "[cost-guardrail] BLOCKED: config parse error" >&2; exit 2; }
DEFAULT_OUTPUT=$(echo "$MERGED_CONFIG" | jq -r '.default_output_per_1k // 0.015' 2>/dev/null) || { echo "[cost-guardrail] BLOCKED: config parse error" >&2; exit 2; }
DEFAULT_CACHE_READ=$(echo "$MERGED_CONFIG" | jq -r '.default_cache_read_per_1k // 0.0003' 2>/dev/null) || { echo "[cost-guardrail] BLOCKED: config parse error" >&2; exit 2; }
DEFAULT_CACHE_WRITE=$(echo "$MERGED_CONFIG" | jq -r '.default_cache_write_per_1k // 0.00375' 2>/dev/null) || { echo "[cost-guardrail] BLOCKED: config parse error" >&2; exit 2; }
# MERGED_CONFIG_FILE: progressive 등 후속 jq 조회에 사용할 임시 파일
MERGED_CONFIG_FILE="/tmp/claude-cost-guardrail-${USER:-unknown}-merged.json"
echo "$MERGED_CONFIG" > "$MERGED_CONFIG_FILE" 2>/dev/null || true

# Guard: if threshold is 0 or non-numeric, block
if ! echo "$THRESHOLD_USD" | grep -qE '^[0-9]+\.?[0-9]*$' || [[ "$THRESHOLD_USD" == "0" ]]; then
  echo "[cost-guardrail] BLOCKED: Invalid or zero threshold_usd" >&2
  exit 2
fi

# --- 카운터 로직 (prompt_submit만 해당) ---
# progressive 설정이 있으면 비용 근접도에 따라 체크 간격을 조절합니다.
#   비용 >= 100% → 매 프롬프트마다 (즉시 차단)
#   비용 < 50%  → low 간격 (느슨하게, 예: 50회마다)
#   비용 50~80% → mid 간격 (중간, 예: 20회마다)
#   비용 > 80%  → high 간격 (촘촘하게, 예: 5회마다)
# progressive 미설정 시 check_interval 사용 (하위 호환)
if [[ "$EVENT" == "prompt_submit" ]]; then
  # 캐시에서 마지막 비용을 읽어 적정 간격 결정 (추가 쿼리 없음)
  EFFECTIVE_INTERVAL="$CHECK_INTERVAL"
  PROG_LOW=$(jq -r '.progressive.low // null' "$MERGED_CONFIG_FILE" 2>/dev/null)
  if [[ "$PROG_LOW" != "null" && -n "$PROG_LOW" && -f "$CACHE_FILE" ]]; then
    LAST_COST=$(jq -r '.cost_usd // 0' "$CACHE_FILE" 2>/dev/null) || LAST_COST="0"
    COST_PCT=$(awk "BEGIN {printf \"%.0f\", ${LAST_COST} * 100 / ${THRESHOLD_USD}}" 2>/dev/null) || COST_PCT="0"
    PROG_MID=$(jq -r '.progressive.mid // 20' "$MERGED_CONFIG_FILE" 2>/dev/null) || PROG_MID="20"
    PROG_HIGH=$(jq -r '.progressive.high // 5' "$MERGED_CONFIG_FILE" 2>/dev/null) || PROG_HIGH="5"
    if [[ "$COST_PCT" -ge 100 ]]; then
      EFFECTIVE_INTERVAL=1
    elif [[ "$COST_PCT" -lt 50 ]]; then
      EFFECTIVE_INTERVAL="$PROG_LOW"
    elif [[ "$COST_PCT" -lt 80 ]]; then
      EFFECTIVE_INTERVAL="$PROG_MID"
    else
      EFFECTIVE_INTERVAL="$PROG_HIGH"
    fi
  fi

  COUNTER=0
  if [[ -f "$COUNTER_FILE" ]]; then
    COUNTER=$(cat "$COUNTER_FILE" 2>/dev/null) || COUNTER=0
    if ! [[ "$COUNTER" =~ ^[0-9]+$ ]]; then
      COUNTER=0
    fi
  fi
  COUNTER=$((COUNTER + 1))
  if [[ "$COUNTER" -lt "$EFFECTIVE_INTERVAL" ]]; then
    echo "$COUNTER" > "$COUNTER_FILE"
    exit 0  # 이번 체크 건너뜀 (정상 흐름 — 아직 체크 간격에 도달하지 않음)
  fi
  # 카운터 리셋, 비용 확인 진행
  echo "0" > "$COUNTER_FILE"
fi

if [[ "$EVENT" == "session_start" ]]; then
  echo "0" > "$COUNTER_FILE"
fi

# --- Get IAM User ARN ---
USER_ARN=$(aws sts get-caller-identity --query "Arn" --output text 2>/dev/null) || {
  echo "[cost-guardrail] BLOCKED: Failed to get IAM identity" >&2
  exit 2
}

# --- 캐시 확인 (session_start, report는 항상 새로 조회) ---
if [[ "$EVENT" == "prompt_submit" ]] && use_cache; then
  TOTAL_COST="$CACHED_COST"
fi

# --- CloudWatch Logs Insights 쿼리 ---
if [[ -z "$TOTAL_COST" ]]; then
  # 시간 범위 계산 (이식성: date -d 대신 산술 사용)
  NOW_EPOCH=$(date +%s)
  HOUR=$(TZ="$TIMEZONE" date +%H); MIN=$(TZ="$TIMEZONE" date +%M); SEC=$(TZ="$TIMEZONE" date +%S)
  TODAY_START=$(( NOW_EPOCH - (10#$HOUR * 3600) - (10#$MIN * 60) - 10#$SEC ))
  CURRENT_MONTH=$(TZ="$TIMEZONE" date +%Y-%m)
  CURRENT_DATE=$(TZ="$TIMEZONE" date +%Y-%m-%d)

  # CW 쿼리문 (모델별 4종 토큰 집계)
  QUERY_STRING="filter identity.arn = \"${USER_ARN}\"
| stats sum(input.inputTokenCount) as inputTokens, sum(input.cacheReadInputTokenCount) as cacheReadTokens, sum(input.cacheWriteInputTokenCount) as cacheWriteTokens, sum(output.outputTokenCount) as outputTokens by modelId"

  # --- 일별 누적 로직 (monthly만 해당) ---
  # daily 모드는 하루치만 조회하므로 누적 불필요
  USE_FULL_QUERY=""
  PREV_TOTAL="0"

  if [[ "$PERIOD" == "monthly" ]]; then
    init_daily_state

    # session_start 시 어제 비용 확정 (로그 수집 지연 고려)
    if [[ "$EVENT" == "session_start" ]]; then
      finalize_yesterday
    fi

    PREV_TOTAL=$(load_previous_total)

    # 7일마다 전체 월 쿼리로 drift 보정
    if [[ "$(needs_reconciliation)" == "true" ]]; then
      USE_FULL_QUERY="true"
      update_reconcile_timestamp
    fi
  fi

  # --- 보정 쿼리 (monthly + reconciliation) ---
  # 월초 → 오늘 자정 범위만 쿼리하여 previous_total을 갱신합니다.
  # 오늘치 비용은 아래 normal path에서 별도 쿼리로 누산합니다.
  if [[ "$PERIOD" == "monthly" && "$USE_FULL_QUERY" == "true" ]]; then
    DAY=$(TZ="$TIMEZONE" date +%d)
    MONTH_START_EPOCH=$(( TODAY_START - (10#$DAY - 1) * 86400 ))
    RECON_RESULTS=$(run_cw_query "$MONTH_START_EPOCH" "$TODAY_START")
    if [[ -n "$RECON_RESULTS" ]]; then
      RECON_COST=$(calculate_cost_from_results "$RECON_RESULTS")
      # previous_total을 보정값으로 갱신, days 리셋 (보정값이 모든 이전 일자 포함)
      jq --argjson c "$RECON_COST" '.previous_total = $c | .days = {}' \
        "$DAILY_FILE" > "${DAILY_FILE}.tmp" 2>/dev/null && mv "${DAILY_FILE}.tmp" "$DAILY_FILE"
      PREV_TOTAL="$RECON_COST"
    fi
  fi

  # --- 쿼리 시간 범위 결정 ---
  if [[ "$PERIOD" == "daily" ]]; then
    # daily: 오늘 00:00 → 현재
    START_TIME=$TODAY_START
  else
    # monthly (보정 포함): 오늘 00:00 → 현재 (하루치만 스캔)
    START_TIME=$TODAY_START
  fi
  END_TIME=$NOW_EPOCH

  # --- CW 쿼리 실행 + 결과 처리 ---
  RESULTS=$(run_cw_query "$START_TIME" "$END_TIME")

  if [[ -z "$RESULTS" ]]; then
    # 쿼리 실패 — 캐시 사용, 캐시 없으면 block
    if use_cache; then
      TOTAL_COST="$CACHED_COST"
    else
      echo "[cost-guardrail] BLOCKED: CloudWatch query failed and no cache available" >&2
      exit 2
    fi
  else
    # 쿼리 결과 → 비용 계산
    QUERY_COST=$(calculate_cost_from_results "$RESULTS")

    if [[ "$PERIOD" == "daily" ]]; then
      # daily: 쿼리 결과가 곧 총 비용
      TOTAL_COST="$QUERY_COST"
    else
      # monthly (보정 포함): 이전 일자 합계 + 오늘 비용
      TOTAL_COST=$(awk "BEGIN {printf \"%.5f\", ${PREV_TOTAL} + ${QUERY_COST}}" 2>/dev/null) || TOTAL_COST="$QUERY_COST"
    fi

    # 캐시 저장
    echo "{\"cost_usd\": ${TOTAL_COST}, \"timestamp\": $(date +%s)}" > "$CACHE_FILE" 2>/dev/null || true
  fi
fi

# --- Threshold Check ---
# Ensure TOTAL_COST is set
TOTAL_COST="${TOTAL_COST:-0}"

# Calculate percentage
PERCENT=$(awk "BEGIN {printf \"%.1f\", ${TOTAL_COST} * 100 / ${THRESHOLD_USD}}" 2>/dev/null) || PERCENT="0"

# Report mode — always print, never block
if [[ "$EVENT" == "report" ]]; then
  echo "User: ${USER_ARN}"
  if [[ "$PERIOD" == "daily" ]]; then
    echo "Period: $(TZ="$TIMEZONE" date +%Y-%m-%d) (${PERIOD})"
  else
    echo "Period: $(TZ="$TIMEZONE" date +%Y-%m) (${PERIOD})"
  fi
  echo "Estimated cost: \$${TOTAL_COST} / \$${THRESHOLD_USD} (${PERCENT}%)"
  if [ "$(awk "BEGIN {print (${TOTAL_COST} >= ${THRESHOLD_USD}) ? 1 : 0}")" = "1" ]; then
    echo "Status: BLOCKED"
  else
    echo "Status: Active"
  fi
  exit 0
fi

# Check threshold
EXCEEDED=$(awk "BEGIN {print (${TOTAL_COST} >= ${THRESHOLD_USD}) ? 1 : 0}" 2>/dev/null) || EXCEEDED="0"
if [[ "$EXCEEDED" == "1" ]]; then
  echo "[cost-guardrail] BLOCKED: Estimated Bedrock cost \$${TOTAL_COST} has reached threshold \$${THRESHOLD_USD} (${PERCENT}%)" >&2
  echo "[cost-guardrail] Contact your admin to adjust threshold." >&2
  exit 2
fi

exit 0

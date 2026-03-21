#!/usr/bin/env bash
# ============================================================================
# lib-cost.sh — 비용 계산 및 상태 관리 함수 라이브러리
# check-cost.sh에서 source하여 사용합니다.
#
# 의존하는 외부 변수 (check-cost.sh에서 설정):
#   CONFIG_FILE, LOG_GROUP, TIMEZONE, QUERY_STRING
#   DEFAULT_INPUT, DEFAULT_OUTPUT, DEFAULT_CACHE_READ, DEFAULT_CACHE_WRITE
#   CACHE_FILE, DAILY_FILE, CURRENT_MONTH, TODAY_START
# ============================================================================

# --- 캐시 관리 ---------------------------------------------------------------
# 캐시 파일의 유효성을 확인하고, 유효하면 CACHED_COST에 값을 설정합니다.
# 인자: $1 = TTL(초), 기본 300초(5분)
# 반환: 0(유효) 또는 1(만료/없음)
use_cache() {
  local ttl="${1:-300}"
  if [[ -f "$CACHE_FILE" ]]; then
    local cache_ts
    cache_ts=$(jq -r '.timestamp // 0' "$CACHE_FILE" 2>/dev/null) || { return 1; }
    local now_ts
    now_ts=$(date +%s)
    local age=$(( now_ts - cache_ts ))
    if [[ "$age" -lt "$ttl" ]]; then
      CACHED_COST=$(jq -r '.cost_usd // 0' "$CACHE_FILE" 2>/dev/null) || { return 1; }
      return 0
    fi
  fi
  return 1
}

# --- CW 쿼리 결과 → 비용 계산 ------------------------------------------------
# CloudWatch Logs Insights 쿼리 결과 JSON을 받아서 총 비용($)을 계산합니다.
# 각 모델별로: (토큰수 / 1000) × 단가 를 4종 토큰에 대해 합산합니다.
# 인자: $1 = aws logs get-query-results의 전체 JSON 출력
# 출력: 총 비용 (stdout, 예: "35.67000")
calculate_cost_from_results() {
  local results="$1"
  local total="0"

  while IFS= read -r row; do
    # 필드 이름으로 파싱 (배열 위치가 아닌 이름 기반 — AWS 스키마 변경에 안전)
    local MODEL_ID_RAW INPUT_TOKENS CACHE_READ_TOKENS CACHE_WRITE_TOKENS OUTPUT_TOKENS
    MODEL_ID_RAW=$(echo "$row" | jq -r '.[] | select(.field == "modelId") | .value // ""' 2>/dev/null) || continue
    INPUT_TOKENS=$(echo "$row" | jq -r '[.[] | select(.field == "inputTokens") | .value] | first // "0"' 2>/dev/null) || INPUT_TOKENS="0"
    CACHE_READ_TOKENS=$(echo "$row" | jq -r '[.[] | select(.field == "cacheReadTokens") | .value] | first // "0"' 2>/dev/null) || CACHE_READ_TOKENS="0"
    CACHE_WRITE_TOKENS=$(echo "$row" | jq -r '[.[] | select(.field == "cacheWriteTokens") | .value] | first // "0"' 2>/dev/null) || CACHE_WRITE_TOKENS="0"
    OUTPUT_TOKENS=$(echo "$row" | jq -r '[.[] | select(.field == "outputTokens") | .value] | first // "0"' 2>/dev/null) || OUTPUT_TOKENS="0"

    # 숫자 검증 (빈 문자열이나 비숫자 → 0)
    INPUT_TOKENS="${INPUT_TOKENS:-0}"; [[ "$INPUT_TOKENS" =~ ^[0-9]+$ ]] || INPUT_TOKENS="0"
    CACHE_READ_TOKENS="${CACHE_READ_TOKENS:-0}"; [[ "$CACHE_READ_TOKENS" =~ ^[0-9]+$ ]] || CACHE_READ_TOKENS="0"
    CACHE_WRITE_TOKENS="${CACHE_WRITE_TOKENS:-0}"; [[ "$CACHE_WRITE_TOKENS" =~ ^[0-9]+$ ]] || CACHE_WRITE_TOKENS="0"
    OUTPUT_TOKENS="${OUTPUT_TOKENS:-0}"; [[ "$OUTPUT_TOKENS" =~ ^[0-9]+$ ]] || OUTPUT_TOKENS="0"

    # 토큰 데이터가 전혀 없으면 건너뜀
    if [[ "$INPUT_TOKENS" == "0" && "$CACHE_READ_TOKENS" == "0" && "$CACHE_WRITE_TOKENS" == "0" && "$OUTPUT_TOKENS" == "0" ]]; then
      continue
    fi

    # ARN에서 모델 ID 추출
    # 예: "arn:aws:bedrock:us-west-2:123:inference-profile/us.anthropic.claude-opus-4-6-v1"
    #   → "us.anthropic.claude-opus-4-6-v1"
    local MODEL_ID="$MODEL_ID_RAW"
    if [[ "$MODEL_ID" == arn:* ]]; then
      MODEL_ID="${MODEL_ID##*/}"
    fi

    # 모델 가격 조회: 정확히 일치 → us. 접두사 제거 후 재시도 → 기본 단가
    local LOOKUP_ID="$MODEL_ID" INPUT_PRICE OUTPUT_PRICE CACHE_READ_PRICE CACHE_WRITE_PRICE
    INPUT_PRICE=$(jq -r ".pricing[\"${LOOKUP_ID}\"].input_per_1k // null" "$CONFIG_FILE" 2>/dev/null)
    if [[ "$INPUT_PRICE" == "null" || -z "$INPUT_PRICE" ]]; then
      LOOKUP_ID="${MODEL_ID#us.}"
      INPUT_PRICE=$(jq -r ".pricing[\"${LOOKUP_ID}\"].input_per_1k // null" "$CONFIG_FILE" 2>/dev/null)
    fi
    if [[ "$INPUT_PRICE" == "null" || -z "$INPUT_PRICE" ]]; then
      INPUT_PRICE="$DEFAULT_INPUT"; OUTPUT_PRICE="$DEFAULT_OUTPUT"
      CACHE_READ_PRICE="$DEFAULT_CACHE_READ"; CACHE_WRITE_PRICE="$DEFAULT_CACHE_WRITE"
    else
      OUTPUT_PRICE=$(jq -r ".pricing[\"${LOOKUP_ID}\"].output_per_1k // ${DEFAULT_OUTPUT}" "$CONFIG_FILE" 2>/dev/null) || OUTPUT_PRICE="$DEFAULT_OUTPUT"
      CACHE_READ_PRICE=$(jq -r ".pricing[\"${LOOKUP_ID}\"].cache_read_per_1k // ${DEFAULT_CACHE_READ}" "$CONFIG_FILE" 2>/dev/null) || CACHE_READ_PRICE="$DEFAULT_CACHE_READ"
      CACHE_WRITE_PRICE=$(jq -r ".pricing[\"${LOOKUP_ID}\"].cache_write_per_1k // ${DEFAULT_CACHE_WRITE}" "$CONFIG_FILE" 2>/dev/null) || CACHE_WRITE_PRICE="$DEFAULT_CACHE_WRITE"
    fi

    # 모델별 비용 = (토큰수 / 1000) × 단가, 4종 합산
    local MODEL_COST
    MODEL_COST=$(awk "BEGIN {printf \"%.5f\", \
      (${INPUT_TOKENS} / 1000 * ${INPUT_PRICE}) + \
      (${CACHE_READ_TOKENS} / 1000 * ${CACHE_READ_PRICE}) + \
      (${CACHE_WRITE_TOKENS} / 1000 * ${CACHE_WRITE_PRICE}) + \
      (${OUTPUT_TOKENS} / 1000 * ${OUTPUT_PRICE})}" 2>/dev/null) || MODEL_COST="0"
    total=$(awk "BEGIN {printf \"%.5f\", ${total} + ${MODEL_COST}}" 2>/dev/null) || true
  done < <(echo "$results" | jq -c '.results[]' 2>/dev/null)

  echo "$total"
}

# --- CW 쿼리 실행 (비동기 3단계) ---------------------------------------------
# CloudWatch Logs Insights 쿼리를 시작하고 결과를 폴링합니다.
# 인자: $1 = start_time (epoch), $2 = end_time (epoch)
# 출력: 쿼리 결과 JSON (stdout) 또는 빈 문자열 (실패 시)
run_cw_query() {
  local start_time="$1" end_time="$2"

  # 1단계: 쿼리 시작
  local query_id
  query_id=$(aws logs start-query \
    --log-group-name "$LOG_GROUP" \
    --start-time "$start_time" \
    --end-time "$end_time" \
    --query-string "$QUERY_STRING" \
    --query "queryId" --output text 2>/dev/null) || { echo ""; return; }

  # 2단계: 결과 대기 (progressive backoff, 최대 25초)
  # 처음 2회는 2초 간격 (빠른 쿼리 조기 감지), 이후 3초 간격
  # 25초 = session_start의 60초 timeout 내에서 2회 쿼리 가능 (25×2 + 오버헤드 < 60)
  local status results=""
  for (( i=1; i<=9; i++ )); do
    sleep $(( i < 3 ? 2 : 3 ))
    status=$(aws logs get-query-results --query-id "$query_id" --query "status" --output text 2>/dev/null) || break
    if [[ "$status" == "Complete" ]]; then
      results=$(aws logs get-query-results --query-id "$query_id" --output json 2>/dev/null) || break
      break
    elif [[ "$status" == "Failed" || "$status" == "Cancelled" ]]; then
      break
    fi
  done

  # 3단계: 결과 반환
  echo "$results"
}

# --- 일별 누적 상태 관리 -----------------------------------------------------
# 상태 파일 형식:
# {
#   "month": "2026-03",
#   "days": {"2026-03-01": 5.20, "2026-03-02": 3.10, ...},
#   "previous_total": 87.60,
#   "last_reconcile": 1774310400
# }

# 상태 파일 초기화 (월이 바뀌면 리셋)
init_daily_state() {
  local file_month=""
  if [[ -f "$DAILY_FILE" ]]; then
    file_month=$(jq -r '.month // ""' "$DAILY_FILE" 2>/dev/null) || file_month=""
  fi
  if [[ "$file_month" != "$CURRENT_MONTH" ]]; then
    echo "{\"month\":\"${CURRENT_MONTH}\",\"days\":{},\"previous_total\":0,\"last_reconcile\":$(date +%s)}" \
      > "$DAILY_FILE" 2>/dev/null || true
  fi
}

# 확정된 이전 일자 비용 합계를 반환합니다.
# 예: 3월 1~20일 확정 비용의 합 = previous_total
load_previous_total() {
  if [[ ! -f "$DAILY_FILE" ]]; then echo "0"; return; fi
  local file_month
  file_month=$(jq -r '.month // ""' "$DAILY_FILE" 2>/dev/null) || { echo "0"; return; }
  if [[ "$file_month" != "$CURRENT_MONTH" ]]; then echo "0"; return; fi
  jq -r '.previous_total // 0' "$DAILY_FILE" 2>/dev/null || echo "0"
}

# 어제 비용을 확정합니다.
# session_start 시에만 호출 — 로그 수집 지연을 고려하여 어제 데이터가 완전히
# CloudWatch에 도착한 후에 확정합니다.
finalize_yesterday() {
  local yesterday_start yesterday_end yesterday_date
  yesterday_start=$(( TODAY_START - 86400 ))
  yesterday_end=$TODAY_START

  # 어제 날짜 문자열 (이식성: GNU date -d @epoch → BSD date -r epoch)
  yesterday_date=$(TZ="$TIMEZONE" date -d @$yesterday_start +%Y-%m-%d 2>/dev/null) || \
    yesterday_date=$(TZ="$TIMEZONE" date -r $yesterday_start +%Y-%m-%d 2>/dev/null) || return

  # 다른 월이면 건너뜀 (예: 4월 1일에 3월 31일 확정 불필요 — 이미 월 리셋됨)
  local yesterday_month="${yesterday_date:0:7}"
  if [[ "$yesterday_month" != "$CURRENT_MONTH" ]]; then return; fi

  # 이미 확정된 날짜면 건너뜀
  local already
  already=$(jq -r ".days[\"$yesterday_date\"] // \"null\"" "$DAILY_FILE" 2>/dev/null) || already="null"
  if [[ "$already" != "null" ]]; then return; fi

  # 어제 하루치만 CW 쿼리 (스캔 범위가 작아서 빠름)
  local yq_results
  yq_results=$(run_cw_query "$yesterday_start" "$yesterday_end")
  if [[ -z "$yq_results" ]]; then return; fi

  # 어제 비용 계산 후 상태 파일 업데이트
  local yesterday_cost prev_total new_total
  yesterday_cost=$(calculate_cost_from_results "$yq_results")
  prev_total=$(jq -r '.previous_total // 0' "$DAILY_FILE" 2>/dev/null) || prev_total="0"
  new_total=$(awk "BEGIN {printf \"%.5f\", ${prev_total} + ${yesterday_cost}}" 2>/dev/null) || return

  jq --arg d "$yesterday_date" --argjson c "$yesterday_cost" --argjson t "$new_total" \
    '.days[$d] = $c | .previous_total = $t' "$DAILY_FILE" > "${DAILY_FILE}.tmp" 2>/dev/null && \
    mv "${DAILY_FILE}.tmp" "$DAILY_FILE"
}

# --- 주간 보정 (drift 방지) --------------------------------------------------
# 일별 누적은 근사값이므로, 7일마다 전체 월 쿼리로 실제 비용과 보정합니다.
# 반환: "true"(보정 필요) 또는 "false"
needs_reconciliation() {
  if [[ ! -f "$DAILY_FILE" ]]; then echo "false"; return; fi
  local last_rec now_ts age
  last_rec=$(jq -r '.last_reconcile // 0' "$DAILY_FILE" 2>/dev/null) || { echo "false"; return; }
  now_ts=$(date +%s)
  age=$(( now_ts - last_rec ))
  # 604800초 = 7일
  if [[ "$age" -ge 604800 ]]; then echo "true"; else echo "false"; fi
}

# 보정 타임스탬프를 현재 시각으로 갱신합니다.
update_reconcile_timestamp() {
  local now_ts=$(date +%s)
  jq --argjson t "$now_ts" '.last_reconcile = $t' "$DAILY_FILE" > "${DAILY_FILE}.tmp" 2>/dev/null && \
    mv "${DAILY_FILE}.tmp" "$DAILY_FILE"
}

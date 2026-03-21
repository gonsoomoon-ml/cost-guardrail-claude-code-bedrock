#!/usr/bin/env bash
# ============================================================================
# preflight.sh — 비용 가드레일 플러그인 사전 요구사항 점검
# 사용법: bash scripts/preflight.sh
#
# 플러그인 설치 후 또는 문제 발생 시 실행하여
# 필수 도구, AWS 자격 증명, 로그 그룹 등을 한번에 점검합니다.
# ============================================================================

PASS=0
FAIL=0
WARN=0

# --- 점검 결과 출력 함수 ---
check() {
  local label="$1" result="$2" fix="${3:-}"
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

# --- 플랫폼 감지 ---
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

# --- 1. Bash 버전 ---
BASH_VER="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
  check "Bash $BASH_VER" "ok"
elif [[ "${BASH_VERSINFO[0]}" -ge 3 ]]; then
  case "$OS" in
    macos) FIX="brew install bash" ;;
    *)     FIX="패키지 매니저로 bash 업데이트" ;;
  esac
  check "Bash $BASH_VER (3.x 호환되지만 4+ 권장)" "warn" "$FIX"
else
  check "Bash $BASH_VER (너무 오래됨)" "fail" "Bash 4+ 설치 필요"
fi

# --- 2. jq ---
if command -v jq &>/dev/null; then
  check "jq $(jq --version 2>&1)" "ok"
else
  case "$OS" in
    macos)       FIX="brew install jq" ;;
    linux|wsl)   FIX="sudo apt install jq  또는  sudo yum install jq" ;;
    gitbash)     FIX="https://jqlang.github.io/jq/download/ 에서 다운로드" ;;
    *)           FIX="jq 설치 필요" ;;
  esac
  check "jq 미설치" "fail" "$FIX"
fi

# --- 3. awk ---
if command -v awk &>/dev/null; then
  check "awk 사용 가능" "ok"
else
  check "awk 미설치" "fail" "gawk 또는 mawk 설치 필요"
fi

# --- 4. AWS CLI ---
if command -v aws &>/dev/null; then
  AWS_VER=$(aws --version 2>&1 | head -1)
  check "AWS CLI: $AWS_VER" "ok"
else
  case "$OS" in
    macos)  FIX="brew install awscli" ;;
    *)      FIX="https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" ;;
  esac
  check "AWS CLI 미설치" "fail" "$FIX"
fi

# --- 5. AWS 자격 증명 ---
if aws sts get-caller-identity --query "Arn" --output text &>/dev/null; then
  ARN=$(aws sts get-caller-identity --query "Arn" --output text 2>/dev/null)
  check "AWS 인증: $ARN" "ok"
else
  check "AWS 자격 증명 미설정 또는 만료" "fail" "aws configure 또는 aws sso login 실행"
fi

# --- 6. CloudWatch 로그 그룹 ---
LOG_GROUP="bedrock/model-invocations"
# 플러그인 config.json에서 log_group 읽기 시도
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${PLUGIN_ROOT}/config.json" ]]; then
  CUSTOM_LG=$(jq -r '.log_group // ""' "${PLUGIN_ROOT}/config.json" 2>/dev/null)
  [[ -n "$CUSTOM_LG" ]] && LOG_GROUP="$CUSTOM_LG"
fi

if aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP" \
  --query "logGroups[?logGroupName=='$LOG_GROUP'].logGroupName" \
  --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
  check "로그 그룹: $LOG_GROUP" "ok"
else
  check "로그 그룹 '$LOG_GROUP' 없음" "fail" \
    "Bedrock Model Invocation Logging 활성화 필요 (로그 그룹: $LOG_GROUP)"
fi

# --- 7. CloudWatch 권한 (logs:StartQuery) ---
# 간단한 1초 쿼리로 권한 테스트
if [[ "$FAIL" -eq 0 ]]; then
  NOW=$(date +%s)
  TEST_QID=$(aws logs start-query \
    --log-group-name "$LOG_GROUP" \
    --start-time $((NOW - 60)) \
    --end-time "$NOW" \
    --query-string "fields @timestamp | limit 1" \
    --query "queryId" --output text 2>/dev/null)
  if [[ -n "$TEST_QID" ]]; then
    check "CloudWatch 쿼리 권한 (logs:StartQuery)" "ok"
  else
    check "CloudWatch 쿼리 권한 없음" "fail" \
      "IAM 정책에 logs:StartQuery, logs:GetQueryResults 권한 추가 필요"
  fi
fi

# --- 결과 요약 ---
echo ""
echo "─────────────────────────────"
echo "결과: ${PASS} 통과, ${FAIL} 실패, ${WARN} 경고"
if [[ "$FAIL" -gt 0 ]]; then
  echo "위의 실패 항목을 해결한 후 플러그인을 사용하세요."
  exit 1
else
  echo "모든 점검 통과. 플러그인 사용 준비 완료."
  exit 0
fi

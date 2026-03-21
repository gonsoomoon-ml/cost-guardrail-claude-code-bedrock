# 비용 조회 동작 원리

이 문서는 `check-cost.sh`가 CloudWatch Logs Insights를 통해 비용을 조회하고 계산하는 전체 흐름을 설명합니다.

## 전체 흐름 요약

```
Claude Code 이벤트 발생
  → check-cost.sh 실행
    → IAM User ARN 확인
      → CloudWatch Logs Insights 쿼리 (비동기)
        → 모델별 토큰 집계
          → config.json 가격표로 비용 계산
            → 임계값 비교 → 허용 또는 차단
```

## 1단계: 이벤트 수신 및 실행 조건

`check-cost.sh`는 세 가지 이벤트로 호출됩니다:

| 이벤트 | 언제 | 동작 |
|--------|------|------|
| `session_start` | Claude Code 세션 시작 시 | 항상 CloudWatch 쿼리 실행 (캐시 무시) |
| `prompt_submit` | 사용자 프롬프트 입력 시 | N번째마다만 실행 (기본 10). 5분 캐시 사용 |
| `report` | `/cost-status` 명령 시 | 항상 CloudWatch 쿼리 실행. 절대 차단 안 함 |

### 카운터 기반 스로틀링 (prompt_submit만 해당)

```
프롬프트 1  → 카운터 1 → 스킵
프롬프트 2  → 카운터 2 → 스킵
  ...
프롬프트 9  → 카운터 9 → 스킵
프롬프트 10 → 카운터 10 → CloudWatch 쿼리 실행, 카운터 리셋
프롬프트 11 → 카운터 1 → 스킵
  ...
```

카운터 파일: `/tmp/claude-cost-guardrail-${USER}-counter`

## 2단계: IAM User 확인

```bash
aws sts get-caller-identity --query "Arn" --output text
# → arn:aws:iam::738490718699:user/Administrator
```

이 ARN으로 "누구의 비용인지"를 CloudWatch 쿼리에서 필터링합니다.

## 3단계: 조회 기간 (Time Window) 계산

### Monthly 모드 (기본)

**매월 1일 00:00:00 ~ 현재**까지의 누적 비용을 조회합니다.

3월 21일에 조회하면:
```
3월 1일                  3월 21일 (현재)              3월 31일
  |████████████████████████|                           |
  START_TIME               END_TIME

  → 3월 1일~21일의 모든 Bedrock 호출 로그를 스캔
```

3월 22일에 조회하면:
```
3월 1일                        3월 22일 (현재)        3월 31일
  |██████████████████████████████|                     |
  START_TIME                     END_TIME

  → 3월 1일~22일의 모든 로그 스캔 (어제 사용량 포함)
```

**핵심: 조회 범위는 매일 커집니다.** 3월 말에는 한 달치 전체 로그를 스캔합니다.

4월 1일이 되면:
```
3월:  |████████████████████████████████████████|  ← 누적 $200
4월:  |█|  ← $0 부터 다시 시작
```

### Daily 모드

**오늘 00:00:00 ~ 현재**까지만 조회합니다.

3월 21일:
```
3월 21일 00:00        현재
  |██████████████████|
  → 오늘 사용량만 계산
```

3월 22일 (자정 이후 리셋):
```
3월 22일 00:00        현재
  |████|
  → 어제 비용은 사라지고, 오늘분만 계산
```

### Monthly vs Daily 비교

```
Monthly (한 달간 누적):

3월 1일    3월 10일    3월 21일    3월 22일    3월 31일
  $0        $15        $36         $44         $200  ← 계속 증가

Daily (매일 리셋):

3월 21일                          3월 22일
  $0    $5    $12                   $0    $3   ...
                ↑ 하루 끝             ↑ 새로 시작
```

## 4단계: CloudWatch Logs Insights 쿼리

### 쿼리문

```sql
filter identity.arn = "arn:aws:iam::738490718699:user/Administrator"
| stats sum(input.inputTokenCount) as inputTokens,
        sum(input.cacheReadInputTokenCount) as cacheReadTokens,
        sum(input.cacheWriteInputTokenCount) as cacheWriteTokens,
        sum(output.outputTokenCount) as outputTokens
  by modelId
```

| 절 | 역할 |
|----|------|
| `filter identity.arn = "..."` | 이 IAM 사용자의 로그만 필터링 |
| `stats sum(...) as ...` | 4가지 토큰 유형을 각각 합산 |
| `by modelId` | 모델별로 그룹화 (Opus, Sonnet, Haiku 각각 별도 집계) |

### 비동기 실행 (3단계 프로세스)

CloudWatch Logs Insights 쿼리는 즉시 결과를 반환하지 않습니다:

```
┌─────────────────────────────────────────────────────────┐
│ Step 1: 쿼리 시작                                        │
│   aws logs start-query ... → query_id 반환               │
│                                                          │
│ Step 2: 결과 대기 (최대 5회, 3초 간격 = 최대 15초)         │
│   aws logs get-query-results --query-id xxx              │
│   → status: Running → Running → Complete                 │
│                                                          │
│ Step 3: 결과 파싱                                        │
│   results 배열에서 모델별 토큰 수 추출                     │
└─────────────────────────────────────────────────────────┘
```

### 쿼리 결과 예시

```json
{
  "status": "Complete",
  "results": [
    [
      {"field": "modelId", "value": "arn:aws:bedrock:us-west-2:123:inference-profile/us.anthropic.claude-opus-4-6-v1"},
      {"field": "inputTokens", "value": "500000"},
      {"field": "cacheReadTokens", "value": "2000000"},
      {"field": "cacheWriteTokens", "value": "50000"},
      {"field": "outputTokens", "value": "300000"}
    ],
    [
      {"field": "modelId", "value": "arn:aws:bedrock:us-west-2:123:inference-profile/us.anthropic.claude-sonnet-4-6-v1"},
      {"field": "inputTokens", "value": "100000"},
      {"field": "cacheReadTokens", "value": "500000"},
      {"field": "cacheWriteTokens", "value": "20000"},
      {"field": "outputTokens", "value": "80000"}
    ]
  ]
}
```

각 배열은 한 모델의 해당 기간 토큰 합계입니다.

### 결과 파싱 방식

필드를 **이름으로 검색**합니다 (배열 위치가 아님):

```bash
# 위치 기반 (❌ — AWS가 필드 순서를 바꾸면 깨짐)
MODEL_ID=$(echo "$row" | jq -r '.[0].value')

# 이름 기반 (✅ — 스키마 변경에 안전)
MODEL_ID=$(echo "$row" | jq -r '.[] | select(.field == "modelId") | .value')
```

## 5단계: 모델 ID 추출 및 가격 조회

### ARN에서 모델 ID 추출

Bedrock 로그의 `modelId`는 ARN 형태입니다:

```
arn:aws:bedrock:us-west-2:123:inference-profile/us.anthropic.claude-opus-4-6-v1
                                                 ↓
                                      us.anthropic.claude-opus-4-6-v1
                                                 ↓ (us. 접두사 제거)
                                      anthropic.claude-opus-4-6-v1
```

### 가격 조회 체인

```
1. config.json에서 정확히 일치하는 모델 검색
   → "us.anthropic.claude-opus-4-6-v1" → 없음

2. "us." 접두사 제거 후 재검색
   → "anthropic.claude-opus-4-6-v1" → 찾음!

3. 그래도 없으면 기본 단가 사용
   → default_input_per_1k, default_output_per_1k 등
```

## 6단계: 비용 계산

각 모델별로 4가지 토큰 유형의 비용을 합산합니다:

```
모델 비용 = (inputTokens / 1000 × input_per_1k)
          + (cacheReadTokens / 1000 × cache_read_per_1k)
          + (cacheWriteTokens / 1000 × cache_write_per_1k)
          + (outputTokens / 1000 × output_per_1k)
```

### 구체적 예시 (3월 21일 기준)

**Opus 사용량:**
```
input:       500,000 토큰
cache_read: 2,000,000 토큰
cache_write:  50,000 토큰
output:      300,000 토큰
```

**Opus 가격 (config.json):**
```
input_per_1k:       $0.015
cache_read_per_1k:  $0.0015
cache_write_per_1k: $0.01875
output_per_1k:      $0.075
```

**계산:**
```
input:       500,000 / 1,000 × $0.015   = $7.50
cache_read: 2,000,000 / 1,000 × $0.0015  = $3.00
cache_write:  50,000 / 1,000 × $0.01875 = $0.9375
output:      300,000 / 1,000 × $0.075   = $22.50
─────────────────────────────────────────
Opus 소계:                                 $33.94
```

**Sonnet도 동일하게 계산 후 합산:**
```
Opus 소계:   $33.94
Sonnet 소계:  $1.73
─────────────────
총 비용:      $35.67
```

## 7단계: 임계값 비교 및 결과

```
총 비용 $35.67 vs 임계값 $1,000

$35.67 < $1,000 → exit 0 (허용)
```

만약 비용이 임계값 이상이면:
```
$1,050 >= $1,000 → exit 2 (차단)

[cost-guardrail] BLOCKED: Estimated Bedrock cost $1050 has reached threshold $1000 (105.0%)
```

| exit 코드 | 의미 |
|-----------|------|
| `exit 0` | 허용 (정상, 에러, fail-open 모두 포함) |
| `exit 2` | 차단 (비용 >= 임계값, `report` 모드에서는 절대 발생 안 함) |

## 캐시 동작

### 캐시 저장

CloudWatch 쿼리 성공 시 결과를 파일에 저장합니다:

```json
// /tmp/claude-cost-guardrail-Administrator-cache.json
{"cost_usd": 35.67, "timestamp": 1774310400}
```

### 캐시 사용 조건

| 이벤트 | 캐시 사용 | 이유 |
|--------|----------|------|
| `session_start` | ❌ 항상 새로 쿼리 | 세션 시작 시 최신 비용 필요 |
| `report` | ❌ 항상 새로 쿼리 | 사용자가 명시적으로 확인 요청 |
| `prompt_submit` | ✅ 5분 이내면 사용 | 성능 + CloudWatch 비용 절약 |

### 캐시 흐름 예시

```
14:00 prompt_submit (10번째) → 캐시 없음 → CloudWatch 쿼리 → $35.67 캐시 저장
14:03 prompt_submit (20번째) → 캐시 유효 (3분 < 5분) → $35.67 반환
14:06 prompt_submit (30번째) → 캐시 만료 (6분 > 5분) → CloudWatch 재쿼리 → $35.80 캐시 갱신
  ...
다음 날 09:00 session_start → 캐시 무시 → CloudWatch 쿼리 → 새 비용
```

## Fail-Open 패턴

모든 에러 상황에서 차단 대신 허용합니다:

```
config.json 없음       → exit 0 (허용)
AWS 인증 실패           → exit 0 (허용)
CloudWatch 쿼리 실패    → 캐시 확인 → 캐시도 없으면 exit 0 (허용)
CloudWatch 쿼리 타임아웃 → 캐시 확인 → 캐시도 없으면 exit 0 (허용)
jq 파싱 에러            → exit 0 (허용)
```

**설계 철학:** 인프라 장애로 개발자를 차단하는 것보다, 일시적으로 비용 초과를 허용하는 것이 낫다.

## 일별 누적 (Daily Accumulation)

Monthly 모드에서 매번 월초부터 쿼리하면, 월말로 갈수록 스캔 범위가 커집니다.
500명 기준 월말: 매 쿼리당 ~4 GB 스캔 → CW 비용만 월 $22,000.

이를 해결하기 위해 **일별 누적** 방식을 사용합니다:

### 동작 원리

```
기존 방식 (매번 전체 월 스캔):
  3월 21일 쿼리: 3월 1일 → 현재 (21일치 전체 스캔)

일별 누적 방식:
  3월 1~20일: 확정된 일별 비용을 로컬 파일에 저장 (previous_total)
  3월 21일 쿼리: 오늘 00:00 → 현재 (1일치만 스캔)
  총 비용 = previous_total + 오늘 쿼리 결과
```

### 상태 파일

`/tmp/claude-cost-guardrail-${USER}-daily.json`:

```json
{
  "month": "2026-03",
  "days": {
    "2026-03-01": 5.20,
    "2026-03-02": 3.10,
    "2026-03-20": 6.80
  },
  "previous_total": 87.60,
  "last_reconcile": 1774310400
}
```

### 어제 비용 확정

`session_start` 시에만 어제 비용을 확정합니다:

```
3월 22일 session_start:
  1. 어제(3월 21일) CW 쿼리 → $8.30
  2. days["2026-03-21"] = $8.30
  3. previous_total = $87.60 + $8.30 = $95.90
  4. 오늘 CW 쿼리 → $2.50
  5. 총 비용 = $95.90 + $2.50 = $98.40
```

### 주간 보정 (Weekly Reconciliation)

일별 누적은 근사값이므로, 7일마다 전체 월 쿼리를 실행하여 실제 비용과 보정합니다.
500명 기준 보정 비용: ~$10/주 (무시 가능).

### 월 변경

4월 1일이 되면 상태 파일이 자동 리셋됩니다 (`month` 필드 비교).

## Progressive Checking (적응형 체크 간격)

비용이 임계값에서 멀면 느슨하게, 가까우면 촘촘하게 확인합니다:

```
비용 < 50%  → 50번째 프롬프트마다 확인 (느슨)
비용 50~80% → 20번째 프롬프트마다 확인 (중간)
비용 > 80%  → 5번째 프롬프트마다 확인 (촘촘)
```

마지막 캐시된 비용을 기준으로 판단하므로, 추가 CW 쿼리 없이 결정됩니다.

`config.json` 설정:

```json
{
  "progressive": {"low": 50, "mid": 20, "high": 5}
}
```

미설정 시 `check_interval` 값을 균일하게 사용합니다 (하위 호환).

## CloudWatch 비용 고려사항

CloudWatch Logs Insights는 **스캔한 데이터량**에 따라 과금됩니다 ($0.005/GB).

### 일별 누적 적용 전후 비교 (500명, monthly, 월말)

| | 스캔/쿼리 | 쿼리/시간 | CW 비용/월 |
|---|---|---|---|
| 기존 (전체 월 스캔) | ~4 GB | 1,500 | ~$22,000 |
| 일별 누적 + progressive | ~130 MB | ~500 | ~$150 |

### 최적화 3가지

1. **일별 누적**: 스캔 범위 31배 축소 (가장 큰 효과)
2. **Progressive checking**: 저비용 사용자의 쿼리 횟수 5배 감소
3. **캐시**: 5분 이내 재쿼리 방지

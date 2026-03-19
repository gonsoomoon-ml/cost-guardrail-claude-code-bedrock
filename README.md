# Cost Guardrail Plugin

IAM 사용자별 Amazon Bedrock API 비용을 모니터링하고, 설정된 임계값에 도달하면 Claude Code 사용을 자동 차단하는 플러그인입니다.

## 아키텍처

### 구성 요소

```mermaid
graph TB
    subgraph "Claude Code"
        CC[Claude Code CLI]
        SJ["~/.claude/settings.json<br/>(hooks 등록 — 차단 실행)"]
    end

    subgraph "cost-guardrail 플러그인"
        PJ[".claude-plugin/plugin.json"]
        HJ["hooks/hooks.json"]
        CS["hooks/check-cost.sh"]
        CF["config.json<br/>(임계값, 모델별 단가)"]
        CMD1["/cost-status"]
        CMD2["/cost-config"]
        SK["skills/cost-awareness"]
    end

    subgraph "로컬 상태 (/tmp/)"
        CTR["counter 파일<br/>(N번째 프롬프트 추적)"]
        CACHE["cache.json<br/>(비용 캐시, 5분 TTL)"]
    end

    subgraph "AWS"
        STS["STS<br/>(IAM 사용자 식별)"]
        CW["CloudWatch Logs Insights<br/>(Bedrock 토큰 사용량 조회)"]
        BR["Bedrock Model<br/>Invocation Logging"]
    end

    CC -->|"SessionStart / UserPromptSubmit"| SJ
    SJ -->|"bash check-cost.sh"| CS
    CS --> CF
    CS --> CTR
    CS --> CACHE
    CS -->|"sts:GetCallerIdentity"| STS
    CS -->|"logs:StartQuery / GetQueryResults"| CW
    BR -->|"로그 기록"| CW
    CMD1 -->|"--event report"| CS
    CMD2 --> CF

    style CS fill:#f9a825,color:#000
    style SJ fill:#e53935,color:#fff
    style CW fill:#1565c0,color:#fff
```

### 비용 확인 흐름 (Sequence Diagram)

```mermaid
sequenceDiagram
    participant U as 사용자
    participant CC as Claude Code
    participant SH as check-cost.sh
    participant TMP as /tmp/ (counter, cache)
    participant AWS as AWS (STS + CloudWatch)

    Note over CC: SessionStart
    CC->>SH: --event session_start
    SH->>TMP: counter = 0 (초기화)
    SH->>AWS: sts get-caller-identity
    AWS-->>SH: IAM User ARN
    SH->>AWS: logs start-query (토큰 사용량)
    loop 최대 5회, 3초 간격
        SH->>AWS: logs get-query-results
        AWS-->>SH: 쿼리 상태
    end
    AWS-->>SH: 모델별 토큰 수
    SH->>SH: 비용 계산 (토큰 × 모델별 단가)
    SH->>TMP: cache.json 저장
    alt 비용 >= 임계값
        SH-->>CC: exit 2 (BLOCKED)
        CC-->>U: ❌ 사용 차단
    else 비용 < 임계값
        SH-->>CC: exit 0 (허용)
        CC-->>U: ✅ 정상 사용
    end

    Note over CC: UserPromptSubmit (매 프롬프트)
    U->>CC: 프롬프트 입력
    CC->>SH: --event prompt_submit
    SH->>TMP: counter 읽기 & 증가
    alt counter < check_interval (기본 10)
        SH->>TMP: counter 저장
        SH-->>CC: exit 0 (스킵, 비용 확인 안 함)
    else counter >= check_interval
        SH->>TMP: counter = 0 (리셋)
        SH->>TMP: cache 확인 (5분 이내?)
        alt 캐시 유효
            TMP-->>SH: 캐시된 비용
        else 캐시 만료
            SH->>AWS: CloudWatch 쿼리 실행
            AWS-->>SH: 토큰 사용량
            SH->>SH: 비용 계산
            SH->>TMP: cache.json 갱신
        end
        alt 비용 >= 임계값
            SH-->>CC: exit 2 (BLOCKED)
        else 비용 < 임계값
            SH-->>CC: exit 0 (허용)
        end
    end
```

## 사전 요구사항

- **Bedrock Model Invocation Logging** 활성화 (CloudWatch Logs로 출력)
  - 로그 그룹명: `bedrock/model-invocations` (기본값)
  - `aws/` 접두사는 AWS 예약어이므로 사용 불가
  - IAM Role 필요: Bedrock → CloudWatch Logs 쓰기 권한
- **AWS CLI v2** 설치 및 설정 (필요 권한: `logs:StartQuery`, `logs:GetQueryResults`, `sts:GetCallerIdentity`)
- **jq**, **bc** 설치

## 설치

### 1. 마켓플레이스 등록 및 플러그인 설치

```bash
claude plugin marketplace add /path/to/local-marketplace
claude plugin install cost-guardrail@local-plugins
claude plugin list  # 설치 확인
```

### 2. 차단 훅 등록 (필수)

> **중요:** 플러그인의 `hooks.json`만으로는 차단이 동작하지 않습니다.
> 실제 차단을 위해서는 `~/.claude/settings.json`에 훅을 직접 등록해야 합니다.

설치된 플러그인 경로를 확인합니다:

```bash
PLUGIN_PATH="$HOME/.claude/plugins/cache/local-plugins/cost-guardrail/1.0.0"
ls "$PLUGIN_PATH/hooks/check-cost.sh"  # 파일 존재 확인
```

`~/.claude/settings.json`에 hooks 섹션을 추가합니다:

```jsonc
{
  // ... 기존 설정 유지 ...
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/plugins/cache/local-plugins/cost-guardrail/1.0.0/hooks/check-cost.sh --event session_start",
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
            "command": "bash $HOME/.claude/plugins/cache/local-plugins/cost-guardrail/1.0.0/hooks/check-cost.sh --event prompt_submit",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

또는 `jq`로 한 번에 추가:

```bash
PLUGIN_PATH="$HOME/.claude/plugins/cache/local-plugins/cost-guardrail/1.0.0"

jq --arg ss "bash $PLUGIN_PATH/hooks/check-cost.sh --event session_start" \
   --arg ps "bash $PLUGIN_PATH/hooks/check-cost.sh --event prompt_submit" \
   '.hooks = {
     "SessionStart": [{"hooks": [{"type": "command", "command": $ss, "timeout": 60}]}],
     "UserPromptSubmit": [{"hooks": [{"type": "command", "command": $ps, "timeout": 30}]}]
   }' ~/.claude/settings.json > /tmp/settings.json && cp /tmp/settings.json ~/.claude/settings.json
```

### 3. 설치 전 검증 (선택)

```bash
claude plugin validate /path/to/cost-guardrail
```

## 설정 (config.json)

설치된 경로: `~/.claude/plugins/cache/local-plugins/cost-guardrail/1.0.0/config.json`

| 필드 | 기본값 | 설명 |
|------|--------|------|
| `threshold_usd` | 50 | 차단 임계값 (USD) |
| `period` | "monthly" | 비용 집계 기간 ("monthly" 또는 "daily") |
| `check_interval` | 10 | 매 N번째 프롬프트마다 비용 확인 |
| `timezone` | "UTC" | 일간 기간 경계 시간대 |
| `log_group` | "bedrock/model-invocations" | CloudWatch Logs 그룹명 |
| `pricing` | (모델별) | 모델별 토큰 단가 (input/output per 1K tokens) |
| `default_input_per_1k` | 0.003 | pricing에 없는 모델의 기본 입력 단가 |
| `default_output_per_1k` | 0.015 | pricing에 없는 모델의 기본 출력 단가 |

## 사용법

### 현재 비용 확인
```
/cost-guardrail:cost-status
```

![cost-status 실행 예시](img/cost-status.png)

### 설정 조회/변경
```
/cost-guardrail:cost-config show
/cost-guardrail:cost-config set threshold_usd 100
/cost-guardrail:cost-config set check_interval 5
```

![cost-config 실행 예시](img/cost-config.png)

## 동작 방식

1. **SessionStart** — 세션 시작 시 항상 비용 확인 (캐시 바이패스)
2. **UserPromptSubmit** — 매 N번째 프롬프트마다 비용 확인 (API 호출 최소화)
3. CloudWatch Logs Insights로 현재 IAM 사용자의 Bedrock 토큰 사용량 조회
4. 토큰 수 (input + cache read + cache write + output) × 모델별 단가로 비용 계산
5. 비용 >= 임계값 → exit 2 (hard block), 비용 < 임계값 → exit 0 (허용)

![임계값 초과 시 차단 화면](img/block_claude.png)

### 플러그인 훅 vs settings.json 훅

| 구분 | 플러그인 hooks.json | settings.json hooks |
|------|-------------------|-------------------|
| 차단 (non-zero exit) | 동작 안 함 (알림 전용) | **동작함** |
| 커맨드/스킬 제공 | /cost-status, /cost-config | 해당 없음 |
| 설치 방식 | `claude plugin install`로 자동 | 수동 등록 필요 |

**두 가지를 함께 사용해야 합니다:**
- 플러그인: 커맨드(`/cost-status`, `/cost-config`)와 스킬(cost-awareness) 제공
- settings.json 훅: 실제 비용 초과 시 차단 실행

## 에러 처리 (Fail-Open)

모든 에러 상황에서 **사용을 허용**합니다 (fail-open). 인프라 문제로 개발자가 차단되는 것을 방지합니다.

| 상황 | 동작 |
|------|------|
| AWS 자격 증명 실패 | exit 0 (허용) |
| CloudWatch 쿼리 타임아웃 | 캐시 사용, 캐시 없으면 exit 0 |
| config.json 누락/오류 | exit 0 (허용) |
| 미등록 모델 | 기본 단가 적용 |
| threshold_usd = 0 | exit 0 (허용) |

## Bedrock 로깅 설정 방법

### IAM Role 생성

```bash
aws iam create-role \
  --role-name BedrockLoggingRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "bedrock.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

aws iam put-role-policy \
  --role-name BedrockLoggingRole \
  --policy-name BedrockCloudWatchLogsPolicy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:*:ACCOUNT_ID:log-group:bedrock/model-invocations:*"
    }]
  }'
```

### CloudWatch Logs 그룹 생성 및 로깅 활성화

```bash
aws logs create-log-group --log-group-name "bedrock/model-invocations"

aws bedrock put-model-invocation-logging-configuration \
  --logging-config '{
    "cloudWatchConfig": {
      "logGroupName": "bedrock/model-invocations",
      "roleArn": "arn:aws:iam::ACCOUNT_ID:role/BedrockLoggingRole"
    },
    "textDataDeliveryEnabled": true,
    "imageDataDeliveryEnabled": false,
    "embeddingDataDeliveryEnabled": false
  }'
```

## 트러블슈팅

- **비용이 항상 $0으로 표시**: Bedrock Model Invocation Logging이 활성화되어 있는지 확인. `aws bedrock get-model-invocation-logging-configuration`으로 확인.
- **IAM identity 실패**: `aws sts get-caller-identity`가 정상 동작하는지 확인.
- **캐시된 오래된 데이터**: `/tmp/claude-cost-guardrail-*-cache.json` 삭제 후 재시도.
- **차단이 안 됨**:
  1. `settings.json`에 훅이 등록되어 있는지 확인 (`jq '.hooks' ~/.claude/settings.json`)
  2. 플러그인 `hooks.json`만으로는 차단이 안 됨 — `settings.json` 훅 필수
  3. `check_interval` 값 확인. 값이 10이면 10번째 프롬프트마다만 확인.
- **로그 그룹 생성 시 `aws/` 접두사 오류**: `aws/`는 AWS 예약어. `bedrock/model-invocations` 사용.

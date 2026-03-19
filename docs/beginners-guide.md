# 초보자 가이드

이 문서는 Cost Guardrail 플러그인을 이해하는 데 필요한 배경 지식을 설명합니다.

## 용어 설명

### AWS 관련

| 용어 | 설명 |
|------|------|
| **IAM User** | AWS 계정 내 개별 사용자. 각 사용자는 고유한 ARN(Amazon Resource Name)을 가지며, 이 플러그인은 IAM User 단위로 비용을 추적합니다. |
| **ARN** | `arn:aws:iam::123456789012:user/john` 형태의 AWS 리소스 고유 식별자. 이 플러그인은 ARN으로 "누가 얼마나 썼는지"를 구분합니다. |
| **Amazon Bedrock** | AWS의 관리형 AI 모델 서비스. Claude, Llama 등의 모델을 API로 호출할 수 있습니다. 호출할 때마다 토큰 기반으로 비용이 발생합니다. |
| **Model Invocation Logging** | Bedrock API 호출 기록을 CloudWatch Logs에 자동으로 저장하는 기능. 이 로그에 누가, 어떤 모델로, 몇 토큰을 사용했는지 기록됩니다. |
| **CloudWatch Logs Insights** | CloudWatch Logs에 저장된 로그를 SQL과 유사한 문법으로 조회하는 서비스. 이 플러그인은 이를 통해 사용자별 토큰 사용량을 집계합니다. |
| **STS (Security Token Service)** | 현재 AWS 자격 증명의 IAM User ARN을 확인하는 데 사용됩니다 (`sts:GetCallerIdentity`). |

### 토큰과 비용

| 용어 | 설명 |
|------|------|
| **토큰 (Token)** | AI 모델이 텍스트를 처리하는 기본 단위. 영어 기준 약 4글자 = 1토큰, 한국어는 1~2글자 = 1토큰 정도입니다. |
| **Input Token** | 사용자가 모델에 보내는 프롬프트의 토큰 수. |
| **Output Token** | 모델이 생성하는 응답의 토큰 수. 일반적으로 input보다 단가가 높습니다. |
| **Cache Read Token** | 이전 대화에서 캐시된 컨텍스트를 재사용할 때 발생하는 토큰. 일반 input 대비 약 1/10 가격으로 매우 저렴합니다. |
| **Cache Write Token** | 컨텍스트를 캐시에 처음 저장할 때 발생하는 토큰. Input보다 약간 비쌉니다. |
| **1K 토큰당 단가** | 이 플러그인의 가격 단위. 예: `input_per_1k: 0.015` → 입력 1,000토큰당 $0.015. |

### 플러그인 관련

| 용어 | 설명 |
|------|------|
| **Hook** | Claude Code의 특정 이벤트(세션 시작, 프롬프트 입력 등)에 자동으로 실행되는 스크립트. 이 플러그인의 핵심 메커니즘입니다. |
| **SessionStart** | Claude Code 세션이 시작될 때 발생하는 이벤트. 이 시점에서 항상 비용을 확인합니다. |
| **UserPromptSubmit** | 사용자가 프롬프트를 입력할 때마다 발생하는 이벤트. 매번 확인하면 느려지므로 N번째마다만 확인합니다 (기본 10). |
| **Hard Block** | 훅 스크립트가 `exit 2`를 반환하면 Claude Code가 해당 프롬프트 실행을 거부합니다. |
| **Fail-Open** | 오류 발생 시 "차단"이 아닌 "허용"으로 처리하는 정책. AWS 연결 실패 등 인프라 문제로 개발자가 일을 못 하는 상황을 방지합니다. 반대 개념은 Fail-Close(오류 시 차단)입니다. |
| **settings.json 훅** | `~/.claude/settings.json`에 등록하는 훅. 플러그인 `hooks.json`의 훅과 달리, non-zero exit code로 실제 차단이 가능합니다. |
| **check_interval** | 비용 확인 빈도. 값이 10이면 10번째 프롬프트마다 확인합니다. 값을 낮추면 더 자주 확인하지만 AWS API 호출이 증가합니다. |
| **Cache (비용 캐시)** | CloudWatch 쿼리 결과를 `/tmp/` 파일에 5분간 저장합니다. 같은 시간 내 반복 확인 시 AWS API 호출 없이 캐시된 값을 사용합니다. |

## 비용은 어떻게 계산되나요?

```
비용 = (input 토큰 / 1000 × input 단가)
     + (cache read 토큰 / 1000 × cache read 단가)
     + (cache write 토큰 / 1000 × cache write 단가)
     + (output 토큰 / 1000 × output 단가)
```

예시: Claude Opus 4.6으로 input 10,000 토큰, output 2,000 토큰을 사용한 경우

```
input:  10,000 / 1,000 × $0.015  = $0.15
output:  2,000 / 1,000 × $0.075  = $0.15
합계: $0.30
```

## 왜 두 가지 훅 설정이 필요한가요?

Claude Code 플러그인 시스템의 제약 때문입니다:

| | 플러그인 hooks.json | settings.json hooks |
|---|---|---|
| 차단 가능 여부 | 불가 (알림만 가능) | **가능** (exit 2 → hard block) |
| 커맨드/스킬 제공 | /cost-status, /cost-config 제공 | 해당 없음 |
| 설치 방식 | `claude plugin install`로 자동 | 수동 등록 필요 |

따라서:
- **플러그인** → 커맨드(`/cost-status`, `/cost-config`)와 스킬(cost-awareness) 제공
- **settings.json** → 실제 차단 실행

## 자주 묻는 질문

**Q: 비용이 항상 $0으로 나옵니다.**
A: Bedrock Model Invocation Logging이 활성화되어 있는지 확인하세요:
```bash
aws bedrock get-model-invocation-logging-configuration
```

**Q: check_interval을 1로 설정하면 어떻게 되나요?**
A: 매 프롬프트마다 CloudWatch를 조회합니다. 비용 확인은 정확해지지만, 각 프롬프트 처리 전 최대 15초(쿼리 폴링 시간) 대기가 발생할 수 있습니다. 캐시(5분 TTL)가 있어 실제로는 5분에 한 번만 AWS API를 호출합니다.

**Q: 여러 사용자가 같은 EC2에서 Claude Code를 사용하면?**
A: `/tmp/` 파일이 `$USER` 환경변수로 구분되므로 각자 독립적으로 추적됩니다.

**Q: Fail-open이면 비용 초과를 놓칠 수 있지 않나요?**
A: 네, 일시적으로 가능합니다. 하지만 AWS 장애 때 모든 개발자가 차단되는 것보다, 일시적 초과 후 다음 확인에서 차단하는 것이 더 나은 정책이라는 설계 판단입니다.

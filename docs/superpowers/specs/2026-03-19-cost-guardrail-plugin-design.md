# Cost Guardrail Plugin — Design Spec

## Overview

Claude Code plugin that monitors per-IAM-user Bedrock API costs via CloudWatch Logs Insights and hard-blocks usage when a spending threshold is reached. Built with the same markdown/JSON/shell architecture as the existing translate-toolkit plugin.

## Decisions

| Decision | Choice |
|----------|--------|
| Cost data source | Bedrock Model Invocation Logging → CloudWatch Logs Insights |
| Check timing | SessionStart (always) + every Nth UserPromptSubmit |
| Tracking unit | Per IAM User (filtered by user ARN) |
| Threshold config | Local `config.json` only |
| Blocking mechanism | Hard block (non-zero exit code from hook) |
| Error policy | **Fail-open** — if AWS calls fail, allow usage (never lock out a developer due to infra issues) |

## Prerequisites

- **Bedrock Model Invocation Logging** enabled (outputs to CloudWatch Logs)
- **AWS CLI** configured with permissions: `logs:StartQuery`, `logs:GetQueryResults`, `sts:GetCallerIdentity`
- **jq** and **bc** installed for JSON parsing and arithmetic in shell scripts

## plugin.json

```json
{
  "name": "cost-guardrail",
  "version": "1.0.0",
  "description": "Per-user Bedrock cost monitoring with automatic usage blocking when spending threshold is reached",
  "author": {
    "name": "cost-guardrail-team"
  }
}
```

## Plugin Structure

Following the translate-toolkit pattern, files exist at the plugin root level for loader discovery. `CLAUDE_PLUGIN_ROOT` resolves to the plugin root directory (where `.claude-plugin/` lives).

```
cost-guardrail/
├── .claude-plugin/
│   └── plugin.json                    # Plugin metadata (required)
├── commands/
│   ├── cost-status.md                 # /cost-status — check current spend
│   └── cost-config.md                 # /cost-config — view/modify threshold
├── skills/
│   └── cost-awareness/
│       └── SKILL.md                   # Auto-referenced cost context for AI
├── hooks/
│   ├── hooks.json                     # SessionStart + UserPromptSubmit hooks
│   └── check-cost.sh                  # Main cost check + block logic
├── config.json                        # Threshold and pricing config (plugin root)
└── README.md                          # Installation and setup guide
```

No `agents/` directory — this plugin operates via hooks and commands only.

## config.json

Located at the plugin root (`${CLAUDE_PLUGIN_ROOT}/config.json`).

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

- `threshold_usd` — USD amount that triggers hard block
- `period` — `"monthly"` or `"daily"`, defines the cost accumulation window
- `check_interval` — check cost every Nth prompt (reduces API calls)
- `log_group` — CloudWatch Logs group where Bedrock invocation logs are stored
- `timezone` — timezone for daily period boundary calculation (default: `"UTC"`)
- `default_input_per_1k` / `default_output_per_1k` — fallback pricing for models not listed in `pricing`
- `pricing` — per-model token pricing (input/output per 1K tokens), manually maintained from Bedrock pricing page. Models not listed here use the default pricing.

## hooks.json

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

- `SessionStart` timeout: 60s (first query may be slower, latency is tolerable at session start)
- `UserPromptSubmit` timeout: 30s (only runs every Nth prompt)

## check-cost.sh Logic

### Arguments

- `--event session_start` — always run full cost check
- `--event prompt_submit` — counter-based, only check every Nth prompt
- `--event report` — always run full cost check, never exit non-zero (used by /cost-status)

### Flow

```
1. Parse --event argument
2. Load config from ${CLAUDE_PLUGIN_ROOT}/config.json
3. If prompt_submit:
   a. Read counter from /tmp/claude-cost-guardrail-${USER}-counter
   b. Increment counter
   c. If counter < check_interval → write counter, exit 0 (skip)
   d. If counter >= check_interval → reset to 0, continue
4. If session_start: reset counter to 0
5. Get current IAM user ARN:
   - aws sts get-caller-identity --query Arn --output text
   - On failure → exit 0 (fail-open)
6. Check local cache (/tmp/claude-cost-guardrail-${USER}-cache.json):
   - If cache exists and is less than 5 minutes old → use cached cost
   - Otherwise → query CloudWatch (steps 7-8)
7. Calculate time range:
   - monthly → first day of current month (UTC or configured timezone) to now
   - daily → start of current day to now
8. Execute CloudWatch Logs Insights query:
   - aws logs start-query → get queryId
   - Poll aws logs get-query-results (max 5 attempts, 3s intervals)
   - On timeout or error → use cached value if available, else exit 0 (fail-open)
9. Calculate cost:
   - For each model: (input_tokens / 1000 * input_price) + (output_tokens / 1000 * output_price)
   - Models not in pricing config → use default_input_per_1k / default_output_per_1k
   - Write result to cache file
10. Compare:
    - If --event report → print status, always exit 0
    - cost >= threshold → print block message to stderr, exit 2
    - cost < threshold → exit 0
```

### CloudWatch Logs Insights Query

```
filter identity.arn = "USER_ARN"
| stats sum(input.inputTokenCount) as totalInput,
        sum(output.outputTokenCount) as totalOutput
  by modelId
```

Note: Field paths (`identity.arn`, `input.inputTokenCount`, `output.outputTokenCount`, `modelId`) must be verified against actual Bedrock invocation log entries during implementation. The Bedrock invocation log schema may vary by region or API version.

### Counter File

- Path: `/tmp/claude-cost-guardrail-${USER}-counter`
- Content: single integer
- Namespaced by OS `$USER` to avoid conflicts between concurrent users on shared machines

### Cache File

- Path: `/tmp/claude-cost-guardrail-${USER}-cache.json`
- Content: `{"cost_usd": 32.50, "timestamp": 1742000000, "details": {...}}`
- Used as fallback when CloudWatch query times out or fails
- Expires after 5 minutes (configurable in future)

## Commands

### /cost-status (cost-status.md)

```yaml
---
name: cost-status
description: Check current Bedrock cost for the active IAM user
---
```

Instructions for the AI:
1. Run `bash ${CLAUDE_PLUGIN_ROOT}/hooks/check-cost.sh --event report`
2. Parse the output and present to the user in a formatted table:

```
User: arn:aws:iam::123456789012:user/john
Period: 2026-03 (monthly)
Estimated cost: $32.50 / $50.00 (65%)
Status: ✅ Active
```

### /cost-config (cost-config.md)

```yaml
---
name: cost-config
description: View or modify cost guardrail settings
---
```

Instructions for the AI:
1. Read `${CLAUDE_PLUGIN_ROOT}/config.json`
2. Subcommands:
   - `show` — display all current settings in a table
   - `set <key> <value>` — update the specified key in config.json and write back the complete file
3. Only allow modification of: `threshold_usd`, `check_interval`, `period`, `timezone`
4. Do not allow modification of `pricing` or `log_group` via this command (direct file edit required)

## cost-awareness SKILL.md

```yaml
---
name: cost-awareness
description: Context about active cost guardrail for AI responses
autoContext:
  - always: true
---
```

Content:
- This project has a cost guardrail plugin that monitors Bedrock API spending per IAM user
- If a user asks about costs or budget, direct them to `/cost-status`
- If a user wants to change their spending limit, direct them to `/cost-config set threshold_usd <amount>`
- Be mindful of cost efficiency: prefer concise responses, avoid unnecessary tool calls when possible

## Error Handling Summary

| Scenario | Behavior |
|----------|----------|
| AWS credentials expired/missing | Fail-open: exit 0, allow usage |
| CloudWatch query timeout | Use cached value if <5min old, else fail-open |
| config.json missing or malformed | Fail-open: exit 0 with warning to stderr |
| Model not in pricing table | Use `default_input_per_1k` / `default_output_per_1k` |
| Counter file unreadable | Reset counter to 0, proceed with check |
| Multiple concurrent sessions | Counter namespaced by $USER; minor race is acceptable |

## Future Extensions (not in scope now)

- **2-stage threshold**: 80% warning + 90% hard block
- **SNS notifications**: alert admins when users approach limits
- **Parameter Store integration**: centralized threshold management
- **Per-model budgets**: separate limits for different Bedrock models
- **Cost history command**: `/cost-history` showing daily/weekly trends

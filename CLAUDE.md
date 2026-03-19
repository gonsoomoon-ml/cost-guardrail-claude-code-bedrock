# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Code plugin that monitors per-IAM-user Amazon Bedrock API costs via CloudWatch Logs Insights and hard-blocks usage when a spending threshold is reached. Built entirely with Markdown, JSON, and Bash (no programming language code).

## Plugin Structure

```
.claude-plugin/plugin.json    # Plugin metadata (name, version, author)
commands/
  cost-status.md              # /cost-status — check current spend
  cost-config.md              # /cost-config — view/modify threshold
skills/
  cost-awareness/SKILL.md     # Auto-injected cost context for AI
hooks/
  hooks.json                  # SessionStart + UserPromptSubmit hooks
  check-cost.sh               # Core: CW Logs Insights query + cost calc + blocking
config.json                   # Threshold, pricing, settings
```

## Key Design Decisions

- **Fail-open**: All errors → exit 0 (allow usage). Never block a developer due to infra issues. No `set -euo pipefail` in check-cost.sh.
- **Plugin hooks vs settings.json hooks**: Plugin `hooks.json` non-zero exit codes do NOT block sessions/prompts. Actual blocking requires `~/.claude/settings.json` hooks. Both are needed: plugin for commands/skills, settings.json for enforcement.
- **4-type token pricing**: Input, cache_read, cache_write, output each have separate per-model pricing. Cache read is ~10x cheaper than input.
- **ARN model ID extraction**: Bedrock logs `modelId` as inference profile ARN (`arn:aws:bedrock:.../us.anthropic.claude-opus-4-6-v1`). Script extracts model ID and strips `us.` prefix for config.json pricing lookup.
- **Counter-based throttling**: `UserPromptSubmit` only queries CloudWatch every Nth prompt (default 10). Counter stored in `/tmp/claude-cost-guardrail-${USER}-counter`.
- **Log group naming**: `aws/` prefix is reserved by AWS. Use `bedrock/model-invocations`.

## Testing

```bash
# Syntax check
bash -n hooks/check-cost.sh

# Report mode (queries AWS, never blocks)
bash hooks/check-cost.sh --event report

# Validate JSON
find . -name "*.json" -not -path "./.git/*" -exec jq . {} \;

# Validate plugin
claude plugin validate .
```

## config.json Pricing Format

```json
{
  "pricing": {
    "anthropic.claude-opus-4-6-v1": {
      "input_per_1k": 0.015,
      "output_per_1k": 0.075,
      "cache_read_per_1k": 0.0015,
      "cache_write_per_1k": 0.01875
    }
  }
}
```

Models not in pricing table use `default_*_per_1k` values. Pricing is manually maintained from Bedrock pricing page.

## Prerequisites

- Bedrock Model Invocation Logging enabled → CloudWatch Logs
- AWS CLI v2 with permissions: `logs:StartQuery`, `logs:GetQueryResults`, `sts:GetCallerIdentity`
- jq, bc installed

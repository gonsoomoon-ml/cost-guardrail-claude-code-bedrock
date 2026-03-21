# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Code plugin that monitors per-IAM-user Amazon Bedrock API costs via CloudWatch Logs Insights and hard-blocks usage when a spending threshold is reached. Built entirely with Markdown, JSON, and Bash (no programming language code).

## Plugin Structure

```
.claude-plugin/plugin.json    # Plugin metadata (name: bedrock-cost-guardrail, version, author)
commands/
  cost-status.md              # /bedrock-cost-guardrail:cost-status — check current spend
  cost-config.md              # /bedrock-cost-guardrail:cost-config — view/modify settings
skills/
  cost-awareness/SKILL.md     # Auto-injected cost context for AI
hooks/
  hooks.json                  # SessionStart + UserPromptSubmit hooks
  check-cost.sh               # Main: event handling, config merge, flow control
  lib-cost.sh                 # Library: cost calc, CW query, daily state, cache
config.json                   # Shared base: pricing, log_group, defaults

# Admin-only (not distributed to employees)
admin/
  config.admin.json           # Admin policy overrides (threshold, period, interval, timezone)
  config.dist.json            # Employee defaults (used by release.sh to build dist config)
scripts/
  release.sh                  # Publish to marketplace repo
  preflight.sh                # Prerequisite checker (bash, jq, awk, aws, log group)
docs/
```

## Config Architecture

Three config files, merged at runtime via `jq -s '.[0] * .[1]'`:

- **`config.json`** (shared base): pricing, log_group, default_*_per_1k — maintained once, used by everyone
- **`admin/config.admin.json`** (admin policy): threshold_usd, period, check_interval, timezone, progressive
- **`admin/config.dist.json`** (employee defaults): same fields, different values — merged with base during release

check-cost.sh merges base + admin at runtime. release.sh merges base + dist to produce the marketplace config.

## Key Design Decisions

- **Fail-closed**: All errors → exit 2 (block usage). Prevents unmonitored spending. No `set -euo pipefail` in check-cost.sh (error handling is explicit per command).
- **Plugin hooks vs settings.json hooks**: Plugin `hooks.json` non-zero exit codes do NOT block sessions/prompts. Actual blocking requires `~/.claude/settings.json` hooks. Both are needed: plugin for commands/skills, settings.json for enforcement.
- **4-type token pricing**: Input, cache_read, cache_write, output each have separate per-model pricing. Cache read is ~10x cheaper than input.
- **ARN model ID extraction**: Bedrock logs `modelId` as inference profile ARN (`arn:aws:bedrock:.../us.anthropic.claude-opus-4-6-v1`). Script extracts model ID and strips `us.` prefix for config.json pricing lookup.
- **Daily accumulation** (monthly period): Only queries today's logs, caches previous days' totals in a daily state file. Reduces CloudWatch scan cost ~31x. Weekly full-month reconciliation corrects drift.
- **Progressive checking**: Adaptive check intervals based on cost proximity to threshold. Low spend (<50%) → every 50 prompts; mid (50-80%) → every 20; high (>80%) → every 5.
- **Cross-platform**: Uses `awk` instead of `bc` for arithmetic, math-based epoch calculation instead of `date -d`. Works on macOS, Linux, and Windows Git Bash/WSL.
- **Log group naming**: `aws/` prefix is reserved by AWS. Use `bedrock/model-invocations`.
- **Admin-only threshold**: `threshold_usd` is not user-modifiable via `/cost-config set`. Users can change `check_interval`, `period`, `timezone` only. Pricing and `log_group` require direct file edit.

## Exit Code Semantics (check-cost.sh)

- `exit 0` — allow usage (only when cost is verified below threshold, or counter skip)
- `exit 2` — hard block (only when cost >= threshold, never in `report` mode)
- Blocking only works from `~/.claude/settings.json` hooks, not from plugin `hooks.json`

## Runtime State

- Counter: `/tmp/claude-cost-guardrail-${USER}-counter` (integer, resets each session)
- Cache: `/tmp/claude-cost-guardrail-${USER}-cache.json` (cost + timestamp, 5-min TTL)
- Daily state: `/tmp/claude-cost-guardrail-${USER}-daily.json` (monthly accumulation: finalized days + previous_total + reconciliation timestamp)
- Merged config: `/tmp/claude-cost-guardrail-${USER}-merged.json` (base + admin, regenerated each run)
- Cache bypass: `session_start` and `report` events always query CloudWatch fresh. Only `prompt_submit` uses cache.
- `CLAUDE_PLUGIN_ROOT` env var — set by Claude Code plugin loader, resolves to repo root (where `.claude-plugin/` lives). Used in hooks.json commands and command .md files.

## Testing

```bash
# Syntax check
bash -n hooks/check-cost.sh
bash -n hooks/lib-cost.sh

# Report mode (queries AWS, never blocks)
bash hooks/check-cost.sh --event report

# Validate JSON
find . -name "*.json" -not -path "./.git/*" -exec jq . {} \;

# Prerequisite check
bash scripts/preflight.sh

# Validate plugin
claude plugin validate .
```

## CloudWatch Query Details

- Filters by `identity.arn` and aggregates by `modelId`
- Token fields: `input.inputTokenCount`, `input.cacheReadInputTokenCount`, `input.cacheWriteInputTokenCount`, `output.outputTokenCount`
- Results parsed by field name (not positional index) for robustness against schema changes
- Model ID lookup chain: exact match in `pricing` → strip `us.` prefix and retry → fall back to `default_*_per_1k`
- Query polls with progressive backoff (2,2,3,3,3,3,3,3,3 = 25s max); on timeout falls back to cache, then fail-closed (block)
- Daily accumulation: normal queries scan only today's logs; weekly reconciliation scans full month

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
- jq, awk installed (bc is NOT required)
- Run `bash scripts/preflight.sh` to verify all prerequisites

## Notes

- README.md is written in Korean. Keep it in Korean when editing.
- Design spec lives at `docs/superpowers/specs/2026-03-19-cost-guardrail-plugin-design.md` — consult for architectural rationale.

## Repositories

- Source: https://github.com/gonsoomoon-ml/cost-guardrail-claude-code-bedrock
- Marketplace: https://github.com/gonsoomoon-ml/bedrock-cost-guardrail

## Release Workflow

To publish a new version to the marketplace repo:

    bash scripts/release.sh /path/to/bedrock-cost-guardrail
    cd /path/to/bedrock-cost-guardrail && git add -A && git commit -m "Release vX.Y.Z" && git push

The release script merges `config.json` + `admin/config.dist.json` to produce the distribution config ($180 employee threshold).

## Simulation (Blocking Test)

End-to-end test to verify the full lifecycle: allow → use → threshold reached → block.

### 1. Set a low threshold (below current cost)

```bash
# Check current cost first
bash hooks/check-cost.sh --event report 2>&1

# Set threshold below current cost (e.g., $100 if cost is ~$200)
vi admin/config.dist.json   # set threshold_usd to 100

# Release to dist repo
bash scripts/release.sh /path/to/bedrock-cost-guardrail
cd /path/to/bedrock-cost-guardrail && git add -A && git commit -m "Test: lower threshold" && git push
```

### 2. Employee side — install and test

```bash
# Pull latest and clean state
cd ~/.claude/plugins/bedrock-cost-guardrail
git pull
sudo rm -f /tmp/claude-cost-guardrail-*

# Verify blocking in shell (should all Exit: 2)
export AWS_REGION=<your-region>
bash plugins/bedrock-cost-guardrail/hooks/check-cost.sh --event report 2>&1
for i in 1 2 3; do
  echo "=== Prompt $i ==="
  bash plugins/bedrock-cost-guardrail/hooks/check-cost.sh --event prompt_submit 2>&1
  echo "Exit: $?"
done

# Test in Claude Code (should block immediately)
claude
# Type any prompt → should see "BLOCKED" + "Contact your admin"
```

### 3. Restore threshold

```bash
# Set threshold back to $180
vi admin/config.dist.json   # set threshold_usd to 180
bash scripts/release.sh /path/to/bedrock-cost-guardrail
cd /path/to/bedrock-cost-guardrail && git add -A && git commit -m "Restore threshold" && git push
```

### 4. Employee side — verify unblocked

```bash
cd ~/.claude/plugins/bedrock-cost-guardrail && git pull
sudo rm -f /tmp/claude-cost-guardrail-*
claude
# Type any prompt → should work normally
```

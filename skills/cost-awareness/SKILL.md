---
name: cost-awareness
description: Context about active cost guardrail for AI responses
autoContext:
  - always: true
---

# Cost Guardrail — Active

This project has a cost guardrail plugin that monitors Amazon Bedrock API spending per IAM user.

## What It Does

- Checks estimated Bedrock cost at session start and periodically during use
- Blocks usage (hard block) when the configured spending threshold is reached
- Tracks costs per IAM user using CloudWatch Logs Insights

## User Commands

- `/cost-status` — Check current estimated cost, threshold, and status
- `/cost-config show` — View current settings
- `/cost-config set threshold_usd <amount>` — Change spending limit

## Cost Efficiency

When this plugin is active, be mindful of cost:
- Prefer concise, focused responses
- Avoid unnecessary tool calls when a direct answer suffices
- If the user asks about costs or budget, direct them to `/cost-status`

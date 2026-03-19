---
name: cost-config
description: View or modify cost guardrail settings
---

# /cost-config — Guardrail Configuration

View or modify the cost guardrail plugin settings.

## Usage

```
/cost-config show
/cost-config set <key> <value>
```

## Instructions

### show
1. Read `${CLAUDE_PLUGIN_ROOT}/config.json`
2. Display all settings in a formatted table:
   - threshold_usd, period, check_interval, timezone
   - List all models in the pricing table with their rates

### set
1. Read `${CLAUDE_PLUGIN_ROOT}/config.json`
2. Only allow modification of these keys:
   - `threshold_usd` (number) — spending limit in USD
   - `check_interval` (integer) — check every Nth prompt
   - `period` ("monthly" or "daily") — cost accumulation window
   - `timezone` (string) — timezone for daily period boundary
3. Validate the value type before writing
4. Write back the complete updated JSON file (preserve all other fields)
5. Confirm the change to the user

### Restrictions
- Do NOT allow modification of `pricing`, `log_group`, `default_input_per_1k`, or `default_output_per_1k` via this command
- For pricing changes, instruct the user to edit config.json directly

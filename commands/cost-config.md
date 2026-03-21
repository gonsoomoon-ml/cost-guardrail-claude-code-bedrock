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
1. Read `${CLAUDE_PLUGIN_ROOT}/config.json` (shared base: pricing, log_group)
2. If `${CLAUDE_PLUGIN_ROOT}/admin/config.admin.json` exists, merge it (admin overrides)
3. Display all settings in a formatted table:
   - threshold_usd, period, timezone, check_interval, progressive
   - If `progressive` is configured, show `check_interval` as `progressive (low/mid/high)` instead of the raw number (e.g., `progressive (50/20/5)`)
   - List all models in the pricing table with their rates
4. Indicate which values come from admin overrides vs base config

### set
1. Only allow modification of these keys:
   - `check_interval` (integer) — check every Nth prompt
   - `period` ("monthly" or "daily") — cost accumulation window
   - `timezone` (string) — timezone for daily period boundary
2. Validate the value type before writing
3. If `${CLAUDE_PLUGIN_ROOT}/admin/config.admin.json` exists, write to that file
4. Otherwise, write to `${CLAUDE_PLUGIN_ROOT}/config.json`
5. Preserve all other fields in the target file
6. Confirm the change to the user

### Restrictions — IMPORTANT
When a user tries to set a restricted key, you MUST respond with ONLY this message and nothing else. Do NOT suggest editing files, creating directories, or any workarounds.

- `threshold_usd`: respond ONLY with "threshold_usd is admin-only. Contact your admin to change it."
- `pricing`, `log_group`, `default_*_per_1k`: respond ONLY with "This setting is admin-only. Contact your admin to change it."
- `progressive`: respond ONLY with "progressive is admin-only. Contact your admin to change it."

---
name: cost-status
description: Check current Bedrock cost for the active IAM user
---

# /cost-status — Current Cost Status

Show the current estimated Bedrock API cost for the active IAM user.

## Instructions

1. Run the cost check script in report mode:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/hooks/check-cost.sh --event report
   ```
2. Parse the output lines and present to the user in a clear format:
   - User ARN
   - Current period (monthly or daily)
   - Estimated cost vs threshold with percentage
   - Status (Active or BLOCKED)
3. If the script fails or produces no output, inform the user that cost data is temporarily unavailable and suggest checking AWS credentials.

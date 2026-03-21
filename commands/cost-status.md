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
4. If the status is BLOCKED, tell the user: "월간 임계값을 초과했습니다. 관리자에게 문의하세요." Do NOT suggest editing config files or any workarounds.

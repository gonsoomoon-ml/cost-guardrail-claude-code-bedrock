#!/usr/bin/env bash
# ============================================================================
# uninstall.sh — Amazon Bedrock Cost Guardrail Plugin uninstaller
#
# Reverses everything install.sh did:
#   1. Remove cost-guardrail hooks from ~/.claude/settings.json
#   2. Remove plugin directory (~/.claude/plugins/...)
#   3. Clean up temp files
#   4. Remove the cloned repo (where this script lives)
#
# Usage:
#   bash uninstall.sh
# ============================================================================
set -euo pipefail

INSTALL_DIR="$HOME/.claude/plugins/bedrock-cost-guardrail"
SETTINGS_FILE="$HOME/.claude/settings.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[uninstall] $1"; }

# --- Step 1: Remove hooks from settings.json ---
if [[ -f "$SETTINGS_FILE" ]]; then
  if grep -q "check-cost.sh" "$SETTINGS_FILE" 2>/dev/null; then
    log "Removing cost-guardrail hooks from settings.json..."
    TEMP_FILE="$(mktemp)"
    jq \
      --arg marker "check-cost.sh" \
      '
      .hooks.SessionStart = [(.hooks.SessionStart // [])[] | select(.hooks[0].command | contains($marker) | not)]
      | .hooks.UserPromptSubmit = [(.hooks.UserPromptSubmit // [])[] | select(.hooks[0].command | contains($marker) | not)]
      | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
      | if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end
      | if (.hooks | length) == 0 then del(.hooks) else . end
      ' \
      "$SETTINGS_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$SETTINGS_FILE"
    echo "  [DONE] hooks removed"
  else
    log "No cost-guardrail hooks found in settings.json."
  fi
else
  log "settings.json not found — skipping."
fi

# --- Step 2: Remove plugin directory ---
if [[ -d "$INSTALL_DIR" ]]; then
  log "Removing $INSTALL_DIR..."
  rm -rf "$INSTALL_DIR"
  echo "  [DONE] directory removed"
else
  log "Plugin directory not found — skipping."
fi

# --- Step 3: Clean up temp files ---
log "Cleaning up temp files..."
rm -f /tmp/claude-cost-guardrail-* 2>/dev/null || true
echo "  [DONE] temp files removed"

# --- Step 4: Remove cloned repo ---
# Move out of the repo directory before deleting it
cd "$HOME"
if [[ -d "$SCRIPT_DIR" && -d "$SCRIPT_DIR/.git" ]]; then
  log "Removing cloned repo: $SCRIPT_DIR..."
  rm -rf "$SCRIPT_DIR"
  echo "  [DONE] repo removed"
fi

# --- Done ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Uninstall complete."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

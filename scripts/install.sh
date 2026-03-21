#!/usr/bin/env bash
# ============================================================================
# install.sh — Amazon Bedrock Cost Guardrail Plugin installer
#
# This script handles the entire installation process:
#   1. Prerequisite checks (jq, awk, AWS CLI, credentials, log group)
#   2. Clone or update plugin
#   3. Register marketplace
#   4. Install plugin
#   5. Register blocking hooks (~/.claude/settings.json)
#   6. Verify installation
#
# Usage:
#   bash install.sh
#
# If something fails:
#   - Missing tools  → follow the install commands shown on screen
#   - AWS issues     → contact your admin
#   - Other errors   → share the full output with your admin
# ============================================================================
set -euo pipefail

REPO_URL="https://github.com/gonsoomoon-ml/bedrock-cost-guardrail.git"
INSTALL_DIR="$HOME/.claude/plugins/bedrock-cost-guardrail"
PLUGIN_PATH="$INSTALL_DIR/plugins/bedrock-cost-guardrail"
SETTINGS_FILE="$HOME/.claude/settings.json"
LOG_GROUP="bedrock/model-invocations"

log()  { echo "[install] $1"; }
warn() { echo "[install] WARNING: $1"; }

# Print error with fix instructions and exit
err() {
  echo "" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "  FAILED: $1" >&2
  if [[ -n "${2:-}" ]]; then
    echo "" >&2
    echo "  How to fix:" >&2
    echo -e "    $2" >&2
  fi
  echo "" >&2
  echo "  After fixing, run again: bash install.sh" >&2
  echo "  Still not working? Share this entire output with your admin." >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  exit 1
}

# --- Detect platform (macOS, Linux, WSL, Git Bash) ---
detect_platform() {
  case "$(uname -s)" in
    Darwin)  echo "macos" ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
      else
        echo "linux"
      fi ;;
    MINGW*|MSYS*|CYGWIN*) echo "gitbash" ;;
    *)       echo "unknown" ;;
  esac
}

OS="$(detect_platform)"

# --- Platform-specific install commands ---
install_hint() {
  local cmd="$1"
  case "$cmd" in
    jq)
      case "$OS" in
        macos)       echo "brew install jq" ;;
        linux|wsl)   echo "sudo apt install jq  or  sudo yum install jq" ;;
        gitbash)     echo "Download from https://jqlang.github.io/jq/download/" ;;
        *)           echo "Install jq: https://jqlang.github.io/jq/" ;;
      esac ;;
    awk)
      case "$OS" in
        macos)       echo "brew install gawk  (macOS built-in awk also works)" ;;
        linux|wsl)   echo "sudo apt install gawk  or  sudo yum install gawk" ;;
        gitbash)     echo "Included in Git Bash. Reinstall: https://gitforwindows.org" ;;
        *)           echo "Install gawk or mawk" ;;
      esac ;;
    aws)
      case "$OS" in
        macos)       echo "brew install awscli" ;;
        *)           echo "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" ;;
      esac ;;
    git)
      case "$OS" in
        macos)       echo "xcode-select --install  or  brew install git" ;;
        linux|wsl)   echo "sudo apt install git  or  sudo yum install git" ;;
        *)           echo "https://git-scm.com/downloads" ;;
      esac ;;
  esac
}

# ============================================================================
# Step 1: Prerequisite checks
# ============================================================================
log "Checking prerequisites... (platform: $OS)"
echo ""

FAILED=0
FAILED_HINTS=""

# Required tools: jq, awk, aws, git
for cmd in jq awk aws git; do
  if command -v "$cmd" &>/dev/null; then
    echo "  [PASS] $cmd"
  else
    HINT="$(install_hint "$cmd")"
    echo "  [FAIL] $cmd not installed"
    echo "         → $HINT"
    FAILED=$((FAILED + 1))
    FAILED_HINTS="${FAILED_HINTS}\n    - $cmd: $HINT"
  fi
done

# Stop early if any tool is missing
if [[ "$FAILED" -gt 0 ]]; then
  err "${FAILED} required tool(s) missing" \
      "Install the following, then run this script again:${FAILED_HINTS}"
fi

# AWS credentials check
if ARN=$(aws sts get-caller-identity --query "Arn" --output text 2>/dev/null); then
  echo "  [PASS] AWS credentials: $ARN"
else
  echo "  [FAIL] AWS credentials not configured or expired"
  err "AWS credentials not found" \
      "Run: aws configure  or  aws sso login\n    If you don't have an AWS account, ask your admin to set it up."
fi

# CloudWatch log group check
if aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP" \
  --query "logGroups[?logGroupName=='$LOG_GROUP'].logGroupName" \
  --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
  echo "  [PASS] Log group: $LOG_GROUP"
else
  echo "  [FAIL] Log group '$LOG_GROUP' not found"
  err "CloudWatch log group '$LOG_GROUP' does not exist" \
      "Ask your admin to enable Bedrock Model Invocation Logging.\n    (Log group: $LOG_GROUP)"
fi

echo ""
log "All prerequisites passed."
echo ""

# ============================================================================
# Step 2: Clone or update plugin
# ============================================================================
if [[ -d "$INSTALL_DIR" ]]; then
  log "Updating existing installation..."
  git -C "$INSTALL_DIR" pull --quiet \
    || err "Failed to update $INSTALL_DIR" \
           "Delete and retry: rm -rf $INSTALL_DIR"
else
  log "Cloning to $INSTALL_DIR..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --quiet "$REPO_URL" "$INSTALL_DIR" \
    || err "Failed to clone $REPO_URL" \
           "Check your network connection. Corporate networks may require proxy settings."
fi

# ============================================================================
# Step 3: Register marketplace
# ============================================================================
log "Registering marketplace..."
claude plugin marketplace add "$INSTALL_DIR" \
  || err "Marketplace registration failed" \
         "Check that Claude Code is installed: claude --version"

# ============================================================================
# Step 4: Install plugin
# ============================================================================
log "Installing plugin..."
claude plugin install bedrock-cost-guardrail@bedrock-cost-guardrail \
  || err "Plugin installation failed" \
         "Check marketplace registration: claude plugin marketplace list"

# ============================================================================
# Step 5: Register blocking hooks (~/.claude/settings.json)
#
# The plugin hooks.json alone CANNOT block usage.
# Actual blocking requires hooks in settings.json.
# Existing cost-guardrail hooks are replaced; other plugins' hooks are preserved.
# ============================================================================
log "Registering blocking hooks in settings.json..."
HOOK_SS="bash $PLUGIN_PATH/hooks/check-cost.sh --event session_start"
HOOK_PS="bash $PLUGIN_PATH/hooks/check-cost.sh --event prompt_submit"

mkdir -p "$(dirname "$SETTINGS_FILE")"

SS_HOOK='{"hooks": [{"type": "command", "command": "'"$HOOK_SS"'", "timeout": 60}]}'
PS_HOOK='{"hooks": [{"type": "command", "command": "'"$HOOK_PS"'", "timeout": 30}]}'

if [[ ! -f "$SETTINGS_FILE" ]]; then
  # Create new settings.json
  jq -n \
    --argjson ss "$SS_HOOK" \
    --argjson ps "$PS_HOOK" \
    '{
      hooks: {
        SessionStart: [$ss],
        UserPromptSubmit: [$ps]
      }
    }' > "$SETTINGS_FILE" \
    || err "Failed to create $SETTINGS_FILE" \
           "Check that jq is working: jq --version"
else
  # Merge into existing settings.json (preserve other hooks, replace cost-guardrail hooks)
  TEMP_FILE="$(mktemp)"
  jq \
    --argjson ss "$SS_HOOK" \
    --argjson ps "$PS_HOOK" \
    --arg marker "check-cost.sh" \
    '
    .hooks.SessionStart = ([(.hooks.SessionStart // [])[] | select(.hooks[0].command | contains($marker) | not)] + [$ss])
    | .hooks.UserPromptSubmit = ([(.hooks.UserPromptSubmit // [])[] | select(.hooks[0].command | contains($marker) | not)] + [$ps])
    ' \
    "$SETTINGS_FILE" > "$TEMP_FILE" \
    || err "Failed to update $SETTINGS_FILE" \
           "Check settings.json syntax: jq . $SETTINGS_FILE\n    If broken, delete it and re-run: rm $SETTINGS_FILE"
  mv "$TEMP_FILE" "$SETTINGS_FILE"
fi

# ============================================================================
# Step 6: Verify installation
# ============================================================================
log "Verifying installation..."
VERIFY_FAILED=0

# check-cost.sh exists
if [[ -f "$PLUGIN_PATH/hooks/check-cost.sh" ]]; then
  echo "  [PASS] check-cost.sh"
else
  echo "  [FAIL] check-cost.sh not found"
  VERIFY_FAILED=$((VERIFY_FAILED + 1))
fi

# config.json is valid JSON
if [[ -f "$PLUGIN_PATH/config.json" ]] && jq . "$PLUGIN_PATH/config.json" &>/dev/null; then
  echo "  [PASS] config.json"
else
  echo "  [FAIL] config.json missing or invalid"
  VERIFY_FAILED=$((VERIFY_FAILED + 1))
fi

# settings.json hooks are registered
if jq -e '.hooks.SessionStart' "$SETTINGS_FILE" &>/dev/null && \
   jq -e '.hooks.UserPromptSubmit' "$SETTINGS_FILE" &>/dev/null; then
  echo "  [PASS] settings.json hooks registered"
else
  echo "  [FAIL] settings.json hooks not registered"
  VERIFY_FAILED=$((VERIFY_FAILED + 1))
fi

echo ""

if [[ "$VERIFY_FAILED" -gt 0 ]]; then
  err "${VERIFY_FAILED} verification check(s) failed" \
      "Share this entire output with your admin."
fi

# ============================================================================
# Done
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Installation complete!"
echo ""
echo "  Use these commands in Claude Code:"
echo "    Check cost:  /bedrock-cost-guardrail:cost-status"
echo "    View config: /bedrock-cost-guardrail:cost-config show"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Marketplace Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable public distribution of the cost-guardrail plugin via a marketplace repo with a one-command install experience.

**Architecture:** Two-repo model — source repo (this repo) for development, marketplace repo (`bedrock-cost-guardrail`) for distribution. A release script copies plugin files from source to marketplace. An install script in the marketplace repo handles cloning, registration, plugin install, and settings.json hook setup.

**Tech Stack:** Bash, JSON, Markdown (no programming languages)

**Spec:** `docs/superpowers/specs/2026-03-20-marketplace-deployment-design.md`

---

### Task 1: Fix source repo bugs and rename plugin

**Files:**
- Modify: `.claude-plugin/plugin.json` (rename)
- Modify: `hooks/check-cost.sh:44` (fix log_group fallback)

- [ ] **Step 1: Rename plugin in plugin.json**

Change `"name": "cost-guardrail"` to `"name": "bedrock-cost-guardrail"` in `.claude-plugin/plugin.json`:

```json
{
  "name": "bedrock-cost-guardrail",
  "version": "1.0.0",
  "description": "Per-user Bedrock cost monitoring with automatic usage blocking when spending threshold is reached",
  "author": {
    "name": "cost-guardrail-team"
  }
}
```

- [ ] **Step 2: Fix log_group fallback in check-cost.sh**

Line 44 of `hooks/check-cost.sh` — change the jq fallback default from `aws/bedrock/model-invocations` to `bedrock/model-invocations`:

Before:
```bash
LOG_GROUP=$(jq -r '.log_group // "aws/bedrock/model-invocations"' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
```

After:
```bash
LOG_GROUP=$(jq -r '.log_group // "bedrock/model-invocations"' "$CONFIG_FILE" 2>/dev/null) || { exit 0; }
```

- [ ] **Step 3: Validate changes**

Run:
```bash
bash -n hooks/check-cost.sh && echo "Syntax OK"
jq . .claude-plugin/plugin.json && echo "JSON OK"
```

Expected: Both print OK, no errors.

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json hooks/check-cost.sh
git commit -m "Rename plugin to bedrock-cost-guardrail, fix log_group fallback"
```

---

### Task 2: Update source repo README and CLAUDE.md

**Files:**
- Modify: `README.md` (command prefix update)
- Modify: `CLAUDE.md` (note rename, add release workflow)

- [ ] **Step 1: Update README.md command prefixes**

Replace all occurrences of `/cost-guardrail:` with `/bedrock-cost-guardrail:` in `README.md`. There are two instances:
- Line 11: `/cost-guardrail:cost-status` → `/bedrock-cost-guardrail:cost-status`
- Line 18-20: `/cost-guardrail:cost-config` → `/bedrock-cost-guardrail:cost-config`

- [ ] **Step 2: Update CLAUDE.md**

Add a "Release Workflow" section after the "Notes" section:

```markdown
## Release Workflow

To publish a new version to the marketplace repo:

```bash
bash scripts/release.sh /path/to/bedrock-cost-guardrail
cd /path/to/bedrock-cost-guardrail && git add -A && git commit -m "Release vX.Y.Z" && git push
```

The release script copies plugin files and generates a distribution config.json with safe defaults ($50 threshold).
```

Also update the Plugin Structure section: change any references to plugin name `cost-guardrail` that should now be `bedrock-cost-guardrail`.

- [ ] **Step 3: Validate JSON files unchanged**

Run:
```bash
find . -name "*.json" -not -path "./.git/*" -exec jq . {} \;
```

Expected: All JSON files parse successfully.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "Update command prefixes and add release workflow to docs"
```

---

### Task 3: Create release script

**Files:**
- Create: `scripts/release.sh`

- [ ] **Step 1: Create scripts directory and release.sh**

Create `scripts/release.sh` with this content:

```bash
#!/usr/bin/env bash
# release.sh — Copy plugin files from source repo to marketplace repo
# Usage: bash scripts/release.sh /path/to/bedrock-cost-guardrail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET_DIR="${1:-}"
if [[ -z "$TARGET_DIR" ]]; then
  echo "Usage: bash scripts/release.sh /path/to/bedrock-cost-guardrail" >&2
  exit 1
fi

TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

# Validate target is a marketplace repo
if [[ ! -f "$TARGET_DIR/.claude-plugin/marketplace.json" ]]; then
  echo "Error: $TARGET_DIR/.claude-plugin/marketplace.json not found" >&2
  echo "Target must be a marketplace repo with .claude-plugin/marketplace.json" >&2
  exit 1
fi

PLUGIN_DIR="$TARGET_DIR/plugins/bedrock-cost-guardrail"

echo "[release] Source: $SOURCE_ROOT"
echo "[release] Target: $PLUGIN_DIR"

# Clean target plugin directory
if [[ -d "$PLUGIN_DIR" ]]; then
  echo "[release] Cleaning $PLUGIN_DIR..."
  rm -rf "$PLUGIN_DIR"
fi

# Create directory structure
mkdir -p "$PLUGIN_DIR/.claude-plugin"
mkdir -p "$PLUGIN_DIR/commands"
mkdir -p "$PLUGIN_DIR/hooks"
mkdir -p "$PLUGIN_DIR/skills/cost-awareness"

# Copy plugin files
echo "[release] Copying plugin files..."
cp "$SOURCE_ROOT/.claude-plugin/plugin.json" "$PLUGIN_DIR/.claude-plugin/plugin.json"
cp "$SOURCE_ROOT/commands/cost-status.md"    "$PLUGIN_DIR/commands/cost-status.md"
cp "$SOURCE_ROOT/commands/cost-config.md"    "$PLUGIN_DIR/commands/cost-config.md"
cp "$SOURCE_ROOT/hooks/hooks.json"           "$PLUGIN_DIR/hooks/hooks.json"
cp "$SOURCE_ROOT/hooks/check-cost.sh"        "$PLUGIN_DIR/hooks/check-cost.sh"
cp "$SOURCE_ROOT/skills/cost-awareness/SKILL.md" "$PLUGIN_DIR/skills/cost-awareness/SKILL.md"

# Generate distribution config.json with safe defaults
echo "[release] Generating distribution config.json..."
cat > "$PLUGIN_DIR/config.json" << 'DIST_CONFIG'
{
  "threshold_usd": 50,
  "period": "monthly",
  "check_interval": 10,
  "log_group": "bedrock/model-invocations",
  "timezone": "UTC",
  "default_input_per_1k": 0.003,
  "default_output_per_1k": 0.015,
  "default_cache_read_per_1k": 0.0003,
  "default_cache_write_per_1k": 0.00375,
  "pricing": {
    "anthropic.claude-opus-4-6-v1": {
      "input_per_1k": 0.015,
      "output_per_1k": 0.075,
      "cache_read_per_1k": 0.0015,
      "cache_write_per_1k": 0.01875
    },
    "anthropic.claude-sonnet-4-6-v1": {
      "input_per_1k": 0.003,
      "output_per_1k": 0.015,
      "cache_read_per_1k": 0.0003,
      "cache_write_per_1k": 0.00375
    },
    "anthropic.claude-haiku-4-5-20251001-v1:0": {
      "input_per_1k": 0.0008,
      "output_per_1k": 0.004,
      "cache_read_per_1k": 0.00008,
      "cache_write_per_1k": 0.001
    }
  }
}
DIST_CONFIG

# Summary
echo ""
echo "[release] Done! Files copied to $PLUGIN_DIR:"
find "$PLUGIN_DIR" -type f | sort | while read -r f; do
  echo "  ${f#$TARGET_DIR/}"
done
echo ""
echo "[release] Next steps:"
echo "  cd $TARGET_DIR"
echo "  git add -A && git diff --cached --stat"
echo "  git commit -m 'Release vX.Y.Z'"
echo "  git push"
```

- [ ] **Step 2: Make executable and syntax check**

Run:
```bash
chmod +x scripts/release.sh
bash -n scripts/release.sh && echo "Syntax OK"
```

Expected: "Syntax OK"

- [ ] **Step 3: Commit**

```bash
git add scripts/release.sh
git commit -m "Add release script for marketplace deployment"
```

---

### Task 4: Create marketplace repo scaffold

This task creates the marketplace repo locally for testing. The repo will later be pushed to GitHub.

**Files (all in a new directory outside source repo):**
- Create: `~/bedrock-cost-guardrail/.claude-plugin/marketplace.json`
- Create: `~/bedrock-cost-guardrail/install.sh`
- Create: `~/bedrock-cost-guardrail/README.md`

- [ ] **Step 1: Initialize marketplace repo**

```bash
mkdir -p ~/bedrock-cost-guardrail/.claude-plugin
cd ~/bedrock-cost-guardrail && git init
```

- [ ] **Step 2: Create marketplace.json**

Create `~/bedrock-cost-guardrail/.claude-plugin/marketplace.json`:

```json
{
  "name": "bedrock-cost-guardrail",
  "description": "Per-user Bedrock cost monitoring with automatic usage blocking",
  "owner": { "name": "<org>" },
  "plugins": [
    {
      "name": "bedrock-cost-guardrail",
      "description": "Per-user Bedrock cost monitoring with automatic usage blocking when spending threshold is reached",
      "source": "./plugins/bedrock-cost-guardrail"
    }
  ]
}
```

- [ ] **Step 3: Validate marketplace.json**

Run:
```bash
jq . ~/bedrock-cost-guardrail/.claude-plugin/marketplace.json
```

Expected: Valid JSON output.

- [ ] **Step 4: Commit scaffold**

```bash
cd ~/bedrock-cost-guardrail
git add .claude-plugin/marketplace.json
git commit -m "Initialize marketplace repo with marketplace.json"
```

---

### Task 5: Test release script end-to-end

**Files:**
- Read: `scripts/release.sh` (source repo)
- Verify: `~/bedrock-cost-guardrail/plugins/bedrock-cost-guardrail/` (marketplace repo)

- [ ] **Step 1: Run release script**

```bash
cd /home/ubuntu/cost-guardrail-claude-code-bedrock
bash scripts/release.sh ~/bedrock-cost-guardrail
```

Expected output: List of files copied, next steps printed.

- [ ] **Step 2: Verify copied files**

```bash
find ~/bedrock-cost-guardrail/plugins/bedrock-cost-guardrail -type f | sort
```

Expected:
```
.claude-plugin/plugin.json
commands/cost-config.md
commands/cost-status.md
config.json
hooks/check-cost.sh
hooks/hooks.json
skills/cost-awareness/SKILL.md
```

- [ ] **Step 3: Verify distribution config has safe defaults**

```bash
jq '.threshold_usd' ~/bedrock-cost-guardrail/plugins/bedrock-cost-guardrail/config.json
```

Expected: `50` (not the source repo's working threshold).

- [ ] **Step 4: Verify plugin.json has new name**

```bash
jq '.name' ~/bedrock-cost-guardrail/plugins/bedrock-cost-guardrail/.claude-plugin/plugin.json
```

Expected: `"bedrock-cost-guardrail"`

- [ ] **Step 5: Commit marketplace repo**

```bash
cd ~/bedrock-cost-guardrail
git add plugins/
git commit -m "Release v1.0.0 — initial plugin files"
```

---

### Task 6: Create install.sh in marketplace repo

**Files:**
- Create: `~/bedrock-cost-guardrail/install.sh`

- [ ] **Step 1: Create install.sh**

Create `~/bedrock-cost-guardrail/install.sh`:

```bash
#!/usr/bin/env bash
# install.sh — One-command installer for bedrock-cost-guardrail plugin
set -euo pipefail

REPO_URL="https://github.com/<org>/bedrock-cost-guardrail.git"
INSTALL_DIR="$HOME/.claude/plugins/bedrock-cost-guardrail"
PLUGIN_PATH="$INSTALL_DIR/plugins/bedrock-cost-guardrail"
SETTINGS_FILE="$HOME/.claude/settings.json"

log() { echo "[bedrock-cost-guardrail] $1"; }
err() { echo "[bedrock-cost-guardrail] ERROR: $1" >&2; exit 1; }

# --- Step 1: Check prerequisites ---
log "Checking prerequisites..."
MISSING=""
for cmd in claude jq aws bc git; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING="$MISSING $cmd"
  fi
done
if [[ -n "$MISSING" ]]; then
  err "Missing required commands:$MISSING"
fi

# --- Step 2: Clone or update ---
if [[ -d "$INSTALL_DIR" ]]; then
  log "Updating existing installation..."
  git -C "$INSTALL_DIR" pull --quiet || err "Failed to update $INSTALL_DIR"
else
  log "Cloning to $INSTALL_DIR..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --quiet "$REPO_URL" "$INSTALL_DIR" || err "Failed to clone $REPO_URL"
fi

# --- Step 3: Register marketplace ---
log "Registering marketplace..."
claude plugin marketplace add "$INSTALL_DIR" || err "Failed to register marketplace"

# --- Step 4: Install plugin ---
log "Installing plugin..."
claude plugin install bedrock-cost-guardrail@bedrock-cost-guardrail || err "Failed to install plugin"

# --- Step 5: Patch settings.json ---
log "Configuring settings.json hooks..."
HOOK_SS="bash $PLUGIN_PATH/hooks/check-cost.sh --event session_start"
HOOK_PS="bash $PLUGIN_PATH/hooks/check-cost.sh --event prompt_submit"

mkdir -p "$(dirname "$SETTINGS_FILE")"

SS_HOOK='{"hooks": [{"type": "command", "command": "'"$HOOK_SS"'", "timeout": 60}]}'
PS_HOOK='{"hooks": [{"type": "command", "command": "'"$HOOK_PS"'", "timeout": 30}]}'

if [[ ! -f "$SETTINGS_FILE" ]]; then
  # Create new settings.json with hooks
  jq -n \
    --argjson ss "$SS_HOOK" \
    --argjson ps "$PS_HOOK" \
    '{
      hooks: {
        SessionStart: [$ss],
        UserPromptSubmit: [$ps]
      }
    }' > "$SETTINGS_FILE" || err "Failed to create $SETTINGS_FILE"
else
  # Merge hooks into existing settings.json, preserving other plugins' hooks
  TEMP_FILE="$(mktemp)"
  jq \
    --argjson ss "$SS_HOOK" \
    --argjson ps "$PS_HOOK" \
    --arg marker "check-cost.sh" \
    '
    # Remove any existing cost-guardrail hooks (by matching command string)
    .hooks.SessionStart = ([(.hooks.SessionStart // [])[] | select(.hooks[0].command | contains($marker) | not)] + [$ss])
    | .hooks.UserPromptSubmit = ([(.hooks.UserPromptSubmit // [])[] | select(.hooks[0].command | contains($marker) | not)] + [$ps])
    ' \
    "$SETTINGS_FILE" > "$TEMP_FILE" || err "Failed to patch $SETTINGS_FILE. Manual setup required — see README."
  mv "$TEMP_FILE" "$SETTINGS_FILE"
fi

# --- Done ---
log "Done! Plugin installed successfully."
echo ""
echo "  Verify: /bedrock-cost-guardrail:cost-status"
echo "  Config: /bedrock-cost-guardrail:cost-config show"
```

- [ ] **Step 2: Make executable and syntax check**

Run:
```bash
chmod +x ~/bedrock-cost-guardrail/install.sh
bash -n ~/bedrock-cost-guardrail/install.sh && echo "Syntax OK"
```

Expected: "Syntax OK"

- [ ] **Step 3: Commit**

```bash
cd ~/bedrock-cost-guardrail
git add install.sh
git commit -m "Add one-command installer script"
```

---

### Task 7: Create marketplace README.md

**Files:**
- Create: `~/bedrock-cost-guardrail/README.md`

- [ ] **Step 1: Create README.md**

Create `~/bedrock-cost-guardrail/README.md`:

```markdown
# Bedrock Cost Guardrail

Claude Code plugin that monitors per-IAM-user Amazon Bedrock API costs and blocks usage when a spending threshold is reached.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/<org>/bedrock-cost-guardrail/main/install.sh | bash
```

Or clone and run manually:

```bash
git clone https://github.com/<org>/bedrock-cost-guardrail.git ~/.claude/plugins/bedrock-cost-guardrail
bash ~/.claude/plugins/bedrock-cost-guardrail/install.sh
```

## Prerequisites

- [Claude Code](https://claude.ai/code) installed
- AWS CLI v2 configured with permissions: `logs:StartQuery`, `logs:GetQueryResults`, `sts:GetCallerIdentity`
- Bedrock Model Invocation Logging enabled (CloudWatch Logs)
- jq, bc installed

## Usage

### Check current cost

```
/bedrock-cost-guardrail:cost-status
```

### View or change settings

```
/bedrock-cost-guardrail:cost-config show
/bedrock-cost-guardrail:cost-config set check_interval 5
/bedrock-cost-guardrail:cost-config set period daily
```

## How It Works

- Checks estimated Bedrock cost at session start and every Nth prompt (default: 10)
- Calculates cost from CloudWatch Logs using per-model token pricing (input, output, cache read, cache write)
- Blocks usage (hard block) when the configured spending threshold is reached
- Fails open on all errors — infrastructure issues never block developers

## Default Settings

| Setting | Default | Description |
|---------|---------|-------------|
| threshold_usd | $50 | Spending limit before blocking |
| period | monthly | Cost accumulation window |
| check_interval | 10 | Check cost every Nth prompt |
| timezone | UTC | Period boundary timezone |

## Uninstall

1. Remove hooks from `~/.claude/settings.json` (delete the `SessionStart` and `UserPromptSubmit` entries referencing `check-cost.sh`)
2. Uninstall plugin: `claude plugin uninstall bedrock-cost-guardrail` (if supported)
3. Remove marketplace: `claude plugin marketplace remove bedrock-cost-guardrail` (if supported)
4. Remove the plugin directory: `rm -rf ~/.claude/plugins/bedrock-cost-guardrail`

## Source

Development repo and detailed documentation: [cost-guardrail-claude-code-bedrock](https://github.com/<org>/cost-guardrail-claude-code-bedrock)
```

- [ ] **Step 2: Commit**

```bash
cd ~/bedrock-cost-guardrail
git add README.md
git commit -m "Add English README with install and usage guide"
```

---

### Task 8: End-to-end validation

- [ ] **Step 1: Validate all JSON in marketplace repo**

```bash
find ~/bedrock-cost-guardrail -name "*.json" -not -path "*/.git/*" -exec jq . {} \;
```

Expected: All files parse successfully.

- [ ] **Step 2: Validate all bash scripts**

```bash
bash -n ~/bedrock-cost-guardrail/install.sh && echo "install.sh OK"
bash -n ~/bedrock-cost-guardrail/plugins/bedrock-cost-guardrail/hooks/check-cost.sh && echo "check-cost.sh OK"
```

Expected: Both OK.

- [ ] **Step 3: Validate source repo**

```bash
cd /home/ubuntu/cost-guardrail-claude-code-bedrock
bash -n hooks/check-cost.sh && echo "check-cost.sh OK"
find . -name "*.json" -not -path "./.git/*" -exec jq . {} \; > /dev/null && echo "All JSON OK"
```

Expected: Both OK.

- [ ] **Step 4: Verify release script is idempotent**

Run the release script a second time and verify it produces identical output:

```bash
cd /home/ubuntu/cost-guardrail-claude-code-bedrock
bash scripts/release.sh ~/bedrock-cost-guardrail
cd ~/bedrock-cost-guardrail && git diff
```

Expected: No changes (clean diff).

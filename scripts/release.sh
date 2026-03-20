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

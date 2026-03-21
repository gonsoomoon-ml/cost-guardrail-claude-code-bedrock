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
mkdir -p "$PLUGIN_DIR/img"

# Copy plugin files
echo "[release] Copying plugin files..."
cp "$SOURCE_ROOT/.claude-plugin/plugin.json" "$PLUGIN_DIR/.claude-plugin/plugin.json"
cp "$SOURCE_ROOT/commands/cost-status.md"    "$PLUGIN_DIR/commands/cost-status.md"
cp "$SOURCE_ROOT/commands/cost-config.md"    "$PLUGIN_DIR/commands/cost-config.md"
cp "$SOURCE_ROOT/hooks/hooks.json"           "$PLUGIN_DIR/hooks/hooks.json"
cp "$SOURCE_ROOT/hooks/check-cost.sh"        "$PLUGIN_DIR/hooks/check-cost.sh"
cp "$SOURCE_ROOT/hooks/lib-cost.sh"          "$PLUGIN_DIR/hooks/lib-cost.sh"
cp "$SOURCE_ROOT/skills/cost-awareness/SKILL.md" "$PLUGIN_DIR/skills/cost-awareness/SKILL.md"

# Copy screenshot images (referenced by both plugin and repo-root README)
if [[ -d "$SOURCE_ROOT/img" ]]; then
  echo "[release] Copying images..."
  mkdir -p "$TARGET_DIR/img"
  cp "$SOURCE_ROOT"/img/*.png "$PLUGIN_DIR/img/" 2>/dev/null || true
  cp "$SOURCE_ROOT"/img/*.png "$TARGET_DIR/img/" 2>/dev/null || true
fi

# Generate distribution config.json by merging base + dist overrides
# config.json (pricing, log_group) + admin/config.dist.json (threshold, period, etc.)
echo "[release] Generating distribution config.json..."
DIST_OVERRIDE="${SOURCE_ROOT}/admin/config.dist.json"
if [[ ! -f "$DIST_OVERRIDE" ]]; then
  echo "Error: admin/config.dist.json not found" >&2
  exit 1
fi
jq -s '.[0] * .[1]' "$SOURCE_ROOT/config.json" "$DIST_OVERRIDE" > "$PLUGIN_DIR/config.json"

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

#!/usr/bin/env bash
#
# Single source of truth for the release version is the repo-root VERSION file.
# This script propagates that version into every place it must appear:
#   - the three product manifests (zymtrace/.claude-plugin, .codex-plugin, .cursor-plugin)
#   - the Claude marketplace.json plugin entry (.claude-plugin/marketplace.json)
# Skills carry no version (the plugin is the versioned unit). The Codex and Cursor
# marketplace files carry no version field either — version lives in their plugin.json.
#
# Usage:
#   ./scripts/sync-version.sh            # propagate the current VERSION file to all manifests + skills
#   ./scripts/sync-version.sh 26.6.0     # set VERSION to 26.6.0, then propagate
#
# After running, `make test` verifies everything is in lockstep.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"

# If a version is passed, write it to the VERSION file first.
if [[ "${1:-}" != "" ]]; then
  echo "$1" > "$VERSION_FILE"
fi

V="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: VERSION '$V' is not semver (X.Y.Z)." >&2
  exit 1
fi

echo "Syncing version → $V"

# JSON manifests: each has exactly one "version": "..." key to bump.
json_files=(
  "$ROOT/zymtrace/.claude-plugin/plugin.json"
  "$ROOT/zymtrace/.codex-plugin/plugin.json"
  "$ROOT/zymtrace/.cursor-plugin/plugin.json"
  "$ROOT/.claude-plugin/marketplace.json"
)
for f in "${json_files[@]}"; do
  sed -i.bak -E 's/"version": "[^"]*"/"version": "'"$V"'"/' "$f" && rm -f "$f.bak"
  echo "  updated $(basename "$(dirname "$f")")/$(basename "$f")"
done

# Skills carry no version — the plugin is the versioned unit.

echo "Done. Run 'make test' to verify lockstep."

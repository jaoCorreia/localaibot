#!/bin/bash
# Build the macOS shell, sign it with the virtualization entitlement, and run it.
# The brain (../brain) is started by the app itself.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/apps/mac"

(cd "$ROOT/brain" && [ -d node_modules ] || npm install --silent)

swift build --package-path "$APP"
BIN="$(swift build --package-path "$APP" --show-bin-path)/LocalBot"

# Virtualization.framework refuses to run without this entitlement. Ad-hoc signing is enough locally.
codesign --force --sign - --entitlements "$APP/LocalBot.entitlements" "$BIN"

LOCALBOT_BRAIN_DIR="$ROOT/brain" exec "$BIN"

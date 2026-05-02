#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINUX_AGENT_DIR="$ROOT_DIR/linux-agent"
APP_NAME="DKST Linux Battery Agent"
OUTPUT="$ROOT_DIR/build/$APP_NAME"

mkdir -p "$ROOT_DIR/build"
(
  cd "$LINUX_AGENT_DIR"
  go build -o "$OUTPUT" .
)
chmod +x "$OUTPUT"

echo "Built $OUTPUT"

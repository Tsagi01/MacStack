#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/scripts/swift-env.sh"
cd "$PROJECT_DIR"
swift test --scratch-path "$BUILD_CACHE"

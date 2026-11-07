#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIGURATION="${1:-Debug}"
case "$BUILD_CONFIGURATION" in Debug|Release) ;; *) printf 'Use Debug or Release.\n' >&2; exit 64 ;; esac
TASK_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
LOG_DIR="$PROJECT_ROOT/.build/BuildLogs"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/xcodebuild-$BUILD_CONFIGURATION.log"
if DEVELOPER_DIR="$TASK_DEVELOPER_DIR" xcodebuild \
    -project "$PROJECT_ROOT/SnapFrame.xcodeproj" \
    -scheme SnapFrame -configuration "$BUILD_CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$PROJECT_ROOT/.build/Xcode$BUILD_CONFIGURATION" \
    CODE_SIGN_IDENTITY=- build > "$LOG_PATH" 2>&1; then
    BUILD_RESULT=0
else
    BUILD_RESULT=$?
fi
tail -n 30 "$LOG_PATH"
printf 'Xcode build exit: %s; full log: %s\n' "$BUILD_RESULT" "$LOG_PATH"
exit "$BUILD_RESULT"

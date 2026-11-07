#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_ROOT/Scripts/xcode-build.sh" Release
APP_SOURCE="$PROJECT_ROOT/.build/XcodeRelease/Build/Products/Release/SnapFrame.app"
APP_DESTINATION="$PROJECT_ROOT/.build/SnapFrame.app"
/usr/bin/codesign --verify --deep --strict "$APP_SOURCE"
# Replace this generated build artifact; merging leaves resources from older builds.
/bin/rm -rf "$APP_DESTINATION"
/usr/bin/ditto "$APP_SOURCE" "$APP_DESTINATION"
/usr/bin/codesign --verify --deep --strict "$APP_DESTINATION"
printf 'Built %s (including Finder Quick Action)\n' "$APP_DESTINATION"

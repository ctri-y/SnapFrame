#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="${ARCH:-$(uname -m)}"
mkdir -p "$BUILD_DIR/ModuleCache"
xcrun swiftc -swift-version 6 -parse-as-library \
    -target "$ARCH-apple-macosx14.0" -sdk "$SDK_PATH" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    "$PROJECT_ROOT/SnapFrame/Models/ImportedImage.swift" \
    "$PROJECT_ROOT/SnapFrame/Models/ImportModel.swift" \
    "$PROJECT_ROOT/SnapFrame/Services/ImageImportService.swift" \
    "$PROJECT_ROOT/SnapFrame/Services/FileDropReader.swift" \
    "$PROJECT_ROOT/Tests/ImportChecks.swift" \
    -o "$BUILD_DIR/ImportChecks"
"$BUILD_DIR/ImportChecks" "$BUILD_DIR/TestFixtures"

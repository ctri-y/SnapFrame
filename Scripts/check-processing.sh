#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build/MVP"
mkdir -p "$BUILD_DIR/ModuleCache"
xcrun swiftc -swift-version 6 -parse-as-library \
    -target "$(uname -m)-apple-macosx14.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    "$PROJECT_ROOT/SnapFrame/Models/ImportedImage.swift" \
    "$PROJECT_ROOT/SnapFrame/Services/ImageImportService.swift" \
    "$PROJECT_ROOT/SnapFrame/Core/ProcessingIO.swift" \
    "$PROJECT_ROOT/SnapFrame/Core/ImageProcessor.swift" \
    "$PROJECT_ROOT/SnapFrame/Core/BatchJobRunner.swift" \
    "$PROJECT_ROOT/Tests/ProcessingChecks.swift" -o "$BUILD_DIR/ProcessingChecks"
"$BUILD_DIR/ProcessingChecks" "$PROJECT_ROOT" "$@"

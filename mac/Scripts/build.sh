#!/bin/bash
# Unified build and test entry for Meno.
#
# Usage:
#   Scripts/build.sh           Debug build + all tests (unsigned, safe to run anytime)
#   Scripts/build.sh test      Tests only
#   Scripts/build.sh release   Signed Release build, ready for Scripts/install.sh
#
# Debug builds run unsigned on purpose: an unsigned build never triggers a
# temporary Finder extension registration from the build directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MAC_ROOT/.." && pwd)"
BUILD_ROOT="$REPO_ROOT/build/mac"
RENDERER_ROOT="$MAC_ROOT/Features/MarkdownPreviewRenderer"

mkdir -p "$BUILD_ROOT"
cd "$MAC_ROOT"

PROJECT="Meno.xcodeproj"
SCHEME="MenoApp"
RELEASE_PRODUCT="$BUILD_ROOT/ReleaseDerivedData/Build/Products/Release/Meno.app"

build_renderer() {
    command -v npm >/dev/null 2>&1 || {
        echo "ERROR: npm is required to build the Markdown preview renderer." >&2
        exit 1
    }
    cd "$RENDERER_ROOT"
    npm ci --no-audit --no-fund
    npm run typecheck
    npm test
    npm run build
    cd "$MAC_ROOT"
}

if [ $# -gt 1 ]; then
    echo "Usage: $0 [debug|test|release]" >&2
    exit 2
fi

case "${1:-debug}" in
    debug)
        build_renderer
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
            -derivedDataPath "$BUILD_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO build test
        ;;
    test)
        build_renderer
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
            -derivedDataPath "$BUILD_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO test
        ;;
    release)
        build_renderer
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
            -derivedDataPath "$BUILD_ROOT/ReleaseDerivedData" build
        codesign --verify --deep --strict "$RELEASE_PRODUCT"
        echo "Release product verified: $RELEASE_PRODUCT"
        ;;
    *)
        echo "Usage: $0 [debug|test|release]" >&2
        exit 2
        ;;
esac

# A signed build can leave a temporary extension registration pointing at the
# build directory; make sure only the fixed /Applications copy stays registered.
"$SCRIPT_DIR/clean-ext.sh"

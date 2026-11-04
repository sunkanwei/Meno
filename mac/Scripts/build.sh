#!/bin/bash
# Unified build and test entry for Meno.
#
# Usage:
#   Scripts/build.sh           Debug build + all tests (unsigned, safe to run anytime)
#   Scripts/build.sh test      Tests only
#   Scripts/build.sh test MenoTests/TestClass  Run one Swift test class or method
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

finish_build() {
    local status=$?
    if ! "$SCRIPT_DIR/clean-ext.sh"; then
        echo "ERROR: Could not clean up extension registrations." >&2
        if [ "$status" -eq 0 ]; then status=1; fi
    fi
    exit "$status"
}

usage() {
    echo "Usage: $0 [debug|test [MenoTests/TestClass[/testMethod] ...]|release]" >&2
    exit 2
}

MODE="${1:-debug}"
SWIFT_TEST_SELECTION=()
if [ "$#" -gt 1 ]; then
    [ "$MODE" = test ] || usage
    shift
    for test_id in "$@"; do
        case "$test_id" in
            MenoTests/?*) SWIFT_TEST_SELECTION+=("-only-testing:$test_id") ;;
            *) usage ;;
        esac
    done
fi
case "$MODE" in
    debug|test|release) ;;
    *) usage ;;
esac

build_renderer
# Xcode can register temporary extensions even when a later build step fails.
trap finish_build EXIT

case "$MODE" in
    debug)
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
            -derivedDataPath "$BUILD_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO build test
        ;;
    test)
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
            -derivedDataPath "$BUILD_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO \
            ${SWIFT_TEST_SELECTION[@]+"${SWIFT_TEST_SELECTION[@]}"} test
        ;;
    release)
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
            -derivedDataPath "$BUILD_ROOT/ReleaseDerivedData" build
        codesign --verify --deep --strict "$RELEASE_PRODUCT"
        echo "Release product verified: $RELEASE_PRODUCT"
        ;;
esac

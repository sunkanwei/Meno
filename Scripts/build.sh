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

cd "$(dirname "$0")/.."

PROJECT="Meno.xcodeproj"
SCHEME="MenoApp"
RELEASE_PRODUCT="build/ReleaseDerivedData/Build/Products/Release/Meno.app"

if [ $# -gt 1 ]; then
    echo "Usage: $0 [debug|test|release]" >&2
    exit 2
fi

case "${1:-debug}" in
    debug)
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
            -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build test
        ;;
    test)
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
            -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
        ;;
    release)
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
            -derivedDataPath build/ReleaseDerivedData build
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
"$(dirname "$0")/clean-ext.sh"

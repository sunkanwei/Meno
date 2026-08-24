#!/bin/bash
# Build (Release, signed) and install Meno to /Applications/Meno.app.
#
# This script encodes the project install rules so they cannot be skipped:
#   1. fresh signed Release build
#   2. verify the new product (bundle id, embedded extensions, helper, signature)
#   3. verify the currently installed copy matches the same identity/signature
#   4. quit Meno, move the old version to a timestamped backup (never delete)
#   5. install and re-verify; on failure move the failed copy aside and restore
#   6. clean extension registrations, restart Finder, launch, verify process
#
# Backups are kept under the repository-local build/mac/backups/ directory and
# are never removed automatically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MAC_ROOT/.." && pwd)"
BUILD_ROOT="$REPO_ROOT/build/mac"

mkdir -p "$BUILD_ROOT"
cd "$MAC_ROOT"

INSTALL="/Applications/Meno.app"
PRODUCT="$BUILD_ROOT/ReleaseDerivedData/Build/Products/Release/Meno.app"
EXPECTED_ID="com.sunkanwei.Meno"
EXPECTED_FINDER_EXT_ID="com.sunkanwei.Meno.FinderExtension"
EXPECTED_PREVIEW_EXT_ID="com.sunkanwei.Meno.MarkdownPreview"
EXPECTED_HELPER_ID="com.sunkanwei.Meno.PowerHelper"
EXPECTED_AUTH="Meno Local Development"
BACKUP_ROOT="$BUILD_ROOT/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"

fail() { echo "ERROR: $*" >&2; exit 1; }

verify_appex() {
    local app="$1" label="$2" appex="$3" expected_id="$4"
    local appex_path="$app/Contents/PlugIns/$appex.appex" actual
    [ -d "$appex_path" ] || { echo "ERROR: $label is missing embedded $appex.appex" >&2; return 1; }
    actual="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$appex_path/Contents/Info.plist" 2>/dev/null)"
    [ "$actual" = "$expected_id" ] || { echo "ERROR: $label embeds $appex.appex with bundle id '$actual', expected '$expected_id'" >&2; return 1; }
}

verify_bundle() {
    local app="$1" label="$2" actual auth
    [ -d "$app" ] || { echo "ERROR: $label not found: $app" >&2; return 1; }
    actual="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)"
    [ "$actual" = "$EXPECTED_ID" ] || { echo "ERROR: $label bundle id is '$actual', expected '$EXPECTED_ID'" >&2; return 1; }
    verify_appex "$app" "$label" MenoFinderExtension "$EXPECTED_FINDER_EXT_ID" || return 1
    verify_appex "$app" "$label" MenoMarkdownPreview "$EXPECTED_PREVIEW_EXT_ID" || return 1
    local helper="$app/Contents/Library/PrivilegedHelperTools/$EXPECTED_HELPER_ID"
    [ -f "$helper" ] || { echo "ERROR: $label is missing the embedded power helper" >&2; return 1; }
    actual="$(codesign -dvvv "$helper" 2>&1 | awk -F= '/^Identifier=/ {value = $2} END {print value}')"
    [ "$actual" = "$EXPECTED_HELPER_ID" ] || { echo "ERROR: $label power helper signed as '$actual', expected '$EXPECTED_HELPER_ID'" >&2; return 1; }
    codesign --verify --deep --strict "$app" || { echo "ERROR: $label failed signature verification" >&2; return 1; }
    auth="$(codesign -dvvv "$app" 2>&1 | awk -F= '/^Authority=/ {value = $2} END {print value}')"
    [ "$auth" = "$EXPECTED_AUTH" ] || { echo "ERROR: $label signed by '$auth', expected '$EXPECTED_AUTH'" >&2; return 1; }
}

# 1. Fresh signed Release build, then verify the product.
"$SCRIPT_DIR/build.sh" release
verify_bundle "$PRODUCT" "New build" || fail "New build verification failed; not installing."

# 2. Verify the installed copy before touching it.
if [ -d "$INSTALL" ]; then
    verify_bundle "$INSTALL" "Installed app" || fail "Installed app identity/signature mismatch; refusing to replace it."
fi

# 3. Quit Meno if running.
wait_for_exit() {
    for _ in $(seq 1 20); do
        pgrep -x Meno >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    return 1
}
if pgrep -x Meno >/dev/null 2>&1; then
    osascript -e 'tell application id "com.sunkanwei.Meno" to quit' >/dev/null 2>&1 || true
    if ! wait_for_exit; then
        pkill -x Meno || true
        wait_for_exit || true
    fi
fi

# 4. Move the old version to a timestamped backup, then install the new one.
BACKUP_DIR=""
if [ -d "$INSTALL" ]; then
    BACKUP_DIR="$BACKUP_ROOT/Meno-$STAMP"
    [ ! -e "$BACKUP_DIR/Meno.app" ] || fail "Backup already exists: $BACKUP_DIR/Meno.app"
    mkdir -p "$BACKUP_DIR"
    mv "$INSTALL" "$BACKUP_DIR/Meno.app"
    echo "Previous version moved to $BACKUP_DIR/Meno.app"
fi
ditto "$PRODUCT" "$INSTALL"

# 5. Verify the installed copy; on failure set it aside and restore the backup.
if ! verify_bundle "$INSTALL" "Installed app"; then
    FAILED_DIR="$BACKUP_ROOT/failed-$STAMP"
    mkdir -p "$FAILED_DIR"
    if ! mv "$INSTALL" "$FAILED_DIR/Meno.app"; then
        fail "Could not move the failed install aside; left at $INSTALL. Backup intact at ${BACKUP_DIR:-<none>}."
    fi
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR/Meno.app" ]; then
        mv "$BACKUP_DIR/Meno.app" "$INSTALL"
        open "$INSTALL" 2>/dev/null || true
        echo "Restored and relaunched the previous version from $BACKUP_DIR/Meno.app"
    fi
    fail "Installation verification failed. Failed copy kept at $FAILED_DIR/Meno.app"
fi

# 6. Clean registrations, reload extensions from the fixed path, restart Finder.
"$SCRIPT_DIR/clean-ext.sh" --reload

# 7. Launch and confirm the process is running.
open "$INSTALL"
for _ in $(seq 1 20); do
    pgrep -x Meno >/dev/null 2>&1 && break
    sleep 0.5
done
pgrep -x Meno >/dev/null 2>&1 || fail "Meno did not start after installation."

cat <<EOF

Installation complete.
Feature-specific manual acceptance checks (not part of build or tests):
  1. Only when Finder context-menu behavior changed, right-click empty space
     in a Finder folder and verify "新建文档" lists "文本文档" and
     "Markdown 文档".
  2. Only when menu bar behavior changed, verify the affected feature responds.
  3. If the system asks to re-confirm accessibility/input monitoring
     permission, confirm it.
Backup kept at: ${BACKUP_DIR:-<none>} (delete it yourself when satisfied).
EOF

#!/bin/bash
# Build (Release, signed) and install Meno to /Applications/Meno.app.
#
# This script encodes the project install rules so they cannot be skipped:
#   1. fresh signed Release build
#   2. verify the new product (bundle id, embedded extensions, helper, signature)
#   3. verify the currently installed copy matches the same identity/signature
#   4. quit Meno, move the old version to a timestamped backup (never delete)
#   5. install, verify, reload extensions and launch from the fixed path
#   6. on any replacement failure, move the failed copy aside and restore
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

installed_pids() {
    ps -axo pid=,comm= | awk -v exe="$INSTALL/Contents/MacOS/Meno" '
        { pid = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == exe) print pid }
    '
}

wait_for_process() {
    local expected="$1" pids
    for _ in $(seq 1 20); do
        pids="$(installed_pids)" || return 1
        if [ "$expected" = running ] && [ -n "$pids" ]; then return 0; fi
        if [ "$expected" = stopped ] && [ -z "$pids" ]; then return 0; fi
        sleep 0.5
    done
    return 1
}

quit_installed_app() {
    local pids pid
    pids="$(installed_pids)" || return 1
    [ -n "$pids" ] || return 0
    osascript -e 'with timeout of 5 seconds' -e 'tell application id "com.sunkanwei.Meno" to quit' \
        -e 'end timeout' >/dev/null 2>&1 || true
    if wait_for_process stopped; then return 0; fi
    pids="$(installed_pids)" || return 1
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
    done
    wait_for_process stopped
}

launch_installed_app() {
    open "$INSTALL" && wait_for_process running
}

rollback_on_failure() {
    local status=$? failed_dir="$BACKUP_ROOT/failed-$STAMP" reloaded=1
    trap - EXIT INT TERM
    [ "$status" -ne 0 ] || return 0
    echo "ERROR: Replacement failed; restoring the previous installation." >&2
    quit_installed_app || fail "Failed candidate is still running. Backup: ${BACKUP_DIR:-<none>}"
    if [ -e "$INSTALL" ]; then
        [ ! -e "$failed_dir/Meno.app" ] || fail "Failed candidate destination already exists. Backup: ${BACKUP_DIR:-<none>}"
        mkdir -p "$failed_dir" && mv "$INSTALL" "$failed_dir/Meno.app" \
            || fail "Could not move the failed install aside. Backup: ${BACKUP_DIR:-<none>}"
        echo "Failed candidate moved to $failed_dir/Meno.app"
    fi
    if [ -n "$BACKUP_DIR" ]; then
        mv "$BACKUP_DIR/Meno.app" "$INSTALL" || fail "Could not restore $BACKUP_DIR/Meno.app."
    fi
    "$SCRIPT_DIR/clean-ext.sh" --reload || reloaded=0
    if [ -n "$BACKUP_DIR" ]; then
        verify_bundle "$INSTALL" "Restored app" && launch_installed_app \
            || fail "Previous app restored but verification or relaunch failed."
        rmdir "$BACKUP_DIR" || true
        echo "Restored and relaunched the previous version from $INSTALL"
    fi
    [ "$reloaded" -eq 1 ] || fail "Extension reload after rollback failed."
    exit "$status"
}

quit_installed_app || fail "The installed Meno did not quit; no replacement was made."

# 4. Move the old version to a timestamped backup, then install the new one.
BACKUP_DIR=""
if [ -d "$INSTALL" ]; then
    BACKUP_DIR="$BACKUP_ROOT/Meno-$STAMP"
    [ ! -e "$BACKUP_DIR/Meno.app" ] || fail "Backup already exists: $BACKUP_DIR/Meno.app"
    mkdir -p "$BACKUP_DIR"
    mv "$INSTALL" "$BACKUP_DIR/Meno.app"
    echo "Previous version moved to $BACKUP_DIR/Meno.app"
fi
trap rollback_on_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$PRODUCT" "$INSTALL" || fail "Could not copy the candidate into $INSTALL."
verify_bundle "$INSTALL" "Installed app" || fail "Installation verification failed."
"$SCRIPT_DIR/clean-ext.sh" --reload
launch_installed_app || fail "Meno did not start from the fixed installation path."
trap - EXIT INT TERM

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

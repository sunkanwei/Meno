#!/bin/bash
# Keep only the fixed /Applications registration of Meno's system extensions.
#
# Any build that produces Meno.app or an .appex can make the system register a
# temporary extension pointing at a build directory. This script:
#   - removes pluginkit registrations that do not point at /Applications/Meno.app
#   - kills extension processes running from non-fixed paths
#   - re-registers the fixed install copy when it exists, with the expected
#     bundle id and signature
#   - restarts Finder only when something actually changed
#   - finally asserts that nothing is registered outside the fixed install and
#     that the fixed copy (when present) is registered
#
# With --reload (used after installing a new build): also kills extension
# processes from the fixed path so the new version gets loaded, and always
# restarts Finder.
set -euo pipefail

FIXED_APP="/Applications/Meno.app"
EXPECTED_AUTH="Meno Local Development"
FINDER_EXT_ID="com.sunkanwei.Meno.FinderExtension"
PREVIEW_EXT_ID="com.sunkanwei.Meno.MarkdownPreview"
RELOAD=0
CHANGED=0
STATE_OK=1

case "${1:-}" in
    "") ;;
    --reload) RELOAD=1 ;;
    *) echo "Usage: $0 [--reload]" >&2; exit 2 ;;
esac

registered_paths() {
    pluginkit -m -A -D -v -i "$1" 2>/dev/null \
        | awk -F'\t' '$1 ~ /com\.sunkanwei\.Meno/ {print $NF}'
}

clean_extension() {
    local id="$1" appex_name="$2"
    local fixed_path="$FIXED_APP/Contents/PlugIns/$appex_name"
    local path

    while IFS= read -r path; do
        [ -z "$path" ] && continue
        case "$path" in
            "$FIXED_APP"/*) ;;
            *)
                echo "Removing stale $id registration: $path"
                pluginkit -r "$path" >/dev/null 2>&1 || true
                CHANGED=1
                ;;
        esac
    done < <(registered_paths "$id")

    if [ -d "$fixed_path" ]; then
        local actual_id auth
        actual_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$fixed_path/Contents/Info.plist" 2>/dev/null)"
        auth="$(codesign -dvvv "$fixed_path" 2>&1 | awk -F= '/^Authority=/ {value = $2} END {print value}')"
        if [ "$actual_id" != "$id" ] || [ "$auth" != "$EXPECTED_AUTH" ]; then
            echo "ERROR: $fixed_path has bundle id '$actual_id' signed by '$auth', expected '$id' signed by '$EXPECTED_AUTH'; not registering." >&2
            exit 1
        fi
        pluginkit -a "$fixed_path" >/dev/null 2>&1 || true
    fi
}

check_extension_state() {
    local id="$1" appex_name="$2"
    local fixed_path="$FIXED_APP/Contents/PlugIns/$appex_name"
    local path found_fixed=0

    while IFS= read -r path; do
        [ -z "$path" ] && continue
        case "$path" in
            "$fixed_path") found_fixed=1 ;;
            "$FIXED_APP"/*) ;;
            *)
                echo "ERROR: $id still registered from non-fixed path: $path" >&2
                STATE_OK=0
                ;;
        esac
    done < <(registered_paths "$id")

    if [ -d "$fixed_path" ] && [ "$found_fixed" = 0 ]; then
        echo "ERROR: $id is not registered from the fixed install." >&2
        STATE_OK=0
    fi
}

clean_extension "$FINDER_EXT_ID" "MenoFinderExtension.appex"
clean_extension "$PREVIEW_EXT_ID" "MenoMarkdownPreview.appex"

# Kill extension processes from non-fixed paths; with --reload, kill all.
while IFS= read -r line; do
    pid="${line%% *}"
    comm="${line#* }"
    case "$comm" in
        *MenoFinderExtension.appex/*|*MenoMarkdownPreview.appex/*)
            case "$comm" in
                "$FIXED_APP"/*)
                    if [ "$RELOAD" = 1 ]; then
                        kill "$pid" 2>/dev/null || true
                    fi
                    ;;
                *)
                    echo "Killing extension process from non-fixed path: $comm (pid $pid)"
                    kill "$pid" 2>/dev/null || true
                    CHANGED=1
                    ;;
            esac
            ;;
    esac
done < <(ps -axo pid=,comm= | sed 's/^ *//')

if [ "$CHANGED" = 1 ] || [ "$RELOAD" = 1 ]; then
    killall Finder 2>/dev/null || true
    echo "Finder restarted."
fi

check_extension_state "$FINDER_EXT_ID" "MenoFinderExtension.appex"
check_extension_state "$PREVIEW_EXT_ID" "MenoMarkdownPreview.appex"
[ "$STATE_OK" = 1 ] || exit 1

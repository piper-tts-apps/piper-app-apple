#!/usr/bin/env bash
set -euo pipefail

if [ -d fastlane/metadata ]; then
  DEFAULT_LANGS=$(ls -1 fastlane/metadata | tr '\n' ' ')
else
  DEFAULT_LANGS="en-US"
fi
LANGUAGES=${LANGUAGES:-$DEFAULT_LANGS}

CACHE_BASE="$HOME/Library/Caches/tools.fastlane"
CACHE_SCREENSHOTS="$CACHE_BASE/screenshots"
OUTPUT_BASE="fastlane/screenshots/macos"
DERIVED_DATA="/tmp/snapshot_derived_macos"

# --- Clean-desktop prep -------------------------------------------------------
# Screenshot runs capture the whole desktop, so hide everything personal for
# the duration of the run: desktop icons, desktop widgets and the Dock, plus
# other apps' windows. The original value of every setting is recorded first
# and restored on exit (success, failure or Ctrl-C) via an EXIT trap, so a
# screenshot run never leaves the desktop in the staged state.
DESKTOP_PREP_ACTIVE=0
ORIG_CREATE_DESKTOP="absent"
ORIG_HIDE_WIDGETS="absent"
ORIG_DOCK_AUTOHIDE="absent"

read_default() {
  # $1 = domain, $2 = key; prints the value, or "absent" when the key is unset
  local value
  if value=$(defaults read "$1" "$2" 2>/dev/null); then
    echo "$value"
  else
    echo "absent"
  fi
}

restore_default() {
  # $1 = domain, $2 = key, $3 = original value ("absent" deletes the key)
  local bool_value
  if [ "$3" = "absent" ]; then
    defaults delete "$1" "$2" 2>/dev/null || true
  else
    if [ "$3" = "1" ]; then bool_value=true; else bool_value=false; fi
    defaults write "$1" "$2" -bool "$bool_value" 2>/dev/null || true
  fi
}

hide_other_apps() {
  # Best effort: needs Automation permission for the hosting terminal, and
  # osascript blocks until a first-time permission prompt is answered, so
  # run it in the background and give up after 10 seconds rather than
  # stalling the whole run. Skipped silently where it cannot work (e.g. CI,
  # where the desktop is clean anyway).
  osascript >/dev/null 2>&1 <<'APPLESCRIPT' &
tell application "System Events"
  set visible of every process whose name is not in {"Piper", "Screenshots-Runner", "System Events"} to false
end tell
APPLESCRIPT
  local osa_pid=$!
  local waited=0
  while kill -0 "$osa_pid" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  kill "$osa_pid" 2>/dev/null || true
  wait "$osa_pid" 2>/dev/null || true
}

restore_desktop() {
  if [ "$DESKTOP_PREP_ACTIVE" = "1" ]; then
    echo "→ Restoring desktop settings"
    restore_default com.apple.finder CreateDesktop "$ORIG_CREATE_DESKTOP"
    restore_default com.apple.WindowManager StandardHideWidgets "$ORIG_HIDE_WIDGETS"
    restore_default com.apple.dock autohide "$ORIG_DOCK_AUTOHIDE"
    killall Finder 2>/dev/null || true
    killall Dock 2>/dev/null || true
    DESKTOP_PREP_ACTIVE=0
  fi
}

prepare_desktop() {
  ORIG_CREATE_DESKTOP=$(read_default com.apple.finder CreateDesktop)
  ORIG_HIDE_WIDGETS=$(read_default com.apple.WindowManager StandardHideWidgets)
  ORIG_DOCK_AUTOHIDE=$(read_default com.apple.dock autohide)
  DESKTOP_PREP_ACTIVE=1
  trap restore_desktop EXIT
  echo "→ Hiding desktop icons, widgets, Dock and other apps for screenshots"
  defaults write com.apple.finder CreateDesktop -bool false
  defaults write com.apple.WindowManager StandardHideWidgets -bool true
  defaults write com.apple.dock autohide -bool true
  killall Finder 2>/dev/null || true
  killall Dock 2>/dev/null || true
  hide_other_apps
}
# --- End clean-desktop prep ---------------------------------------------------

# --- Upload-ready post-processing ---------------------------------------------
# XCUIScreen captures the whole desktop, so the raw PNGs come out at display
# size (e.g. 1920x1080), which App Store Connect rejects for Mac screenshots
# (valid sizes: 1280x800, 1440x900, 2560x1600, 2880x1800). Scale each capture
# to height 800 keeping its aspect ratio, then centre-crop to exactly
# 1280x800, in place - so the files this script leaves in the output folder
# are upload-ready as-is and no separate resize step is needed.
process_screenshots() {
  local dir="$1"
  local f tmp w h nw
  for f in "$dir"/*.png; do
    [ -e "$f" ] || continue
    w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/ {print $2}')
    h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/ {print $2}')
    nw=$(awk -v w="$w" -v h="$h" 'BEGIN { printf "%d", (w * 800 / h) + 0.5 }')
    tmp="$f.processing.png"
    sips -z 800 "$nw" "$f" --out "$tmp" >/dev/null
    mv "$tmp" "$f"
    sips -c 800 1280 "$f" --out "$tmp" >/dev/null
    mv "$tmp" "$f"
    w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/ {print $2}')
    h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/ {print $2}')
    echo "    $(basename "$f") → ${w}x${h}"
    if [ "$w" != "1280" ] || [ "$h" != "800" ]; then
      echo "    ERROR: expected 1280x800 after processing, got ${w}x${h} for $f" >&2
      exit 1
    fi
  done
}
# --- End upload-ready post-processing -----------------------------------------

# Smart arch detection – M4 (arm64) vs old Intel mini (x86_64) vs Rosetta
HOST_ARCH=$(uname -m)
if [[ "$HOST_ARCH" == "arm64" ]]; then
  MAC_ARCH=arm64
else
  MAC_ARCH=x86_64
fi
echo "→ Host arch: $HOST_ARCH → using destination arch=$MAC_ARCH"

echo "→ Languages (from fastlane/metadata): $LANGUAGES"
echo "→ Cleaning test_output + screenshots"
rm -rf fastlane/test_output
mkdir -p fastlane/test_output
rm -rf "$CACHE_SCREENSHOTS"
mkdir -p "$CACHE_SCREENSHOTS"
rm -rf "$OUTPUT_BASE"
mkdir -p "$OUTPUT_BASE"
mkdir -p "$CACHE_BASE"

prepare_desktop

# One-time build – avoids rebuilding Piper + SwiftLint for each language
# FASTLANE_SNAPSHOT=YES makes Project.swift skip SwiftLint phases (speedup)
export FASTLANE_SNAPSHOT=YES
echo "→ Building Screenshots scheme once for macOS (no code signing)"
xcodebuild build-for-testing \
  -workspace Piper.xcworkspace \
  -scheme Screenshots \
  -destination "platform=macOS,arch=$MAC_ARCH" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

for LANG in $LANGUAGES; do
  echo ""
  echo "=== $LANG ==="
  mkdir -p "$CACHE_SCREENSHOTS"
  echo "$LANG" > "$CACHE_BASE/language.txt"
  echo "$LANG" > "$CACHE_BASE/locale.txt"
  echo "  LANG=$LANG locale=$LANG (RTL if ar-SA / ur-PK – system mirrors SwiftUI automatically)"
  mkdir -p "$OUTPUT_BASE/$LANG"
  rm -rf "fastlane/test_output/macos-screenshots-$LANG.xcresult" || true
  rm -f "$CACHE_SCREENSHOTS"/*.png || true

  xcodebuild test-without-building \
    -workspace Piper.xcworkspace \
    -scheme Screenshots \
    -destination "platform=macOS,arch=$MAC_ARCH" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "fastlane/test_output/macos-screenshots-$LANG.xcresult" \
    CODE_SIGNING_ALLOWED=NO

  if [ -d "$CACHE_SCREENSHOTS" ]; then
    count=0
    for f in "$CACHE_SCREENSHOTS"/*.png; do
      [ -e "$f" ] || continue
      cp "$f" "$OUTPUT_BASE/$LANG"/
      count=$((count+1))
    done
    echo "  → $count files → $OUTPUT_BASE/$LANG"
    process_screenshots "$OUTPUT_BASE/$LANG"
  fi
done

ls -R "$OUTPUT_BASE" || true

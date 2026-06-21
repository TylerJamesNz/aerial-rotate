#!/bin/bash
# Detached helper. Waits for the parent app to exit, swaps the .app bundle in
# place from the freshly-downloaded .zip, and relaunches. Bundled inside the
# app at Contents/Resources/install-update.sh; the Swift side copies a
# self-contained copy into ~/Library/Application Support/aerial-rotate/update-staging/
# BEFORE quitting so this script survives the bundle swap it performs.
#
# Args:
#   $1  <zip-path>            absolute path to AerialRotate-vX.zip in the staging dir
#   $2  <target-bundle-path>  absolute path of the running bundle to replace
#   $3  <parent-pid>          PID of the running app, polled until it exits
#
# The daemon script ships as a separate release asset; if this release includes
# a daemon change, the parent app already prompted for sudo via osascript
# BEFORE calling NSApp.terminate, so this script has no daemon work to do.
set -e

ZIP="$1"
TARGET="$2"
PARENT="$3"

while kill -0 "$PARENT" 2>/dev/null; do sleep 0.1; done

TMP=$(mktemp -d)
unzip -q "$ZIP" -d "$TMP"

# Strip quarantine on the staged bundle so a future macOS that adds the xattr
# to URLSession downloads still launches clean. The `|| true` keeps a missing
# xattr from aborting the swap.
xattr -dr com.apple.quarantine "$TMP/AerialRotate.app" 2>/dev/null || true

rm -rf "$TARGET"
mv "$TMP/AerialRotate.app" "$TARGET"

open "$TARGET"
rm -f "$ZIP"
rmdir "$TMP" 2>/dev/null || true

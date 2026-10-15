#!/usr/bin/env bash
# BLE watch-sync debug harness.
#
# Lets an agent (or developer) drive a full watch-sync debug session from the
# command line: build the dev debug APK, install it, grant BLE permissions,
# seed the auto-sync trigger file, launch the app, and watch for the result.
#
# Usage: scripts/ble-debug.sh <command>
#   build     build the dev debug APK (flutter build apk --debug --flavor dev)
#   install   install the APK on the connected phone (adb install -r)
#   grant     grant BLE runtime permissions (no dialogs)
#   seed      write the auto-sync trigger file (run-as); optional JSON via stdin
#   unseed    delete the trigger file if present
#   launch    launch the app
#   logcat    dump recent MontBLE / flutter log lines
#   result    print the last session result file (ble_last_result.json)
#   session   seed + logcat -c + launch + wait for BLE_SYNC_RESULT (or timeout)
#
# Requirements: adb + flutter on PATH, one connected Android device, and the
# backend running with MONT_BLE_ENABLED=true reachable at localhost:8080
# (adb reverse tcp:8080 tcp:8080 is set up by `session`).
set -euo pipefail

PKG="eu.matmoa.mont.dev"
ACTIVITY="eu.matmoa.mont.dev/eu.matmoa.mont.MainActivity"
APK="flutter/build/app/outputs/flutter-apk/app-dev-debug.apk"
TRIGGER="app_flutter/ble_auto.json"
RESULT="app_flutter/ble_last_result.json"
SESSION_TIMEOUT="${SESSION_TIMEOUT:-240}"

adb_shell() { adb shell "$@"; }

require_device() {
  if ! adb devices | awk 'NR>1 && $2=="device" {print $1}' | grep -q .; then
    echo "error: no adb device authorized" >&2
    exit 1
  fi
}

cmd_build() {
  (cd flutter && flutter build apk --debug --flavor dev)
}

cmd_install() {
  require_device
  adb install -r "$APK"
}

cmd_grant() {
  require_device
  for perm in android.permission.BLUETOOTH_SCAN \
              android.permission.BLUETOOTH_CONNECT \
              android.permission.ACCESS_FINE_LOCATION; do
    adb_shell pm grant "$PKG" "$perm" 2>/dev/null || true
  done
  echo "permissions granted"
}

cmd_seed() {
  require_device
  local body
  body="${1:-$(cat)}"
  adb_shell "run-as $PKG sh -c 'mkdir -p app_flutter && cat > $TRIGGER'" <<<"$body"
  echo "trigger seeded"
}

cmd_unseed() {
  require_device
  adb_shell "run-as $PKG sh -c 'rm -f $TRIGGER'" || true
  echo "trigger removed"
}

cmd_launch() {
  require_device
  adb_shell am start -n "$ACTIVITY" >/dev/null
  echo "app launched"
}

cmd_logcat() {
  adb logcat -d -v time | grep -E "MontBLE|BLE_SYNC_RESULT|flutter" | tail -80 || true
}

cmd_result() {
  require_device
  adb_shell "run-as $PKG cat $RESULT" 2>/dev/null || echo "no result file yet"
}

cmd_session() {
  require_device
  adb reverse tcp:8080 tcp:8080
  local body="${1:-{\"timeout_s\":$SESSION_TIMEOUT}}"
  cmd_seed "$body" >/dev/null
  adb logcat -c
  cmd_launch >/dev/null
  echo "waiting up to ${SESSION_TIMEOUT}s for BLE_SYNC_RESULT..."
  local deadline=$((SECONDS + SESSION_TIMEOUT + 20))
  until adb logcat -d | grep -q "BLE_SYNC_RESULT"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "TIMED OUT waiting for result; recent logcat:"
      cmd_logcat
      exit 1
    fi
    sleep 3
  done
  adb logcat -d | grep "BLE_SYNC_RESULT" | tail -1
}

case "${1:-}" in
  build)   cmd_build ;;
  install) cmd_install ;;
  grant)   cmd_grant ;;
  seed)    cmd_seed "${2:-}" ;;
  unseed)  cmd_unseed ;;
  launch)  cmd_launch ;;
  logcat)  cmd_logcat ;;
  result)  cmd_result ;;
  session) cmd_session "${2:-}" ;;
  *)
    grep '^#   ' "$0" | sed 's/^#   //'
    exit 1
    ;;
esac

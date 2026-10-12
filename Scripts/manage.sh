#!/opt/homebrew/bin/bash
# Build, package, and run MeetCallRecorder.
#
# Signed with a local self-signed identity (setup-signing-identity.sh),
# not ad-hoc (-s -) - ad-hoc hashes the binary itself, so every rebuild
# would be a "new" identity to TCC and silently lose the Screen Recording
# grant. A real identity (even self-signed) stays stable across rebuilds.
#
# Autostart is *not* handled here any more. The app registers itself as a
# login item via SMAppService from the welcome screen's "Start at login"
# checkbox (see Sources/MeetCallRecorder/LaunchAtLogin.swift), so it shows
# up under System Settings > General > Login Items and can be turned off
# there. This script used to write a LaunchAgent plist as well, which meant
# two independent owners of the same autostart state: the checkbox could
# read "off" while launchd kept starting the app regardless. `migrate`
# below clears out any leftover from that arrangement.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="MeetCallRecorder"
BUNDLE_ID="dev.kriakiku.MeetCallRecorder"
APP_BUNDLE="${REPO_DIR}/${APP_NAME}.app"
LEGACY_LAUNCH_AGENT="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
SIGNING_IDENTITY="MeetCallRecorder Local Dev"
BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

build() {
  "${SCRIPT_DIR}/setup-signing-identity.sh"
  echo "==> Building (release)..."
  swift build -c release --package-path "$REPO_DIR"
  echo "==> Packaging ${APP_NAME}.app..."
  rm -rf "$APP_BUNDLE"
  mkdir -p "${APP_BUNDLE}/Contents/MacOS"
  cp "${REPO_DIR}/.build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"
  cp "${SCRIPT_DIR}/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
  # Copied by hand rather than declared in Package.swift: SwiftPM would
  # put them in a MeetCallRecorder_MeetCallRecorder.bundle next to the
  # executable, which is not where Bundle.main looks. Contents/Resources
  # is, and this bundle is assembled here anyway.
  mkdir -p "${APP_BUNDLE}/Contents/Resources"
  cp -R "${REPO_DIR}/Resources/." "${APP_BUNDLE}/Contents/Resources/"
  codesign --force --deep -s "$SIGNING_IDENTITY" "$APP_BUNDLE"
  echo "==> Built: ${APP_BUNDLE}"
}

# Removes the LaunchAgent earlier versions installed. Harmless to re-run.
migrate() {
  if [[ -f "$LEGACY_LAUNCH_AGENT" ]] || launchctl print "gui/$(id -u)/${BUNDLE_ID}" >/dev/null 2>&1; then
    echo "==> Removing the old LaunchAgent (autostart is the app's own checkbox now)..."
    launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || true
    rm -f "$LEGACY_LAUNCH_AGENT"
  fi
}

start() {
  [[ -x "$BINARY" ]] || { echo "No build at ${APP_BUNDLE} - run '$0 build' first." >&2; exit 1; }
  echo "==> Starting ${APP_NAME}..."
  open "$APP_BUNDLE"
}

# `open` returns before the app is gone on the way out too, and a quick
# stop-then-start can otherwise leave two instances both detecting the
# same call and both recording it. Wait for the PID to actually disappear.
stop() {
  pkill -f "$BINARY" 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -f "$BINARY" >/dev/null 2>&1 || return 0
    sleep 0.5
  done
  echo "    still running after SIGTERM - force killing"
  pkill -9 -f "$BINARY" 2>/dev/null || true
}

install() {
  migrate
  build
  stop
  start
  echo "==> Installed and started."
  echo "    The welcome screen will ask for Screen Recording and offer to"
  echo "    start the app at login. Granting Screen Recording needs one"
  echo "    relaunch - the screen has a button for it."
}

status() {
  local pid
  pid="$(pgrep -f "$BINARY" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    echo "running (pid ${pid})"
  else
    echo "not running"
  fi
  # SMAppService has no read-only CLI, and the `application.<bundle-id>.*`
  # job in `launchctl list` is just the running app, not its login-item
  # registration - it's there either way. The app logs the real status at
  # every launch instead; this reads back the most recent one.
  local reported
  reported="$(grep "launch at login:" "${HOME}/Library/Logs/${APP_NAME}.log" 2>/dev/null | tail -1 || true)"
  if [[ -n "$reported" ]]; then
    echo "login item (as of ${reported%%]*}]): ${reported##*launch at login: }"
  else
    echo "login item: unknown - start the app once"
  fi
}

logs() { tail -f "${HOME}/Library/Logs/${APP_NAME}.log"; }

uninstall() {
  stop
  migrate
  echo "==> Stopped. Remove the login item under System Settings > General >"
  echo "    Login Items, then delete ${APP_BUNDLE} if you're done with it."
}

case "${1:-}" in
  build) build ;;
  install) install ;;
  migrate) migrate ;;
  update) stop; build; start ;;
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  logs) logs ;;
  uninstall) uninstall ;;
  *)
    echo "Usage: $0 {build|install|update|start|stop|restart|status|logs|migrate|uninstall}"
    exit 1
    ;;
esac

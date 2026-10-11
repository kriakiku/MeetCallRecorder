#!/opt/homebrew/bin/bash
# Build, package, and (un)install MeetCallRecorder as a per-user login item.
#
# Ad-hoc codesign (-s -) hashes the binary itself, so every rebuild is a
# "new" identity to TCC - after `build`/`install`, macOS may silently stop
# granting Screen Recording even though System Settings still shows it
# enabled. If detection stops working after a rebuild, toggle it off/on in
# System Settings > Privacy & Security > Screen Recording.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="MeetCallRecorder"
BUNDLE_ID="dev.kriakiku.MeetCallRecorder"
APP_BUNDLE="${REPO_DIR}/${APP_NAME}.app"
LAUNCH_AGENT_LABEL="${BUNDLE_ID}"
LAUNCH_AGENT_PLIST="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

build() {
  echo "==> Building (release)..."
  swift build -c release --package-path "$REPO_DIR"
  echo "==> Packaging ${APP_NAME}.app..."
  rm -rf "$APP_BUNDLE"
  mkdir -p "${APP_BUNDLE}/Contents/MacOS"
  cp "${REPO_DIR}/.build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"
  cp "${SCRIPT_DIR}/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
  codesign --force --deep -s - "$APP_BUNDLE"
  echo "==> Built: ${APP_BUNDLE}"
}

install() {
  build
  echo "==> Writing LaunchAgent -> ${LAUNCH_AGENT_PLIST}"
  sed "s#__APP_PATH__#${APP_BUNDLE}#g; s#__LABEL__#${LAUNCH_AGENT_LABEL}#g" \
    "${SCRIPT_DIR}/dev.kriakiku.MeetCallRecorder.plist.template" > "$LAUNCH_AGENT_PLIST"
  if launchctl print "gui/$(id -u)/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/${LAUNCH_AGENT_LABEL}" 2>/dev/null || true
    sleep 1
  fi
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST"
  echo "==> Installed and started."
  echo "    If this is the first install, open the app once manually and grant"
  echo "    Screen Recording when prompted (System Settings > Privacy & Security)."
}

start() { launchctl kickstart -k "gui/$(id -u)/${LAUNCH_AGENT_LABEL}"; }
stop() { launchctl bootout "gui/$(id -u)/${LAUNCH_AGENT_LABEL}" 2>/dev/null || true; }
restart() { stop; sleep 1; launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST"; }

status() {
  launchctl print "gui/$(id -u)/${LAUNCH_AGENT_LABEL}" 2>&1 | grep -E "state|pid" || echo "not loaded"
}

logs() { tail -f "${HOME}/Library/Logs/${APP_NAME}.log"; }

uninstall() {
  stop
  rm -f "$LAUNCH_AGENT_PLIST"
  echo "==> Uninstalled LaunchAgent. App bundle left at ${APP_BUNDLE} - delete manually if desired."
}

case "${1:-}" in
  build) build ;;
  install) install ;;
  update) stop; build; start ;;
  start) start ;;
  stop) stop ;;
  restart) restart ;;
  status) status ;;
  logs) logs ;;
  uninstall) uninstall ;;
  *)
    echo "Usage: $0 {build|install|update|start|stop|restart|status|logs|uninstall}"
    exit 1
    ;;
esac

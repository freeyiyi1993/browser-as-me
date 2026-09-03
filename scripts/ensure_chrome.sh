#!/usr/bin/env bash
# Ensure the dedicated CDP Chrome is alive and 9222 responds.
# Exit 0 if up, exit 1 if cannot bring up.
set -euo pipefail

LABEL="${CDP_CHROME_LABEL:-com.local.chrome-cdp}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
PORT=9222
PROFILE="${CDP_CHROME_PROFILE:-Default}"
APP="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
USER_DATA_DIR="$HOME/.chrome-cdp-profile"

check_cdp() {
    curl -sf "http://localhost:${PORT}/json/version" > /dev/null 2>&1
}

cdp_processes() {
    pgrep -f "^${APP} .*--remote-debugging-port=${PORT}" || true
}

current_process_uses_preferred_profile() {
    local pid cmd

    pid=$(cdp_processes | head -n 1)
    [[ -n "$pid" ]] || return 1

    cmd=$(ps -p "$pid" -o command=)
    grep -F -- "--user-data-dir=${USER_DATA_DIR}" <<<"$cmd" >/dev/null &&
        grep -F -- "--profile-directory=${PROFILE}" <<<"$cmd" >/dev/null
}

stop_cdp() {
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    launchctl kill SIGTERM "gui/$(id -u)/${LABEL}" 2>/dev/null || true

    for _ in 1 2 3 4 5; do
        cdp_processes | grep -q . || return 0
        sleep 1
    done

    cdp_processes | xargs kill 2>/dev/null || true
}

if check_cdp; then
    if current_process_uses_preferred_profile; then
        echo "CDP up on :${PORT} (${PROFILE})"
        exit 0
    fi
    echo "CDP is up but not using profile ${PROFILE}; restarting..." >&2
    stop_cdp
fi

echo "CDP not responding, kickstarting LaunchAgent..."

# Avoid Apple Events by default. On recent macOS versions, terminal-hosted
# osascript calls can trigger "access data from other apps" TCC prompts.
RESTORE_FOCUS="${BROWSER_AS_ME_RESTORE_FOCUS:-0}"
FRONT_BID=""
if [[ "$RESTORE_FOCUS" == "1" ]]; then
    FRONT_BID=$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null || true)
fi

if ! launchctl print "gui/$(id -u)/${LABEL}" > /dev/null 2>&1; then
    echo "LaunchAgent not loaded, bootstrapping..."
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi
launchctl kickstart -k "gui/$(id -u)/${LABEL}"

restore_focus() {
    if [[ "$RESTORE_FOCUS" == "1" && -n "${FRONT_BID:-}" && "$FRONT_BID" != "com.google.Chrome" ]]; then
        osascript -e "tell application id \"$FRONT_BID\" to activate" >/dev/null 2>&1 || true
    fi
}
trap restore_focus EXIT

for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if check_cdp; then
        echo "CDP up after ${i}s"
        exit 0
    fi
    sleep 1
done

echo "ERROR: CDP still down after 15s. Check /tmp/chrome-cdp.err.log" >&2
tail -10 /tmp/chrome-cdp.err.log >&2 2>/dev/null || true
exit 1

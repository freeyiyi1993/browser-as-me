#!/usr/bin/env bash
# Ensure the dedicated CDP Chrome is alive and 9222 responds.
# Exit 0 if up, exit 1 if cannot bring up.
set -euo pipefail

LABEL="${CDP_CHROME_LABEL:-com.local.chrome-cdp}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
PORT=9222

check_cdp() {
    curl -sf "http://localhost:${PORT}/json/version" > /dev/null 2>&1
}

if check_cdp; then
    echo "CDP up on :${PORT}"
    exit 0
fi

echo "CDP not responding, kickstarting LaunchAgent..."

if ! launchctl print "gui/$(id -u)/${LABEL}" > /dev/null 2>&1; then
    echo "LaunchAgent not loaded, bootstrapping..."
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
else
    launchctl kickstart -k "gui/$(id -u)/${LABEL}"
fi

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

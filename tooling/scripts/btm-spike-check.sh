#!/bin/zsh
# BTM spike — step 2/3 (check). Run before AND after a reboot. Needs sudo for sfltool/launchctl.
set -uo pipefail

LABEL="eth.7amza.notchnerd.btmspike"
LOG="/Library/Application Support/NotchNerdBTMSpike/heartbeat.log"

echo "=== 1. BTM disposition (the load-bearing check) ==="
BTM=$(sudo sfltool dumpbtm 2>/dev/null | grep -A6 -i "btmspike\|NotchNerdBTMSpike" || true)
if [[ -z "$BTM" ]]; then
    echo "  (no BTM record found for the spike — note this; it may appear only post-reboot)"
else
    echo "$BTM" | sed 's/^/  /'
    if echo "$BTM" | grep -qi "disposition.*disabled\|disallowed"; then
        echo "  ⚠️  VERDICT LEANS: DISALLOWED — try the Login Items toggle, then re-run this check."
    fi
fi

echo "=== 2. Is the daemon actually loaded? ==="
if sudo launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    echo "  ✔ loaded in the system domain"
else
    echo "  ✘ NOT loaded"
fi

echo "=== 3. Is it actually running (fresh heartbeats)? ==="
if [[ -f "$LOG" ]]; then
    echo "  last 3 heartbeats:"; tail -3 "$LOG" | sed 's/^/    /'
    LAST=$(stat -f %m "$LOG"); NOW=$(date +%s)
    if (( NOW - LAST < 120 )); then
        echo "  ✔ heartbeat is FRESH (<2 min) — the ad-hoc daemon RUNS"
    else
        echo "  ✘ heartbeat is STALE ($(( (NOW - LAST) / 60 )) min old)"
    fi
else
    echo "  ✘ no heartbeat log at all — the daemon never ran"
fi

echo
echo "Interpretation: FRESH heartbeat after a reboot with no manual Login-Items rescue"
echo "= classic-daemon path viable (re-test once more after re-signing the binary — cdhash"
echo "churn may reset BTM trust). STALE/absent after reboot = keep-awake needs Developer ID."

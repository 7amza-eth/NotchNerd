#!/bin/zsh
# BTM spike — step 3/3 (uninstall). Removes everything the spike installed. One admin prompt.
set -euo pipefail

LABEL="eth.7amza.notchnerd.btmspike"

osascript -e "do shell script \"
    launchctl bootout system/${LABEL} 2>/dev/null || true; \
    rm -f '/Library/LaunchDaemons/${LABEL}.plist' /Library/PrivilegedHelperTools/NotchNerdBTMSpike; \
    rm -rf '/Library/Application Support/NotchNerdBTMSpike'
\" with administrator privileges"

echo "✔ Spike removed (daemon booted out, binary + plist + log dir deleted)."

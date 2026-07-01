#!/bin/zsh
# BTM spike — step 1/3 (install). See spec.md Part II → v0.4 "SIGNING GATE".
#
# Question this answers: does macOS Background Task Management allow an AD-HOC-signed
# root LaunchDaemon (installed the classic way, one admin prompt) to run on this machine —
# or does BTM mark it "disallowed" (the Nix-on-Tahoe failure)? The answer decides whether
# NotchNerd's keep-awake helper can ship without a Developer ID.
#
# What it does: compiles a trivial heartbeat daemon, ad-hoc signs it, and installs it to
# /Library/PrivilegedHelperTools + /Library/LaunchDaemons via ONE osascript admin prompt
# (the exact install UX keep-awake would use). It only appends timestamps to a log file.
#
# After running: btm-spike-check.sh → REBOOT → btm-spike-check.sh again → btm-spike-uninstall.sh
set -euo pipefail

LABEL="eth.7amza.notchnerd.btmspike"
BIN_DST="/Library/PrivilegedHelperTools/NotchNerdBTMSpike"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
LOG_DIR="/Library/Application Support/NotchNerdBTMSpike"
STAGE="$(mktemp -d)"

echo "→ Compiling the trivial heartbeat daemon…"
cat > "$STAGE/spike.c" <<'EOF'
#include <stdio.h>
#include <time.h>
#include <unistd.h>
int main(void) {
    for (;;) {
        FILE *f = fopen("/Library/Application Support/NotchNerdBTMSpike/heartbeat.log", "a");
        if (f) { time_t t = time(NULL); fprintf(f, "alive %s", ctime(&t)); fclose(f); }
        sleep(60);
    }
    return 0;
}
EOF
clang -o "$STAGE/NotchNerdBTMSpike" "$STAGE/spike.c"

echo "→ Ad-hoc signing (the posture under test)…"
codesign --force -s - --identifier "$LABEL" "$STAGE/NotchNerdBTMSpike"
codesign -dv "$STAGE/NotchNerdBTMSpike" 2>&1 | grep -E "Identifier|Signature" || true

cat > "$STAGE/${LABEL}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key><array><string>${BIN_DST}</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

# Strip any quarantine before it crosses into system dirs.
xattr -cr "$STAGE/NotchNerdBTMSpike" "$STAGE/${LABEL}.plist" 2>/dev/null || true

echo "→ Installing with ONE admin prompt (mkdir + copy + perms + bootstrap)…"
osascript -e "do shell script \"
    mkdir -p '$LOG_DIR' /Library/PrivilegedHelperTools && \
    cp '$STAGE/NotchNerdBTMSpike' '$BIN_DST' && \
    cp '$STAGE/${LABEL}.plist' '$PLIST_DST' && \
    chown root:wheel '$BIN_DST' '$PLIST_DST' && \
    chmod 755 '$BIN_DST' && chmod 644 '$PLIST_DST' && \
    launchctl bootstrap system '$PLIST_DST'
\" with administrator privileges"

echo
echo "✔ Installed. Now:"
echo "  1. zsh tooling/scripts/btm-spike-check.sh        # pre-reboot disposition"
echo "  2. Reboot."
echo "  3. zsh tooling/scripts/btm-spike-check.sh        # the verdict that matters"
echo "     (If DISALLOWED: System Settings → General → Login Items & Extensions —"
echo "      look for an 'unidentified developer' item, toggle it ON, re-check.)"
echo "  4. zsh tooling/scripts/btm-spike-uninstall.sh    # when done"

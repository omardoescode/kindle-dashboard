#!/bin/sh
# Copy everything in this repo to the Kindle. Files that a running process may have open
# (scripts, fonts) go to NAME.new first and then replace NAME, so the process keeps the old copy.
set -e
cd "$(dirname "$0")"
K=mykindle
PLUG=/mnt/us/koreader/plugins/dashboard.koplugin

put() { # put LOCAL REMOTE
    scp -O -q "$1" "$K:$2.new"
    ssh "$K" "mv '$2.new' '$2'"
}

ssh "$K" "mkdir -p $PLUG/fonts /mnt/us/koreader/screensaver && rm -f $PLUG/dashboardwidget.lua"
for f in dashboard.koplugin/*.lua; do put "$f" "$PLUG/$(basename "$f")"; done
for f in dashboard.koplugin/fonts/*; do put "$f" "$PLUG/fonts/$(basename "$f")"; done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
python3 tools/quote_make.py dashboard.koplugin/fonts "$tmp/quote.png"
put "$tmp/quote.png" /mnt/us/koreader/screensaver/quote.png

# Our phoenix critter "Anqa" for Simple UI's Tiny Critter module (its folder name gives its name).
ANQA=/mnt/us/koreader/settings/simpleui/sui_critters/anqa
python3 -I tools/critter_phoenix.py tools/assets/phoenix-cc0-spritesheet.png "$tmp/anqa"
ssh "$K" "mkdir -p $ANQA"
for f in "$tmp"/anqa/*.png; do put "$f" "$ANQA/$(basename "$f")"; done

put kindle/mykindle-start.sh /mnt/us/koreader/mykindle-start.sh
put kindle/KOReader-NoUI.sh /mnt/us/documents/KOReader-NoUI.sh
ssh "$K" "chmod +x /mnt/us/koreader/mykindle-start.sh"

# The library "KOReader" tile (KPM package) also starts without the Amazon UI.
L=/mnt/us/kmc/kpm/packages/koreader
ssh "$K" "[ -e $L/launch.sh.orig ] || cp $L/launch.sh $L/launch.sh.orig"
put kindle/kpm-koreader-launch.sh $L/launch.sh

# Upstart jobs live on the read-only root: write it only when a job changed.
changed=""
for f in kindle/*.conf; do
    n=$(basename "$f")
    if [ "$(md5sum < "$f" | cut -d' ' -f1)" != "$(ssh "$K" "md5sum < /etc/upstart/$n 2>/dev/null" | cut -d' ' -f1)" ]; then
        scp -O -q "$f" "$K:/tmp/$n"
        changed="$changed $n"
    fi
done
if [ -n "$changed" ]; then
    ssh "$K" "mntroot rw && for n in $changed; do cp /tmp/\$n /etc/upstart/\$n; done; mntroot ro"
    echo "Upstart jobs changed:$changed (they take effect at the next start of each job or at reboot)"
fi

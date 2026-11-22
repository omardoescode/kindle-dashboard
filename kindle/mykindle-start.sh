#!/bin/sh
# Start KOReader without the Amazon UI, with on-screen progress.
# Usage: mykindle-start.sh [wait_seconds]  (a touch during the wait cancels the start)
FB=/mnt/us/koreader/fbink
READY=/var/run/mykindle-ko-ready
TOUCH=/var/run/mykindle-touch
FONT=/mnt/us/koreader/plugins/dashboard.koplugin/fonts/IBMPlexSans-SemiBold.ttf
# say TOP_PX SIZE_PX TEXT: one centered line, its full row cleared first
# Touch controller IRQ count: it rises on a touch even when the Amazon UI grabs the input device.
touches() { awk '/ 2-0024$/ { s = 0; for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++) s += $i; print s }' /proc/interrupts; }
say() { $FB -q -m -t regular=$FONT,px=$2,top=$1,padding=FULL "$3"; }

# One KOReader at a time: two would share the screen and the input.
ps | grep -q "[r]eader.lua" && exit 0
# The old koreader.sh deletes /var/tmp/koreader.sh when it ends; if a new one has started by then,
# KOReader shows "startup script has been updated". Let the old one finish first.
i=0
while ps | grep -q "[k]oreader.sh" && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done

wait=${1:-0}
if [ "$wait" -gt 0 ]; then
    rm -f $TOUCH
    # Idle: +1 each ~2 s. A tap: about +10 in 0.2 s.
    prev=$(touches)
    touched() {
        cur=$(touches)
        [ $((cur - prev)) -ge 3 ] && echo "$prev -> $cur" >$TOUCH
        prev=$cur
        [ -s $TOUCH ]
    }
    n=$wait
    while [ $n -gt 0 ] && ! touched; do
        say -300 46 "Dashboard opens in $n s"
        say -235 36 "Touch the screen to stay in Kindle"
        i=0
        while [ $i -lt 4 ] && ! touched; do usleep 250000; i=$((i + 1)); done
        n=$((n - 1))
    done
    if [ -s $TOUCH ]; then
        say -300 46 "Staying in Kindle"
        say -235 36 " "
        exit 0
    fi
fi

rm -f $READY
cd /mnt/us/koreader && setsid ./koreader.sh --framework_stop </dev/null >/var/tmp/mykindle-ko.log 2>&1 &
i=0
while [ ! -e $READY ] && [ $i -lt 240 ]; do
    [ $((i % 4)) -eq 0 ] && say -300 46 "Starting dashboard ..." && say -235 36 " "
    $FB -q -y -3 -A $((i % 17))
    usleep 250000
    i=$((i + 1))
done

# The Amazon UI needs about a minute to draw after KOReader closes; until then the screen looks frozen.
# kill -0 is a shell builtin: no process list scan each time.
# KOReader's own restart (exit code 85) starts a new process: follow it.
while :; do
    ko=$(ps | awk '/[r]eader\.lua/ { print $1; exit }')
    [ -z "$ko" ] && break
    while kill -0 "$ko" 2>/dev/null; do sleep 3; done
    sleep 2
done
# If KOReader stopped without its exit hook, Amazon's lock screen stays unloaded until reboot.
lipc-set-prop com.lab126.blanket load ad_screensaver 2>/dev/null
$FB -q -c -f -m -t regular=$FONT,px=46,top=760,padding=FULL "Opening Kindle ..."
i=0
while [ $i -lt 480 ]; do
    [ -n "$(lipc-get-prop com.lab126.appmgrd activeApp 2>/dev/null)" ] && break
    [ $((i % 8)) -eq 7 ] && ps | grep -q "[r]eader.lua" && break
    [ $((i % 8)) -eq 0 ] && say 760 46 "Opening Kindle ..."
    $FB -q -y -3 -A $((i % 17))
    usleep 250000
    i=$((i + 1))
done

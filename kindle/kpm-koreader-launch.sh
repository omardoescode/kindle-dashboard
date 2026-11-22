#!/bin/sh
# mykindle: the library "KOReader" tile also starts KOReader without the Amazon UI.
# Installed over /mnt/us/kmc/kpm/packages/koreader/launch.sh (original kept as launch.sh.orig).
# A KPM update of KOReader puts the original back; install this file again then.
setsid /mnt/us/koreader/mykindle-start.sh </dev/null >/dev/null 2>&1 &

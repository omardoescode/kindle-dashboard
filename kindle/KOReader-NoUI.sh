#!/bin/sh
# Name: KOReader (no Amazon UI)
# Author: mykindle
cd /mnt/us/koreader && setsid ./koreader.sh --framework_stop </dev/null >/var/tmp/mykindle-ko.log 2>&1 &

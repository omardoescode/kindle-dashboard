#!/bin/sh
set -e
cd "$(dirname "$0")"
ssh mykindle 'mkdir -p /mnt/us/koreader/plugins/dashboard.koplugin/fonts'
scp -O dashboard.koplugin/*.lua mykindle:/mnt/us/koreader/plugins/dashboard.koplugin/
scp -O dashboard.koplugin/fonts/* mykindle:/mnt/us/koreader/plugins/dashboard.koplugin/fonts/
python3 tools/quote_make.py dashboard.koplugin/fonts /tmp/kindle-quote.png
ssh mykindle 'mkdir -p /mnt/us/koreader/screensaver'
scp -O /tmp/kindle-quote.png mykindle:/mnt/us/koreader/screensaver/quote.png

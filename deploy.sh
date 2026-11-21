#!/bin/sh
set -e
cd "$(dirname "$0")"
ssh mykindle 'mkdir -p /mnt/us/koreader/plugins/dashboard.koplugin/fonts'
scp -O dashboard.koplugin/*.lua mykindle:/mnt/us/koreader/plugins/dashboard.koplugin/
scp -O dashboard.koplugin/fonts/* mykindle:/mnt/us/koreader/plugins/dashboard.koplugin/fonts/

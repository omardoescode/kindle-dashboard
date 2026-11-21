# kindle-dashboard

KOReader plugin for a Kindle Paperwhite 12th gen: prayer times, clock, Hijri date and weather on one screen.

- Prayer times: computed on the device (PrayTimes algorithm). Checked against Aladhan within 1 minute.
- Weather and rain: Open-Meteo.
- Arabic font: Zain (OFL), in `dashboard.koplugin/fonts`.
- Design follows [kindil](https://github.com/sharno/kindil) (MIT).

Settings: `koreader/settings/dashboard.lua` (place, lat, lon, method, madhab, clock, hijri_offset, temperature_unit, autostart).

Deploy: `./deploy.sh` (needs `ssh mykindle`).

Test prayer math: `lua5.4 test/verify.lua <lat> <lon> <method> <y> <m> <d> <utc offset>`.

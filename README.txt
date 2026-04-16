# UAVPAL Disco 4G Generic Modem Compatibility (Field Snapshot)

Last validated: April 16, 2026

## Purpose
This repo contains the UAVPAL files proven on-aircraft for multi-modem compatibility (Huawei HiLink, Huawei stick mode, and generic Ethernet clones).

## Canonical Source
Files are synced from the aircraft backup at:
`C:\Users\autog\Desktop\1\_\uavpal`

## Included Files
- `bin/uavpal_disco.sh`
- `bin/uavpal_globalfunctions.sh`
- `bin/uavpal_glympse.sh`
- `bin/uavpal_unload.sh`
- `conf/70-huawei-e3372.rules`
- `conf/modem.conf` (new)

## What Changed
1. Profile-based modem handling (auto / huawei_hilink / huawei_stick / generic_ethernet / generic_ppp).
2. Better detection, serial/interface handling, safer unload/reconnect behavior.
3. Glympse telemetry fallback improvements:
- HiLink API path for supported routers.
- ZTE-style `/reqproc/proc_get` fallback for hostless clones.
- AT-command fallback for stick mode (`AT+CSQ`, with Huawei `AT^SYSINFO*` fallback logic).
4. Connection hardening in `uavpal_globalfunctions.sh`:
- separate modem-link vs internet checks,
- reconnect only after consecutive failures,
- reconnect backoff to reduce thrashing.

## Known Limitations
- Some Huawei stick variants return limited AT metadata; you may get `Cell/<percent>%` instead of explicit `4G/<percent>%`.
- HiLink API may require auth depending on firmware/web UI config.

## Deploy
Replace files on drone under `/data/ftp/uavpal/`, then:
- `chmod +x /data/ftp/uavpal/bin/uavpal_*.sh`
- restart glympse or reboot.

## Verify
- `cat /tmp/modem_connection_profile`
- `ulogcat -d | grep -i "uavpal_glympse.*updating Glympse label" | tail -n 15`
- `ulogcat -d | grep -i "uavpal_connection_handler_.*reconnecting" | tail -n 20`

## Rollback
Restore `*.bak` script backups on aircraft and reboot.

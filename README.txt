UAVPAL Disco 4G Generic Modem Compatibility + Improvements

Last validated: April 17, 2026

Purpose
- Add robust modem compatibility for:
  - Huawei HiLink
  - Huawei stick mode
  - Generic USB Ethernet/hostless modems
- Keep runtime auto-detection and safer reconnect behavior.

Canonical field snapshot
- C:\Users\autog\Desktop\1\_\uavpal

Naming note
- Files in this review bundle may use:
  - diff_*
  - NEW_*
- Before deployment, remove those prefixes.

Core files
1. diff_uavpal_disco.sh
2. diff_uavpal_globalfunctions.sh
3. diff_uavpal_unload.sh
4. diff_uavpal_glympse.sh
5. diff_70-huawei-e3372.rules
6. NEW_modem.conf

Change summary
1) diff_uavpal_disco.sh
- Profile-based startup: auto, huawei_hilink, huawei_stick, generic_ethernet, generic_ppp.
- Better auto-detection and Ethernet -> PPP fallback.
- Tracks active profile in /tmp/modem_connection_profile.
- Adds startup timeout guards:
  - modem_detect_timeout=300
  - internet_wait_timeout=300

2) diff_uavpal_globalfunctions.sh
- Added shared modem helpers (config loader, USB matching, iface/serial detection, modeswitch control).
- Stronger Ethernet/PPP connect paths and reconnect logic (transient tolerance + backoff).
- Added modem link checks separated from internet reachability checks.
- Added low-latency queue tuning:
  - MODEM_LOW_LATENCY_TXQLEN=100 default
  - Reduces oversized tx queues (does not increase small ones).
- Firewall hardening:
  - Uses dedicated UAVPAL_INPUT chain instead of repeated direct INPUT inserts.

3) diff_uavpal_unload.sh
- Safer unload for transient USB re-enumeration.
- Broader modem USB ID handling.
- Targeted firewall cleanup (UAVPAL_INPUT chain + legacy cleanup), no broad INPUT flush.

4) diff_uavpal_glympse.sh
- Better telemetry fallback order (HiLink API, generic API, Huawei API, serial AT fallbacks).
- Adds /reqproc/proc_get support for hostless clones.
- Improves Huawei stick telemetry fallback (SYSINFOEX -> COPS -> HCSQ, plus CSQ).
- Hardens loop behavior:
  - latency parse only when /tmp/sc2ping has valid content
  - waits on per-iteration curl/ping PIDs (no global curl process scan).

5) diff_70-huawei-e3372.rules
- udev trigger generalized from Huawei-only vendor match to usb_device events.
- Enables non-Huawei modem trigger path.

6) NEW_modem.conf
- Configurable modem profile and USB IDs (includes 19d2:*).
- Auto/manual iface and serial controls.
- Optional modeswitch and HiLink tuning knobs.
- Can override low-latency queue target (MODEM_LOW_LATENCY_TXQLEN) if needed.

Deploy
1. Upload files to /data/ftp/uavpal/ with runtime names (no diff_/NEW_ prefix).
2. Make scripts executable:
chmod +x /data/ftp/uavpal/bin/uavpal_disco.sh
chmod +x /data/ftp/uavpal/bin/uavpal_globalfunctions.sh
chmod +x /data/ftp/uavpal/bin/uavpal_unload.sh
chmod +x /data/ftp/uavpal/bin/uavpal_glympse.sh
3. Reboot:
reboot

Quick verification
- Profile:
cat /tmp/modem_connection_profile
- Glympse updates:
ulogcat -d | grep -i "uavpal_glympse.*updating Glympse label" | tail -n 15
- Reconnect flapping:
ulogcat -d | grep -i "uavpal_connection_handler_.*reconnecting" | tail -n 20
- Firewall chain:
iptables -L INPUT -n | grep UAVPAL_INPUT
iptables -L UAVPAL_INPUT -n

Rollback
- Restore previous .bak script copies and reboot.

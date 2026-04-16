UAVPAL Disco 4G Generic Modem Compatibility

Last validated: April 16, 2026

Purpose
This repo contains the UAVPAL modem compatibility changes that were tested on-aircraft for mixed modem types:
- Huawei HiLink
- Huawei stick mode
- Generic Ethernet hostless clones

Dynamic behavior is implemented by runtime detection/configuration, not by fixed AT^NDISDUP port assignment.

Important Naming Note
Files here are intentionally prefixed with diff_ and NEW_ for side-by-side review.

Before deploying to aircraft, remove those prefixes and use original runtime names.

Example:
- diff_uavpal_glympse.sh -> uavpal_glympse.sh
- NEW_modem.conf -> modem.conf

Canonical Source
Current field-working snapshot was pulled from:
C:\Users\autog\Desktop\1\_\uavpal

Included Files
1. diff_uavpal_disco.sh
2. diff_uavpal_globalfunctions.sh
3. diff_uavpal_unload.sh
4. diff_uavpal_glympse.sh
5. diff_70-huawei-e3372.rules
6. NEW_modem.conf

What Changed

1) diff_uavpal_disco.sh
- Reworked modem startup flow.
- Adds profile-based handling:
  - auto
  - huawei_hilink
  - huawei_stick
  - generic_ethernet
  - generic_ppp
- Improves auto-detection.
- Adds Ethernet -> PPP fallback.
- Tracks active modem profile in temp state.

2) diff_uavpal_globalfunctions.sh
- Adds shared modem helpers:
  - modem config loader
  - USB ID matching
  - usb_modeswitch control
  - interface and serial detection
- Strengthens Ethernet and PPP connect handling.
- Adds safer reconnect behavior across handlers:
  - separates local modem-link health from internet reachability
  - requires consecutive failures before reconnect
  - adds reconnect backoff (1s -> 2s -> 4s -> 8s, capped at 10s)
  - reduces reconnect thrash on transient packet loss
- Adds link checks:
  - Ethernet checks iface state and modem gateway reachability
  - Stick checks PPP iface health
- Tunes connection check timing to fail fast and recover faster.

3) diff_uavpal_unload.sh
- Safer unload/disconnect behavior.
- Avoids false unload during transient USB re-enumeration.
- Supports wider modem ID matching.
- Improves route/temp cleanup safety.

4) diff_uavpal_glympse.sh
- Improves telemetry source selection and fallback order.
- Safer serial control device handling.
- Adds generic Ethernet fallback via:
  /reqproc/proc_get (ZTE-style hostless API)
- Maps network_type + signalbar into label output (example: 4G/80%) when available.
- Improves Huawei stick fallback logic:
  - handles firmware that returns ERROR for AT^SYSINFOEX
  - RAT fallback chain:
    AT^SYSINFOEX -> AT+COPS? -> AT^HCSQ?
  - signal fallback:
    AT+CSQ -> percentage conversion
- Prevents permanent Cell/n/a where telemetry is available through fallback paths.

5) NEW_modem.conf
- New modem config defaults:
  - profile mode
  - accepted USB IDs (including 19d2:*)
  - iface/serial auto settings
  - optional modeswitch/HiLink tuning

6) diff_70-huawei-e3372.rules
- Changes udev trigger from Huawei-only to generic USB device events.
- Old trigger: ATTRS{idVendor}=="12d1"
- New trigger: SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device"
- Allows modem scripts to trigger for non-Huawei devices too.

TODO Coverage (from original uavpal_disco.sh)
- TODO: make ppp_if dynamic if possible
  - Addressed through modem.conf + config loading (MODEM_PPP_IFACE).

- TODO: make serial_ctrl_dev and serial_ppp_dev dynamic
  - Addressed through serial auto-discovery and PPP retry with swapped serial roles.

Deploy Steps (after review)
1. Remove diff_ / NEW_ prefixes from filenames.
2. Upload files to drone under /data/ftp/uavpal/ (same paths as originals).
3. Set executable bits:
chmod +x /data/ftp/uavpal/bin/uavpal_disco.sh
chmod +x /data/ftp/uavpal/bin/uavpal_globalfunctions.sh
chmod +x /data/ftp/uavpal/bin/uavpal_unload.sh
chmod +x /data/ftp/uavpal/bin/uavpal_glympse.sh

4. Restart glympse process or reboot:
for p in $(ps | grep '[u]avpal_glympse.sh' | awk '{print $1}'); do kill $p; done

/data/ftp/uavpal/bin/uavpal_glympse.sh </dev/null >/tmp/uavpal_glympse.manual.log 2>&1 &

5. Recommended for full handler reload:
reboot

Verification Commands
Check detected profile:
cat /tmp/modem_connection_profile

Check telemetry label output:
ulogcat -d | grep -i "uavpal_glympse.*updating Glympse label" | tail -n 15

Check reconnect-handler events:
ulogcat -d | grep -i "uavpal_connection_handler_.*reconnecting" | tail -n 20

Known Notes
- Some Huawei stick firmware variants expose limited AT metadata.
- In those cases, signal percentage may still be available while RAT may remain generic (Cell).
- HiLink APIs can return auth errors (125002) depending on firmware/login policy.

Rollback
Restore previous *.bak script copies on aircraft, then reboot.

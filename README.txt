UAVPAL Disco modem compatibility changes summary

1) diff_uavpal_disco.sh.txt
- Main modem startup flow rewrite: adds profile-based handling (auto/huawei_hilink/huawei_stick/generic_ethernet/generic_ppp), better auto-detection, Ethernet->PPP fallback, and connection profile tracking.

2) diff_uavpal_globalfunctions.sh.txt
- Adds shared modem helpers: config loader, USB ID matching, usb_modeswitch control, network/serial interface detection, stronger Ethernet/PPP connect handling, and keep-alive improvements.

3) diff_uavpal_unload.sh.txt
- Makes disconnect/unload safer: avoids false unload on transient re-enumeration, supports broader modem IDs, cleans routes/temp files more safely.

4) diff_uavpal_glympse.sh.txt
- Improves status reporting path selection (HiLink vs serial), safer serial device handling, and cleaner modem signal reporting fallback.
- Adds generic Ethernet modem API fallback via /reqproc/proc_get (ZTE-style hostless WebUI clones).
- Maps network_type + signalbar into Glympse label values (for example: 4G/80%) instead of Cell/n/a when serial and HiLink APIs are unavailable.

5) NEW_modem.conf
- New modem config file with defaults for profile mode, accepted USB IDs (including 19d2:*), iface/serial auto settings, and optional modeswitch/HiLink tuning.

6) 70-huawei-e3372.rules
- Updates udev USB trigger matching from Huawei-only (ATTRS{idVendor}=="12d1") to generic USB device events (SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device").
- This allows uavpal_disco.sh/uavpal_unload.sh to trigger for non-Huawei modems too.

Notes:
- These 5 files represent the core functional modem compatibility work.
- Other file differences on the drone backup (APN/keys/phone/zerotier/version) are environment-specific and not required for generic modem logic.

TODO Coverage (original uavpal_disco.sh)
- TODO: make ppp_if dynamic if possible
  Addressed by modem.conf + load_modem_config (MODEM_PPP_IFACE), allowing configurable PPP interface.

- TODO: make serial_ctrl_dev and serial_ppp_dev dynamic
  Addressed by detect_serial_devices() auto discovery and PPP retry with swapped serial roles when first assignment fails.

Implementation note:
- Dynamic behavior is implemented via runtime detection/configuration rather than AT^NDISDUP-based explicit port assignment.

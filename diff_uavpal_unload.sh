#!/bin/sh

usbmodeswitchStatus=`ps |grep usb_modeswitch |grep -v grep |wc -l`
if [ $usbmodeswitchStatus -ne 0 ]; then
	exit 0  # ignoring "removal" event while usb_modesswitch is running
fi

# Ignore unrelated USB removal events while modem is still present.
MODEM_USB_IDS="12d1:* 19d2:* 2c7c:* 1199:* 2dee:* 05c6:* 1bc7:* 413c:*"
if [ -f /data/ftp/uavpal/conf/modem.conf ]; then
	# shellcheck disable=SC1091
	. /data/ftp/uavpal/conf/modem.conf
fi
for line in $(lsusb 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="ID") print $(i+1)}' | tr 'A-Z' 'a-z'); do
	for pattern in $MODEM_USB_IDS; do
		pattern_lc=$(echo "$pattern" | tr 'A-Z' 'a-z')
		case "$line" in
		$pattern_lc)
			exit 0
			;;
		*)
			;;
		esac
	done
done

# Some modems briefly disconnect/re-enumerate (e.g. storage mode -> modem mode).
# Hold off unload for a short time and re-check whether a supported modem appears.
for retry in $(seq 1 12); do
	usleep 500000
	for line in $(lsusb 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="ID") print $(i+1)}' | tr 'A-Z' 'a-z'); do
		for pattern in $MODEM_USB_IDS; do
			pattern_lc=$(echo "$pattern" | tr 'A-Z' 'a-z')
			case "$line" in
			$pattern_lc)
				exit 0
				;;
			*)
				;;
			esac
		done
	done
done

ulogger -s -t uavpal_drone "USB modem disconnected"
ulogger -s -t uavpal_drone "... unloading scripts and daemons"
killall -9 uavpal_disco.sh
killall -9 uavpal_bebop2.sh
killall -9 uavpal_glympse.sh
killall -9 uavpal_sdcard.sh
killall -9 zerotier-one
killall -9 ntpd
killall -9 udhcpc
killall -9 curl
killall -9 chat
killall -9 pppd

ulogger -s -t uavpal_drone "... stopping telemetry endpoint"
if [ -f /tmp/uavpal_telemetry_httpd.pid ]; then
	telemetry_httpd_pid=$(cat /tmp/uavpal_telemetry_httpd.pid 2>/dev/null)
	if [ -n "$telemetry_httpd_pid" ]; then
		kill "$telemetry_httpd_pid" >/dev/null 2>&1
		sleep 1
		kill -9 "$telemetry_httpd_pid" >/dev/null 2>&1
	fi
fi
killall -9 uavpal_telemetry_server.sh >/dev/null 2>&1

ulogger -s -t uavpal_drone "... clearing UAVPAL iptables rules"
iptables -D INPUT -j UAVPAL_INPUT 2>/dev/null
iptables -F UAVPAL_INPUT 2>/dev/null
iptables -X UAVPAL_INPUT 2>/dev/null
# Backward compatibility: remove direct INPUT drop rules from older releases.
legacy_ifaces="eth1 ppp0 ppp1 ppp2 ppp3"
for ifname in $(ls /proc/sys/net/ipv4/conf 2>/dev/null | grep '^ppp'); do
	legacy_ifaces="$legacy_ifaces $ifname"
done
for iface in $legacy_ifaces; do
	for port in 21 23 51 61 873 8888 9050 44444 67 5353 14551; do
		while iptables -D INPUT -p tcp -i $iface --dport $port -j DROP 2>/dev/null; do :; done
	done
done

ulogger -s -t uavpal_drone "... clearing default route"
if [ -f /tmp/hilink_router_ip ]; then
	ip route del default via "$(cat /tmp/hilink_router_ip)" >/dev/null 2>&1
fi
if [ -f /tmp/modem_gateway_ip ]; then
	ip route del default via "$(cat /tmp/modem_gateway_ip)" >/dev/null 2>&1
fi

ulogger -s -t uavpal_drone "... removing temp files"
rm -f /tmp/serial_ctrl_dev
rm -f /tmp/hilink_router_ip
rm -f /tmp/hilink_login_required
rm -f /tmp/modem_gateway_ip
rm -f /tmp/modem_ip
rm -f /tmp/modem_connection_profile
rm -f /tmp/uavpal_telemetry_httpd.pid
rm -f /tmp/uavpal_telemetry.json
rm -f /tmp/uavpal_telemetry.json.tmp
rm -f /tmp/uavpal_telemetry_www/telemetry.json
rm -f /tmp/uavpal_telemetry_server.sh
rmdir /tmp/uavpal_telemetry_www 2>/dev/null

ulogger -s -t uavpal_drone "... removing lock files"
rm -f /tmp/lock/uavpal_disco
rm -f /tmp/lock/uavpal_bebop2
rm -f /tmp/lock/uavpal_unload
rm -f /tmp/lock/uavpal_sdcard_remove

ulogger -s -t uavpal_drone "... unloading kernel modules"
rmmod xt_tcpudp >/dev/null 2>&1
rmmod iptable_filter >/dev/null 2>&1
rmmod ip_tables >/dev/null 2>&1
rmmod x_tables >/dev/null 2>&1
rmmod option >/dev/null 2>&1
rmmod usb_wwan >/dev/null 2>&1
rmmod usbserial >/dev/null 2>&1
rmmod tun >/dev/null 2>&1
rmmod bsd_comp.ko >/dev/null 2>&1
rmmod ppp_deflate.ko >/dev/null 2>&1
rmmod ppp_async.ko >/dev/null 2>&1
rmmod ppp_generic.ko >/dev/null 2>&1
rmmod slhc.ko >/dev/null 2>&1
rmmod crc-ccitt >/dev/null 2>&1

ulogger -s -t uavpal_drone "*** idle on Wi-Fi ***"

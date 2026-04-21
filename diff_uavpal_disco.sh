#!/bin/sh
{
# exports
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/data/ftp/uavpal/lib

# variables
cdc_if="eth1"
ppp_if="ppp0"
serial_ctrl_dev="ttyUSB0"
serial_ppp_dev="ttyUSB1"
connection_profile=""
ppp_modules_loaded=0
modem_detect_timeout=300
internet_wait_timeout=300

# functions
. /data/ftp/uavpal/bin/uavpal_globalfunctions.sh
load_modem_config

load_ppp_modules()
{
	if [ "$ppp_modules_loaded" -eq "1" ]; then
		return
	fi
	ulogger -s -t uavpal_drone "... loading ppp kernel modules"
	insmod /data/ftp/uavpal/mod/${kernel_mods}/crc-ccitt.ko
	insmod /data/ftp/uavpal/mod/${kernel_mods}/slhc.ko
	insmod /data/ftp/uavpal/mod/${kernel_mods}/ppp_generic.ko
	insmod /data/ftp/uavpal/mod/${kernel_mods}/ppp_async.ko
	insmod /data/ftp/uavpal/mod/${kernel_mods}/ppp_deflate.ko
	insmod /data/ftp/uavpal/mod/${kernel_mods}/bsd_comp.ko
	ppp_modules_loaded=1
}

connect_stick_auto_ports()
{
	connect_stick
	if [ "$?" -eq "0" ]; then
		return 0
	fi

	# If serial ports are auto-detected and at least two are present, retry once with swapped roles.
	if [ "$MODEM_SERIAL_CTRL" = "auto" ] && [ "$MODEM_SERIAL_PPP" = "auto" ] && [ "${serial_dev_count:-0}" -ge "2" ]; then
		ulogger -s -t uavpal_drone "... PPP setup failed, retrying with swapped serial ports (ctrl=${serial_ppp_dev}, ppp=${serial_ctrl_dev})"
		swap_tmp="$serial_ctrl_dev"
		serial_ctrl_dev="$serial_ppp_dev"
		serial_ppp_dev="$swap_tmp"
		connect_stick
		return $?
	fi

	return 1
}

configure_hilink_features()
{
	echo "$modem_gateway_ip" >/tmp/hilink_router_ip
	hilink_ip="$modem_ip"

	hilink_profiles=$(hilink_api "get" "/api/dialup/profiles")
	hilink_apn_index=$(echo "$hilink_profiles" | xmllint --xpath "string(//CurrentProfile)" - 2>/dev/null)
	hilink_apn=$(echo "$hilink_profiles" | xmllint --xpath "string(//Profile[${hilink_apn_index}]/ApnName)" - 2>/dev/null)
	if [ -n "$hilink_apn" ]; then
		ulogger -s -t uavpal_drone "... connecting to mobile network using APN \"${hilink_apn}\" (configured in the modem Web UI)"
	fi

	if [ "$MODEM_HILINK_DMZ" = "1" ]; then
		ulogger -s -t uavpal_drone "... enabling Hi-Link DMZ mode (1:1 NAT for better zerotier performance)"
		hilink_api "post" "/api/security/dmz" "<request><DmzStatus>1</DmzStatus><DmzIPAddress>${hilink_ip}</DmzIPAddress></request>"
	fi
	if [ "$MODEM_HILINK_FULLCONE_NAT" = "1" ]; then
		ulogger -s -t uavpal_drone "... setting Hi-Link NAT type full cone (better zerotier performance)"
		hilink_api "post" "/api/security/nat" "<request><NATType>1</NATType></request>"
	fi

	hilink_dev_info=$(hilink_api "get" "/api/device/information")
	ulogger -s -t uavpal_drone "... model: $(echo "$hilink_dev_info" | xmllint --xpath 'string(//DeviceName)' -), hardware version: $(echo "$hilink_dev_info" | xmllint --xpath 'string(//HardwareVersion)' -)"
	ulogger -s -t uavpal_drone "... software version: $(echo "$hilink_dev_info" | xmllint --xpath 'string(//SoftwareVersion)' -), WebUI version: $(echo "$hilink_dev_info" | xmllint --xpath 'string(//WebUIVersion)' -)"
}

start_telemetry_http_server()
{
	telemetry_dir="/tmp/uavpal_telemetry_www"
	telemetry_file="/tmp/uavpal_telemetry.json"
	telemetry_link="${telemetry_dir}/telemetry.json"
	telemetry_pid_file="/tmp/uavpal_telemetry_httpd.pid"
	telemetry_server_script="/tmp/uavpal_telemetry_server.sh"

	mkdir -p "$telemetry_dir"
	if [ ! -f "$telemetry_file" ]; then
		printf '{"modem_signal_pct":null,"plane_battery_pct":null,"mode":"init","zt":"","ts":%s}\n' "$(date +%s)" > "$telemetry_file"
	fi
	ln -sf "$telemetry_file" "$telemetry_link"

	if [ -f "$telemetry_pid_file" ]; then
		old_pid=$(cat "$telemetry_pid_file" 2>/dev/null)
		if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
			return 0
		fi
		rm -f "$telemetry_pid_file"
	fi

	if command -v httpd >/dev/null 2>&1; then
		httpd -f -p 18080 -h "$telemetry_dir" >/dev/null 2>&1 &
		new_pid=$!
		sleep 1
		if [ -n "$new_pid" ] && kill -0 "$new_pid" 2>/dev/null; then
			echo "$new_pid" > "$telemetry_pid_file"
			ulogger -s -t uavpal_drone "... telemetry endpoint running on :18080/telemetry.json (httpd)"
			return 0
		fi
	fi

	if [ -x /bin/busybox ]; then
		/bin/busybox httpd -f -p 18080 -h "$telemetry_dir" >/dev/null 2>&1 &
		new_pid=$!
		sleep 1
		if [ -n "$new_pid" ] && kill -0 "$new_pid" 2>/dev/null; then
			echo "$new_pid" > "$telemetry_pid_file"
			ulogger -s -t uavpal_drone "... telemetry endpoint running on :18080/telemetry.json (busybox httpd)"
			return 0
		fi
	fi

	if [ -x /bin/busybox ] && /bin/busybox | grep -w nc >/dev/null 2>&1; then
		cat > "$telemetry_server_script" <<'EOF'
#!/bin/sh
while true; do
	{
		printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n'
		cat /tmp/uavpal_telemetry.json 2>/dev/null || echo '{"modem_signal_pct":null,"plane_battery_pct":null,"mode":"init","zt":"","ts":0}'
	} | nc -l -p 18080
done
EOF
		chmod +x "$telemetry_server_script"
		"$telemetry_server_script" >/dev/null 2>&1 &
		new_pid=$!
		sleep 1
		if [ -n "$new_pid" ] && kill -0 "$new_pid" 2>/dev/null; then
			echo "$new_pid" > "$telemetry_pid_file"
			ulogger -s -t uavpal_drone "... telemetry endpoint running on :18080/telemetry.json (nc fallback)"
			return 0
		fi
	fi

	ulogger -s -t uavpal_drone "... WARNING: telemetry endpoint could not start (no working httpd/nc)"
	return 1
}

# main
if ! detect_usb_modem; then
	ulogger -s -t uavpal_drone "... USB event detected, but no configured modem USB ID matched (${MODEM_USB_IDS}) - exiting"
	exit 0
fi

if [ -f /tmp/modem_connection_profile ]; then
	if ps | grep -q "[z]erotier-one"; then
		ulogger -s -t uavpal_drone "... modem connection already active ($(cat /tmp/modem_connection_profile)), ignoring duplicate USB add event"
		exit 0
	fi
	rm -f /tmp/modem_connection_profile
fi

ulogger -s -t uavpal_drone "USB modem detected (USB ID: ${matched_usb_id}${matched_usb_desc:+, device: ${matched_usb_desc}})"
ulogger -s -t uavpal_drone "=== Loading uavpal softmod $(head -1 /data/ftp/uavpal/version.txt |tr -d '\r\n' |tr -d '\n') ==="

# set platform, evinrude=Disco, ardrone3=Bebop 2
platform=$(grep 'ro.parrot.build.product' /etc/build.prop | cut -d'=' -f 2)
drone_fw_version=$(grep 'ro.parrot.build.uid' /etc/build.prop | cut -d '-' -f 3)
drone_fw_version_numeric=${drone_fw_version//.}

if [ "$platform" = "evinrude" ]; then
	drone_alias="Parrot Disco"
	if [ "$drone_fw_version_numeric" -ge "170" ]; then
		kernel_mods="1.7.0"
	else
		kernel_mods="1.4.1"
	fi
elif [ "$platform" = "ardrone3" ]; then
	drone_alias="Parrot Bebop 2"
	kernel_mods="4.4.2"
else
	ulogger -s -t uavpal_drone "... current platform ${platform} is not supported by the softmod - exiting!"
	exit 1
fi

ulogger -s -t uavpal_drone "... detected ${drone_alias} (platform ${platform}), firmware version ${drone_fw_version}"
ulogger -s -t uavpal_drone "... trying to use kernel modules compiled for firmware ${kernel_mods}"

ulogger -s -t uavpal_drone "... loading tunnel kernel module (for zerotier)"
insmod /data/ftp/uavpal/mod/${kernel_mods}/tun.ko

ulogger -s -t uavpal_drone "... loading USB modem kernel modules"
insmod /data/ftp/uavpal/mod/${kernel_mods}/usbserial.ko                 # needed for Disco only
insmod /data/ftp/uavpal/mod/${kernel_mods}/usb_wwan.ko
insmod /data/ftp/uavpal/mod/${kernel_mods}/option.ko

ulogger -s -t uavpal_drone "... loading iptables kernel modules (required for security)"
insmod /data/ftp/uavpal/mod/${kernel_mods}/x_tables.ko                  # needed for Disco firmware <=1.4.1 only
insmod /data/ftp/uavpal/mod/${kernel_mods}/ip_tables.ko                 # needed for Disco firmware <=1.4.1 only
insmod /data/ftp/uavpal/mod/${kernel_mods}/iptable_filter.ko            # needed for Disco firmware <=1.4.1 and >=1.7.0 and Bebop 2 firmware >= 4.4.2
insmod /data/ftp/uavpal/mod/${kernel_mods}/xt_tcpudp.ko                 # needed for Disco firmware <=1.4.1 only

run_usb_modeswitch
sleep 1
detect_usb_modem

ulogger -s -t uavpal_drone "... detecting modem profile"
modem_detect_started=$(date +%s)
while true
do
	detect_cdc_iface
	cdc_detected=$?
	detect_serial_devices
	serial_detected=$?

	mode_profile="$MODEM_PROFILE"
	if [ -z "$mode_profile" ]; then
		mode_profile="auto"
	fi

	# -=-=-=-=-= Forced Hi-Link profile =-=-=-=-=- 
	if [ "$mode_profile" = "huawei_hilink" ]; then
		if [ "$cdc_detected" -eq "0" ]; then
			ulogger -s -t uavpal_drone "... connecting modem to Internet (forced profile: huawei_hilink, iface ${cdc_if})"
			connect_ethernet
			if [ "$?" -ne "0" ]; then
				ulogger -s -t uavpal_drone "... forced huawei_hilink profile failed to obtain Ethernet link"
				usleep 100000
				continue
			fi
			if modem_has_hilink_api; then
				connection_profile="huawei_hilink"
				configure_hilink_features
				firewall ${cdc_if}
				connection_handler_hilink &
				break 1
			fi
		fi
		usleep 100000
		continue
	fi

	# -=-=-=-=-= Forced generic ethernet profile =-=-=-=-=- 
	if [ "$mode_profile" = "generic_ethernet" ]; then
		if [ "$cdc_detected" -eq "0" ]; then
			ulogger -s -t uavpal_drone "... connecting modem to Internet (forced profile: generic_ethernet, iface ${cdc_if})"
			connect_ethernet
			if [ "$?" -ne "0" ]; then
				ulogger -s -t uavpal_drone "... forced generic_ethernet profile failed to obtain Ethernet link"
				usleep 100000
				continue
			fi
			connection_profile="generic_ethernet"
			rm -f /tmp/hilink_router_ip /tmp/hilink_login_required /tmp/serial_ctrl_dev
			firewall ${cdc_if}
			connection_handler_ethernet &
			break 1
		fi
		usleep 100000
		continue
	fi

	# -=-=-=-=-= Forced Huawei PPP stick profile =-=-=-=-=- 
	if [ "$mode_profile" = "huawei_stick" ]; then
		if [ "$serial_detected" -eq "0" ] && [ -c "/dev/${serial_ctrl_dev}" ]; then
			ulogger -s -t uavpal_drone "... connecting modem to Internet (forced profile: huawei_stick, serial ${serial_ppp_dev})"
			load_ppp_modules
			connect_stick_auto_ports
			if [ "$?" -ne "0" ]; then
				ulogger -s -t uavpal_drone "... forced huawei_stick profile failed to establish PPP link"
				usleep 100000
				continue
			fi
			ulogger -s -t uavpal_drone "... querying Huawei device details via AT command"
			fhverString=$(at_command "AT\^FHVER" "OK" "1" | grep "FHVER:" | tail -n 1)
			ulogger -s -t uavpal_drone "... model: $(echo "$fhverString" | cut -d " " -f 1 | cut -d "\"" -f 2), hardware version: $(echo "$fhverString" | cut -d "," -f 2 | cut -d "\"" -f 1)"
			ulogger -s -t uavpal_drone "... software version: $(echo "$fhverString" | cut -d " " -f 2 | cut -d "," -f 1)"
			connection_profile="huawei_stick"
			rm -f /tmp/hilink_router_ip /tmp/hilink_login_required
			firewall ${ppp_if}
			connection_handler_stick &
			break 1
		fi
		usleep 100000
		continue
	fi

	# -=-=-=-=-= Forced generic PPP profile =-=-=-=-=- 
	if [ "$mode_profile" = "generic_ppp" ]; then
		if [ "$serial_detected" -eq "0" ] && [ -c "/dev/${serial_ctrl_dev}" ]; then
			ulogger -s -t uavpal_drone "... connecting modem to Internet (forced profile: generic_ppp, serial ${serial_ppp_dev})"
			load_ppp_modules
			connect_stick_auto_ports
			if [ "$?" -ne "0" ]; then
				ulogger -s -t uavpal_drone "... forced generic_ppp profile failed to establish PPP link"
				usleep 100000
				continue
			fi
			connection_profile="generic_ppp"
			rm -f /tmp/hilink_router_ip /tmp/hilink_login_required
			firewall ${ppp_if}
			connection_handler_stick &
			break 1
		fi
		usleep 100000
		continue
	fi

	# -=-=-=-=-= Auto profile detection =-=-=-=-=- 
	if [ "$cdc_detected" -eq "0" ]; then
		ulogger -s -t uavpal_drone "... detected modem network interface ${cdc_if}, trying Ethernet mode"
		connect_ethernet
		if [ "$?" -ne "0" ]; then
			ulogger -s -t uavpal_drone "... Ethernet mode failed on ${cdc_if}, trying PPP/serial fallback"
		elif modem_has_hilink_api; then
			ulogger -s -t uavpal_drone "... detected modem with Hi-Link compatible API"
			ulogger -s -t uavpal_drone "... unloading Stick Mode kernel modules (not required in Hi-Link/Ethernet mode)"
			rmmod option >/dev/null 2>&1
			rmmod usb_wwan >/dev/null 2>&1
			rmmod usbserial >/dev/null 2>&1
			connection_profile="huawei_hilink"
			configure_hilink_features
			firewall ${cdc_if}
			ulogger -s -t uavpal_drone "... starting connection keep-alive handler in background"
			connection_handler_hilink &
			break 1
		else
			ulogger -s -t uavpal_drone "... detected generic USB Ethernet modem (no Hi-Link API)"
			connection_profile="generic_ethernet"
			rm -f /tmp/hilink_router_ip /tmp/hilink_login_required /tmp/serial_ctrl_dev
			firewall ${cdc_if}
			ulogger -s -t uavpal_drone "... starting connection keep-alive handler in background"
			connection_handler_ethernet &
			break 1
		fi
	fi

	if [ "$serial_detected" -eq "0" ] && [ -c "/dev/${serial_ctrl_dev}" ]; then
		ulogger -s -t uavpal_drone "... detected modem serial interface /dev/${serial_ctrl_dev}, trying PPP mode"
		load_ppp_modules
		connect_stick_auto_ports
		if [ "$?" -ne "0" ]; then
			ulogger -s -t uavpal_drone "... PPP setup failed on auto profile, waiting for next modem state"
			usleep 100000
			continue
		fi
		if [ "$matched_usb_vendor" = "12d1" ]; then
			ulogger -s -t uavpal_drone "... querying Huawei device details via AT command"
			fhverString=$(at_command "AT\^FHVER" "OK" "1" | grep "FHVER:" | tail -n 1)
			ulogger -s -t uavpal_drone "... model: $(echo "$fhverString" | cut -d " " -f 1 | cut -d "\"" -f 2), hardware version: $(echo "$fhverString" | cut -d "," -f 2 | cut -d "\"" -f 1)"
			ulogger -s -t uavpal_drone "... software version: $(echo "$fhverString" | cut -d " " -f 2 | cut -d "," -f 1)"
			connection_profile="huawei_stick"
		else
			connection_profile="generic_ppp"
		fi
		rm -f /tmp/hilink_router_ip /tmp/hilink_login_required
		firewall ${ppp_if}
		ulogger -s -t uavpal_drone "... starting connection keep-alive handler in background"
		connection_handler_stick &
		break 1
	fi

	if [ $(( $(date +%s) - modem_detect_started )) -ge $modem_detect_timeout ]; then
		ulogger -s -t uavpal_drone "... ERROR: timeout while detecting/initializing modem profile"
		exit 1
	fi
	usleep 100000
done

echo "${connection_profile}" >/tmp/modem_connection_profile
ulogger -s -t uavpal_drone "... active modem profile: ${connection_profile}"

internet_wait_started=$(date +%s)
while true; do
	check_connection
	if [ $? -eq 0 ]; then
		break # break out of loop
	fi
	if [ $(( $(date +%s) - internet_wait_started )) -ge $internet_wait_timeout ]; then
		ulogger -s -t uavpal_drone "... ERROR: timeout waiting for public Internet connection"
		exit 1
	fi
done
ulogger -s -t uavpal_drone "... public Internet connection is up"

ulogger -s -t uavpal_drone "... setting DNS servers statically (Google Public DNS)"
echo -e 'nameserver 8.8.8.8\nnameserver 8.8.4.4' >/etc/resolv.conf

ulogger -s -t uavpal_drone "... setting date/time using ntp"
ntpd -n -d -q -p 0.debian.pool.ntp.org -p 1.debian.pool.ntp.org -p 2.debian.pool.ntp.org -p 3.debian.pool.ntp.org

ulogger -s -t uavpal_drone "... starting local telemetry endpoint"
start_telemetry_http_server

if [ -f /data/ftp/uavpal/conf/debug ]; then
	debug_filename="/data/ftp/internal_000/Debug/ulog_debug_$(date +%Y%m%d%H%M%S).log"
	ulogger -s -t uavpal_drone "... Debug mode is enabled - writing debug log to internal storage: $debug_filename"
	kill -9 $(ps |grep ulogcat |grep debugdummy | awk '{ print $1 }')
	ulogcat -u -k -l -F debugdummy >$debug_filename &
fi

ulogger -s -t uavpal_drone "... starting Glympse script for GPS tracking"
/data/ftp/uavpal/bin/uavpal_glympse.sh &

if [ -d "/data/lib/zerotier-one/networks.d" ] && [ ! -f "/data/lib/zerotier-one/networks.d/$(conf_read zt_networkid).conf" ]; then
	ulogger -s -t uavpal_drone "... zerotier config's network ID does not match zt_networkid config - removing zerotier data directory to allow join of new network ID"
	rm -rf /data/lib/zerotier-one 2>/dev/null
	mkdir -p /data/lib/zerotier-one
	ln -s /data/ftp/uavpal/conf/local.conf /data/lib/zerotier-one/local.conf
fi

ulogger -s -t uavpal_drone "... starting zerotier daemon"
/data/ftp/uavpal/bin/zerotier-one -d

if [ ! -d "/data/lib/zerotier-one/networks.d" ]; then
	ulogger -s -t uavpal_drone "... (initial-)joining zerotier network ID $(conf_read zt_networkid)"
	while true
	do
		ztjoin_response=`/data/ftp/uavpal/bin/zerotier-one -q join $(conf_read zt_networkid)`
		if [ "`echo $ztjoin_response |head -n1 |awk '{print $1}')`" == "200" ]; then
			ulogger -s -t uavpal_drone "... successfully joined zerotier network ID $(conf_read zt_networkid)"
			break # break out of loop
		else
			ulogger -s -t uavpal_drone "... ERROR joining zerotier network ID $(conf_read zt_networkid): $ztjoin_response - trying again"
			sleep 1
		fi
	done
fi
ulogger -s -t uavpal_drone "*** idle on LTE ***"
} &

load_modem_config()
{
	MODEM_PROFILE="auto"
	MODEM_USB_IDS="12d1:* 19d2:* 2c7c:* 1199:* 2dee:* 05c6:* 1bc7:* 413c:*"
	MODEM_ETH_IFACE="auto"
	MODEM_ETH_IFACE_PREFIXES="eth usb wwan enx"
	MODEM_PPP_IFACE="ppp0"
	MODEM_SERIAL_CTRL="auto"
	MODEM_SERIAL_PPP="auto"
	MODEM_ENABLE_USB_MODESWITCH="auto"
	MODEM_USB_MODESWITCH_VENDOR="12d1"
	MODEM_USB_MODESWITCH_ARGS="--huawei-new-mode -s 3"
	MODEM_HILINK_DMZ="1"
	MODEM_HILINK_FULLCONE_NAT="1"

	if [ -f /data/ftp/uavpal/conf/modem.conf ]; then
		# shellcheck disable=SC1091
		. /data/ftp/uavpal/conf/modem.conf
	fi

	if [ -n "$MODEM_PPP_IFACE" ]; then
		ppp_if="$MODEM_PPP_IFACE"
	fi
}

detect_usb_modem()
{
	matched_usb_id=""
	matched_usb_vendor=""
	matched_usb_product=""
	matched_usb_desc=""

	while read -r line; do
		usb_id=$(echo "$line" | awk '{for (i=1; i<=NF; i++) if ($i=="ID") { print $(i+1); exit }}' | tr 'A-Z' 'a-z')
		[ -z "$usb_id" ] && continue
		for pattern in $MODEM_USB_IDS; do
			pattern_lc=$(echo "$pattern" | tr 'A-Z' 'a-z')
			case "$usb_id" in
			$pattern_lc)
				matched_usb_id="$usb_id"
				matched_usb_vendor=$(echo "$usb_id" | cut -d ':' -f 1)
				matched_usb_product=$(echo "$usb_id" | cut -d ':' -f 2)
				matched_usb_desc=$(echo "$line" | sed 's/.*ID [0-9A-Fa-f]\{4\}:[0-9A-Fa-f]\{4\} //')
				return 0
				;;
			*)
				;;
			esac
		done
	done <<EOF
$(lsusb 2>/dev/null)
EOF

	return 1
}

run_usb_modeswitch()
{
	if [ ! -x /data/ftp/uavpal/bin/usb_modeswitch ]; then
		return 0
	fi

	if [ -z "$matched_usb_vendor" ] || [ -z "$matched_usb_product" ]; then
		return 1
	fi

	case "$MODEM_ENABLE_USB_MODESWITCH" in
	0 | false | no | off)
		return 0
		;;
	auto)
		modeswitch_vendor_lc=$(echo "$MODEM_USB_MODESWITCH_VENDOR" | tr 'A-Z' 'a-z')
		if [ "$matched_usb_vendor" != "$modeswitch_vendor_lc" ]; then
			return 0
		fi
		;;
	*)
		;;
	esac

	ulogger -s -t uavpal_drone "... running usb_modeswitch for ${matched_usb_vendor}:${matched_usb_product}"
	/data/ftp/uavpal/bin/usb_modeswitch -v "$matched_usb_vendor" -p "$matched_usb_product" $MODEM_USB_MODESWITCH_ARGS
}

list_network_ifaces()
{
	awk -F ':' 'NR>2 { gsub(/ /, "", $1); if ($1 != "") print $1 }' /proc/net/dev
}

is_modem_net_iface_candidate()
{
	iface="$1"

	case "$iface" in
	lo | eth0 | wlan* | zt* | ppp* | sit* | ip6tnl* | tunl* | gre* | gretap* | erspan* | docker* | br* | ifb*)
		return 1
		;;
	*)
		;;
	esac

	dev_path=$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null)
	if [ -n "$dev_path" ] && echo "$dev_path" | grep -q "/usb"; then
		return 0
	fi

	return 1
}

detect_cdc_iface()
{
	if [ -n "$MODEM_ETH_IFACE" ] && [ "$MODEM_ETH_IFACE" != "auto" ]; then
		if [ -d "/proc/sys/net/ipv4/conf/${MODEM_ETH_IFACE}" ]; then
			cdc_if="$MODEM_ETH_IFACE"
			return 0
		fi
	fi

	for prefix in $MODEM_ETH_IFACE_PREFIXES; do
		for iface in $(list_network_ifaces); do
			case "$iface" in
			${prefix}*)
				if is_modem_net_iface_candidate "$iface"; then
					cdc_if="$iface"
					return 0
				fi
				;;
			*)
				;;
			esac
		done
	done

	for iface in $(list_network_ifaces); do
		if is_modem_net_iface_candidate "$iface"; then
			cdc_if="$iface"
			return 0
		fi
	done

	return 1
}

detect_serial_devices()
{
	if [ -n "$MODEM_SERIAL_CTRL" ] && [ "$MODEM_SERIAL_CTRL" != "auto" ]; then
		serial_ctrl_dev="$MODEM_SERIAL_CTRL"
	fi
	if [ -n "$MODEM_SERIAL_PPP" ] && [ "$MODEM_SERIAL_PPP" != "auto" ]; then
		serial_ppp_dev="$MODEM_SERIAL_PPP"
	fi

	serial_candidates=""
	for dev in /dev/ttyUSB* /dev/ttyACM*; do
		if [ -c "$dev" ]; then
			serial_candidates="$serial_candidates $dev"
		fi
	done

	first_dev=$(echo "$serial_candidates" | awk '{ print $1 }')
	second_dev=$(echo "$serial_candidates" | awk '{ print $2 }')
	serial_dev_count=$(echo "$serial_candidates" | awk '{ print NF }')

	if [ "$MODEM_SERIAL_CTRL" = "auto" ] || [ -z "$MODEM_SERIAL_CTRL" ]; then
		if [ -n "$first_dev" ]; then
			serial_ctrl_dev=$(basename "$first_dev")
		fi
	fi

	if [ "$MODEM_SERIAL_PPP" = "auto" ] || [ -z "$MODEM_SERIAL_PPP" ]; then
		if [ -n "$second_dev" ]; then
			serial_ppp_dev=$(basename "$second_dev")
		elif [ -n "$first_dev" ]; then
			serial_ppp_dev=$(basename "$first_dev")
		fi
	fi

	if [ -n "$serial_ctrl_dev" ] && [ -c "/dev/${serial_ctrl_dev}" ]; then
		return 0
	fi

	return 1
}

connect_ethernet()
{
	ulogger -s -t uavpal_connect_ethernet "... bringing up modem network interface ${cdc_if}"
	ifconfig "${cdc_if}" up
	ulogger -s -t uavpal_connect_ethernet "... requesting IP address from modem's DHCP server"
	dhcp_out=$(udhcpc -i "${cdc_if}" -n -t 10 2>&1)
	modem_ip=$(echo "$dhcp_out" | awk '/obtained/ { print $4; exit }')
	modem_gateway_ip=$(echo "$dhcp_out" | awk '/router/ { for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\./) { print $i; exit } }')

	if [ -z "$modem_gateway_ip" ]; then
		modem_gateway_ip=$(ip route 2>/dev/null | awk '$1=="default" { print $3; exit }')
	fi
	if [ -z "$modem_gateway_ip" ]; then
		modem_gateway_ip=$(route -n 2>/dev/null | awk '$1=="0.0.0.0" { print $2; exit }')
	fi
	if [ -z "$modem_gateway_ip" ] && [ -n "$modem_ip" ]; then
		modem_gateway_ip="$(echo "$modem_ip" | cut -d '.' -f 1,2,3).1"
	fi

	if [ -n "$modem_ip" ]; then
		ulogger -s -t uavpal_connect_ethernet "... setting ${cdc_if}'s IP address to ${modem_ip}"
		ifconfig "${cdc_if}" "${modem_ip}" netmask 255.255.255.0
	fi

	if [ -n "$modem_gateway_ip" ]; then
		ulogger -s -t uavpal_connect_ethernet "... setting default route via ${modem_gateway_ip}"
		ip route add default via "${modem_gateway_ip}" dev "${cdc_if}" >/dev/null 2>&1
		if [ "$?" -ne 0 ]; then
			route add default gw "${modem_gateway_ip}" dev "${cdc_if}" >/dev/null 2>&1
		fi
		echo "${modem_gateway_ip}" >/tmp/modem_gateway_ip
	fi
	echo "${modem_ip}" >/tmp/modem_ip

	if [ -z "$modem_ip" ] || [ -z "$modem_gateway_ip" ]; then
		ulogger -s -t uavpal_connect_ethernet "... DHCP/router detection failed on ${cdc_if}"
		return 1
	fi

	return 0
}

modem_has_hilink_api()
{
	if [ -z "$modem_gateway_ip" ] && [ -f /tmp/modem_gateway_ip ]; then
		modem_gateway_ip=$(cat /tmp/modem_gateway_ip)
	fi
	if [ -z "$modem_gateway_ip" ]; then
		return 1
	fi

	probe=$(/data/ftp/uavpal/bin/curl -s -m 2 -X GET "http://${modem_gateway_ip}/api/device/information" 2>/dev/null)
	echo "$probe" | grep -q "<response>" || return 1
	echo "$probe" | grep -q "<DeviceName>" || return 1
	return 0
}

hilink_api()
{
# Usage: hilink_api {get,post} url-context [json-data]
# Note: callers invoking this function using method "post" do not need to process (echoed) return values, as errors are outputted within the function itself, otherwise the response is <response>OK</response>
#       callers invoking this function using method "get" should handle (echoed) return values using var=$(hilink_api)

	if [ "$1" == "post" ]; then
		method="POST"
	else
		method="GET"
	fi
	url="$2"
	data="$3"

	hilink_router_ip=$(cat /tmp/hilink_router_ip)
	sessionInfo=$(/data/ftp/uavpal/bin/curl -s -X GET "http://${hilink_router_ip}/api/webserver/SesTokInfo" 2>/dev/null)
	if [ "$?" -ne "0" ]; then ulogger -s -t uavpal_hilink_api "... Error connecting to Hi-Link API"; fi
	cookie=$(echo "$sessionInfo" | grep "SessionID=" | cut -b 10-147)
	token=$(echo "$sessionInfo" | grep "TokInfo" | cut -b 10-41)
	if [ -f /tmp/hilink_login_required ]; then
		sessionInfoLogin=$(/data/ftp/uavpal/bin/curl -s -X POST "http://${hilink_router_ip}/api/user/login" -d "<request><Username>admin</Username><Password>$(echo -n "admin" |base64)</Password><password_type>3</password_type></request>" -H "Cookie: $cookie" -H "__RequestVerificationToken: $token" --dump-header - 2>/dev/null)
		if echo -n "$sessionInfoLogin" | grep '<code>108006\|<code>108007' ; then
			ulogger -s -t uavpal_hilink_api "... Hi-Link authentication error. Please disable password protection or set it to user=admin, password=admin"
			return # break out function
		fi
		cookie=$(echo -n "$sessionInfoLogin" | grep "SessionID=" | cut -d ':' -f2 | cut -d ';' -f1)
		token=$(echo -n "$sessionInfoLogin" | grep "__RequestVerificationTokenone" | cut -d ':' -f2)
		sessionInfoAdm=$(curl -s -X GET "http://${hilink_router_ip}/api/webserver/SesTokInfo" -H "Cookie: $cookie" 2>/dev/null)
		token=$(echo "$sessionInfoAdm" | grep "TokInfo" | cut -b 10-41)
	fi
	result=$(/data/ftp/uavpal/bin/curl -s -X $method "http://${hilink_router_ip}${url}" -d "$data" -H "Cookie: $cookie" -H "__RequestVerificationToken: $token" 2>/dev/null)
	if echo "$result" | grep "<error>" ; then
		if [ "$(echo $result | xmllint --xpath 'string(//error/code)' -)" -eq "100003" ]; then
			ulogger -s -t uavpal_hilink_api "... Hi-Link authentication required. Trying to login using user=admin, password=admin"
			touch /tmp/hilink_login_required
			result=$(hilink_api "$1" "$2" "$3")
		else
			ulogger -s -t uavpal_hilink_api "... Hi-Link returned Error Code: $(echo $result | xmllint --xpath 'string(//error/code)' -)"
		fi
	fi
	echo "$result"
}

firewall()
{
	# Security: block incoming connections on the Internet interface
	# these connections should only be allowed on Wi-Fi (eth0) and via zerotier (zt*)
	ulogger -s -t uavpal_drone "... applying iptables security rules for interface ${1}"
	ip_block='21 23 51 61 873 8888 9050 44444 67 5353 14551'
	for i in $ip_block; do iptables -I INPUT -p tcp -i ${1} --dport $i -j DROP; done
}

conf_read()
{
	result=$(head -1 /data/ftp/uavpal/conf/${1})
	echo "$result" |tr -d '\r\n' |tr -d '\n'
}

at_command()
{
	command="$1"
	expected_response="$2"
	timeout="$3"
	result=$(/data/ftp/uavpal/bin/chat -V -t $timeout '' "$command" "$expected_response" '' > /dev/${serial_ctrl_dev} < /dev/${serial_ctrl_dev}) 2>&1
	if [ "$?" -ne "0" ]; then ulogger -s -t uavpal_at_command "... Did not receive expected output from AT command $command"; fi
	echo "$result"
}

send_message()
{
	# delay sending of messages if modem is not yet online
	for i in $(seq 0 5); do
		check_connection
	done
	if [ $? -ne 0 ]; then
		ulogger -s -t uavpal_send_message "... Cannot send message (no connection). Exiting send_message function!"
		exit 1 # exit function
	fi

	if [ -z "$serial_ctrl_dev" ] && [ -f /tmp/serial_ctrl_dev ]; then
		serial_ctrl_dev=$(head -1 /tmp/serial_ctrl_dev | tr -d '\r\n' | tr -d '\n')
	fi

	phone_no="$(conf_read phonenumber)"
	if [ "$phone_no" != "+XXYYYYYYYYY" ]; then
		if [ -f "/tmp/hilink_router_ip" ]; then
			ulogger -s -t uavpal_send_message "... sending SMS to ${phone_no} (via Hi-Link API)"
			hilink_api "post" "/api/sms/send-sms" "<request><Index>-1</Index><Phones><Phone>${phone_no}</Phone></Phones><Sca></Sca><Content>${1}</Content><Length>-1</Length><Reserved>-1</Reserved><Date>-1</Date></request>"
		elif [ -n "$serial_ctrl_dev" ] && [ -c "/dev/${serial_ctrl_dev}" ]; then
			ulogger -s -t uavpal_send_message "... sending SMS to ${phone_no} (via ${serial_ctrl_dev})"
			at_command "AT+CMGF=1\rAT+CMGS=\"${phone_no}\"\r${1}\32" "OK" "2"
		else
			ulogger -s -t uavpal_send_message "... cannot send SMS: no modem serial control interface available"
		fi
	fi

	pb_access_token="$(conf_read pushbullet)"
	if [ "$pb_access_token" != "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" ]; then
		ulogger -s -t uavpal_send_message "... sending push notification (via Pushbullet API)"
		/data/ftp/uavpal/bin/curl -q -k -u ${pb_access_token}: -X POST https://api.pushbullet.com/v2/pushes --header 'Content-Type: application/json' --data-binary '{"type": "note", "title": "'"$2"'", "body": "'"$1"'"}'
	fi
}

connect_hilink()
{
	connect_ethernet

	hilink_ip="$modem_ip"
	hilink_router_ip="$modem_gateway_ip"
	if [ -z "$hilink_router_ip" ] && [ -n "$hilink_ip" ]; then
		hilink_router_ip="$(echo "$hilink_ip" | cut -d '.' -f 1,2,3).1"
	fi
	if [ -z "$hilink_router_ip" ]; then
		ulogger -s -t uavpal_connect_hilink "... unable to detect Hi-Link router IP"
		return 1
	fi

	echo "$hilink_router_ip" >/tmp/hilink_router_ip
	hilink_profiles=$(hilink_api "get" "/api/dialup/profiles")
	hilink_apn_index=$(echo $hilink_profiles | xmllint --xpath "string(//CurrentProfile)" -)
	hilink_apn=$(echo $hilink_profiles | xmllint --xpath "string(//Profile[${hilink_apn_index}]/ApnName)" -)
	ulogger -s -t uavpal_connect_hilink "... connecting to mobile network using APN \"${hilink_apn}\" (configured in the Hi-Link Web UI)"
}

connect_stick()
{
	ulogger -s -t uavpal_connect_stick "... running pppd to establish connection to mobile network using APN \"$(conf_read apn)\" (configured in the conf/apn file)"
	killall -9 pppd >/dev/null 2>&1
	killall -9 chat >/dev/null 2>&1
	/data/ftp/uavpal/bin/pppd \
		${serial_ppp_dev} \
		connect "/data/ftp/uavpal/bin/chat -v -f  /data/ftp/uavpal/conf/chatscript -T $(conf_read apn)" \
		noipdefault \
		defaultroute \
		replacedefaultroute \
		hide-password \
		noauth \
		persist \
		usepeerdns \
		maxfail 0 \
		lcp-echo-failure 10 \
		lcp-echo-interval 6 \
		holdoff 5

	ppp_wait_loops=250
	while [ "$ppp_wait_loops" -gt "0" ]; do
		if [ -d "/proc/sys/net/ipv4/conf/${ppp_if}" ]; then
			break
		fi
		usleep 100000
		ppp_wait_loops=$((ppp_wait_loops - 1))
	done

	if [ ! -d "/proc/sys/net/ipv4/conf/${ppp_if}" ]; then
		ulogger -s -t uavpal_connect_stick "... PPP interface \"${ppp_if}\" did not come up (serial PPP dev: ${serial_ppp_dev}, serial CTRL dev: ${serial_ctrl_dev})"
		killall -9 pppd >/dev/null 2>&1
		killall -9 chat >/dev/null 2>&1
		return 1
	fi

	ulogger -s -t uavpal_connect_stick "... interface \"${ppp_if}\" is up"
	echo $serial_ctrl_dev >/tmp/serial_ctrl_dev
	return 0
}

connection_handler_hilink()
{
	while true; do
		check_connection
		if [ $? -ne 0 ]; then
			ulogger -s -t uavpal_connection_handler_hilink "... Internet connection lost, trying to reconnect"
			hilink_api "post" "/api/dialup/mobile-dataswitch" "<request><dataswitch>0</dataswitch></request>"
			sleep 1
			hilink_api "post" "/api/dialup/mobile-dataswitch" "<request><dataswitch>1</dataswitch></request>"
			killall -9 udhcpc
			ifconfig ${cdc_if} down
			if [ -f /tmp/hilink_router_ip ]; then
				ip route del default via "$(cat /tmp/hilink_router_ip)" dev ${cdc_if} >/dev/null 2>&1
			fi
			rm -f /tmp/modem_gateway_ip /tmp/modem_ip
			sleep 1
			connect_hilink
		fi
		sleep 5
	done
}

connection_handler_ethernet()
{
	while true; do
		check_connection
		if [ $? -ne 0 ]; then
			ulogger -s -t uavpal_connection_handler_ethernet "... Internet connection lost, trying to reconnect"
			killall -9 udhcpc
			ifconfig ${cdc_if} down
			if [ -f /tmp/modem_gateway_ip ]; then
				ip route del default via "$(cat /tmp/modem_gateway_ip)" dev ${cdc_if} >/dev/null 2>&1
			fi
			rm -f /tmp/modem_gateway_ip /tmp/modem_ip
			sleep 1
			connect_ethernet
		fi
		sleep 5
	done
}

connection_handler_stick()
{ 
	while true; do
		check_connection
		if [ $? -ne 0 ]; then
			ulogger -s -t uavpal_connection_handler_stick "... Internet connection lost, trying to reconnect"
			killall -9 pppd
			killall -9 chat
			ifconfig ${ppp_if} down
			sleep 1
			connect_stick
		fi
		sleep 5
	done
}

check_connection()
{
	ping_retries_per_destination=2
	ping_destinations="8.8.8.8 192.5.5.241 199.7.83.42" # google-public-dns-a.google.com, f.root-servers.org, l.root-servers.org
	for check in $ping_destinations; do
		for i in $(seq 1 $ping_retries_per_destination); do
			ping -W 5 -c 1 $check >/dev/null 2>&1
			if [ $? -eq 0 ]; then
				return 0
			fi
			sleep 1
		done
	done
	# none of the ping destinations could have been reached
	return 1
}

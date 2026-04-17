#!/bin/sh

# exports
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/data/ftp/uavpal/lib

# variables
platform=$(grep 'ro.parrot.build.product' /etc/build.prop | cut -d'=' -f 2)
serial_ctrl_dev=""
if [ -f /tmp/serial_ctrl_dev ]; then
	serial_ctrl_dev=$(head -1 /tmp/serial_ctrl_dev |tr -d '\r\n' |tr -d '\n')
fi

# functions
. /data/ftp/uavpal/bin/uavpal_globalfunctions.sh

function parse_json()
{
	echo ${1##*\"${2}\":\"} | \
	cut -d "\"" -f 1
}

function gpsDecimal()
{
	gpsVal=$1
	gpsDir="$2"
	gpsInt=$(echo "$gpsVal 100 / p" | /data/ftp/uavpal/bin/dc)
	gpsMin=$(echo "3k$gpsVal $gpsInt 100 * - p" | /data/ftp/uavpal/bin/dc)
	gpsDec=$(echo "6k$gpsMin 60 / $gpsInt + 1000000 * p" | /data/ftp/uavpal/bin/dc | cut -d '.' -f 1)
	if [[ "$gpsDir" != "E" && "$gpsDir" != "N" ]]; then gpsDec="-$gpsDec"; fi
	echo $gpsDec
}

function calc_crc()
{
        local line=$1
        local sum=0
        crc_ok=0

        local msglen=9
        if [ "$platform" == "ardrone3" ]; then
                msglen=15
        fi

        for i in $(seq 1 $msglen); do
                local val=$((0x$(echo $line | cut -d " " -f $(($i+1)))))
                sum=$(($sum ^ $val))
        done
        local crc=$((0x$(echo $line | cut -d " " -f $(($i+2)))))
        if [ $sum -eq $crc ]; then
                crc_ok=1
        fi
}

function calc_volt()
{
        local line=$1
        local voltpos=4
        if [ "$platform" == "ardrone3" ]; then
                voltpos=16
        fi
        local msb=$(echo $line | cut -d " " -f $voltpos)
        local lsb=$(echo $line | cut -d " " -f $(($voltpos+1)))
        local val=$((0x$msb$lsb))
        bat_volts=$(printf "%d.%02d" $(($val / 1000)) $(($val % 1000 / 10)))
}

# main
ulogger -s -t uavpal_glympse "... reading Glympse API key from config file"
apikey="$(conf_read glympse_apikey)"
if [ "$apikey" == "AAAAAAAAAAAAAAAAAAAA" ]; then
	ulogger -s -t uavpal_glympse "... disabling Glympse, API key set to ignore"
	exit 0
fi

ulogger -s -t uavpal_glympse "... reading drone ID from avahi"
droneName=$(cat /tmp/avahi/services/ardiscovery.service |grep name |cut -d '>' -f 2 |cut -d '<' -f 0)

ulogger -s -t uavpal_glympse "... Glympse API: creating account"
glympseCreateAccount=$(/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -X POST "https://api.glympse.com/v2/account/create?api_key=${apikey}")

ulogger -s -t uavpal_glympse "... Glympse API: logging in"
glympseLogin=$(/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -X POST "https://api.glympse.com/v2/account/login?api_key=${apikey}&id=$(parse_json $glympseCreateAccount id)&password=$(parse_json $glympseCreateAccount password)")

ulogger -s -t uavpal_glympse "... Glympse API: parsing access token"
access_token=$(parse_json $(echo $glympseLogin |sed 's/\:\"access_token/\:\"tmp/g') access_token)

ulogger -s -t uavpal_glympse "... Glympse API: creating ticket"
glympseCreateTicket=$(/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -H "Authorization: Bearer ${access_token}" -X POST "https://api.glympse.com/v2/users/self/create_ticket?duration=14400000")

ulogger -s -t uavpal_glympse "... Glympse API: parsing ticket"
ticket=$(parse_json $glympseCreateTicket id)

ulogger -s -t uavpal_glympse "... Glympse API: creating invite"
glympseCreateInvite=$(/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -H "Authorization: Bearer ${access_token}" -X POST "https://api.glympse.com/v2/tickets/$ticket/create_invite?type=sms&address=1234567890&send=client")

ulogger -s -t uavpal_glympse "... Glympse link generated: https://glympse.com/$(parse_json ${glympseCreateInvite% *} id)"

message="You can track the location of your ${droneName} here: https://glympse.com/$(parse_json ${glympseCreateInvite% *} id)"
title="${droneName}'s GPS location"
send_message "$message" "$title" &

ulogger -s -t uavpal_glympse "... Glympse API: setting drone thumbnail image"
if [ "$platform" == "evinrude" ]; then
	# Parrot Disco
	tn_filename="disco.png"
elif [ "$platform" == "ardrone3" ]; then
	# Parrot Bebop 2
	tn_filename="bebop2.png"
fi
/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -H "Authorization: Bearer ${access_token}" -X POST -d "[{\"t\": $(date +%s)000, \"pid\": 0, \"n\": \"avatar\", \"v\": \"https://uavpal.com/img/${tn_filename}?$(date +%s)\"}]" "https://api.glympse.com/v2/tickets/$ticket/append_data"

ztVersion=$(/data/ftp/uavpal/bin/zerotier-one -v)

ulogger -s -t uavpal_glympse "... Glympse API: reading out drone's GPS coordinates every 5 seconds to update Glympse via API"

# initializing vars
bat_volts="n/a"
bat_percent="n/a"

while true
do
	gps_nmea_out=$(grep GNRMC -m 1 /tmp/gps_nmea_out | cut -c4-)
	lat=$(echo $gps_nmea_out | cut -d ',' -f 4)
	latdir=$(echo $gps_nmea_out | cut -d ',' -f 5)
	long=$(echo $gps_nmea_out | cut -d ',' -f 6)
	longdir=$(echo $gps_nmea_out | cut -d ',' -f 7)
	speed=$(printf "%.0f\n" $(/data/ftp/uavpal/bin/dc -e "$(echo $gps_nmea_out | cut -d ',' -f 8) 51.4444 * p"))
	heading="$(printf "%.0f\n" $(echo $gps_nmea_out | cut -d ',' -f 9))"
	altitude_abs=$(grep GNGNS -m 1 /tmp/gps_nmea_out | cut -c4- | cut -d ',' -f 10)

	if [ -f /data/ftp/internal_000/*/academy/*.pud.temp ]; then
		altitude_rel=$(/data/ftp/uavpal/bin/dc -e "$altitude_abs $(cat /tmp/alt_before_takeoff) - p")
	else
		echo $altitude_abs > /tmp/alt_before_takeoff
		altitude_rel="0"
  fi

	if [ -s /tmp/sc2ping ] && [ `cat /tmp/sc2ping | wc -l` -eq '1' ]; then
		latency=$(/data/ftp/uavpal/bin/dc -e "$(cat /tmp/sc2ping) 2 / p")ms
	else
		latency="n/a"
	fi

        crc_ok=0
        for i in $(seq 1 5); do
                i2cline=$(i2cdump -r 0x20-0x2f -y 1 0x08)
                calc_crc "$i2cline"
                if [ $crc_ok -gt 0 ]; then break; fi
        done
        if [ $crc_ok -gt 0 ]; then
	        bat_volts_prev=$bat_volts
                calc_volt "$i2cline"
	        bat_percent_prev=$bat_percent
	        bat_percent=$(ulogcat -d -v csv |grep "Battery percentage" |tail -n 1 | cut -d " " -f 4)
        else
	        bat_percent="$bat_percent_prev";
        fi

	ip_sc2=`netstat -nu |grep 9988 | head -1 | awk '{ print $5 }' | cut -d ':' -f 1`
	ztConn=""
	if [ `echo $ip_sc2 | awk -F. '{print $1"."$2"."$3}'` == "192.168.42" ]; then
		signal="Wi-Fi"
	else
		# detect if zerotier connection is direct vs. relayed
		if [ $(/data/ftp/uavpal/bin/zerotier-one -q listpeers |grep LEAF |grep $ztVersion |grep -v ' - ' | wc -l) != '0' ] && [ "$ip_sc2" != "" ]; then
			ztConn=" [D]"
		fi
		if [ $(/data/ftp/uavpal/bin/zerotier-one -q listpeers |grep LEAF |grep $ztVersion |grep -v ' - ' | wc -l) == '0' ] && [ "$ip_sc2" != "" ]; then
			ztConn=" [R]"
		fi

		# reading out the modem's connection type and signal strength
		modem_profile=""
		if [ -f "/tmp/modem_connection_profile" ]; then
			modem_profile=$(cat /tmp/modem_connection_profile | tr -d '\r\n' | tr -d '\n')
		fi
		mode=""
		signalPercentage=""
		huawei_auth_needed=0

		modem_api_ip=$(ip route | grep default | awk '{print $3}' | head -n 1)
		if [ -z "$modem_api_ip" ]; then
			modem_api_ip="192.168.8.1"
		fi

		# 1) Hi-Link API helper for explicit Hi-Link profile.
		if [ "$modem_profile" = "huawei_hilink" ]; then
			modeStr=$(hilink_api "get" "/api/device/information" | xmllint --xpath 'string(//workmode)' - 2>/dev/null)
			signalBars=$(hilink_api "get" "/api/monitoring/status" | xmllint --xpath 'string(//SignalIcon)' - 2>/dev/null)
			if [ -z "$mode" ]; then
				case "$modeStr" in
					LTE)
						mode="4G"
						;;
					NR5G*|5G*)
						mode="5G"
						;;
					WCDMA|UMTS|HSPA*)
						mode="3G"
						;;
					GSM|GPRS|EDGE)
						mode="2G"
						;;
					"")
						;;
					*)
						mode="$modeStr"
						;;
				esac
			fi
			if [ -z "$signalPercentage" ] && echo "$signalBars" | grep -Eq '^[0-9]+$'; then
				signalPercentage=$(echo "$signalBars 20 * p" | /data/ftp/uavpal/bin/dc)%
			fi
		fi

		# 2) Generic ZTE-style hostless modem API (clone modems).
		if [ -z "$mode" ] || [ -z "$signalPercentage" ]; then
			modem_info_json=$(/data/ftp/uavpal/bin/curl -q -m 2 -s "http://${modem_api_ip}/reqproc/proc_get?isTest=false&multi_data=1&cmd=network_type,signalbar,signalbar_ex,ppp_status" 2>/dev/null)
			modeStr2=$(echo "$modem_info_json" | sed -n 's/.*"network_type":"\([^"]*\)".*/\1/p' | head -n 1)
			signalBars2=$(echo "$modem_info_json" | sed -n 's/.*"signalbar":"\([^"]*\)".*/\1/p' | head -n 1)
			if [ -z "$mode" ]; then
				case "$modeStr2" in
					LTE|FDD\ LTE|TDD\ LTE)
						mode="4G"
						;;
					NR5G*|5G*)
						mode="5G"
						;;
					WCDMA|UMTS|HSPA*)
						mode="3G"
						;;
					GSM|GPRS|EDGE)
						mode="2G"
						;;
					"")
						;;
					*)
						mode="$modeStr2"
						;;
				esac
			fi
			if [ -z "$signalPercentage" ] && echo "$signalBars2" | grep -Eq '^[0-9]+$'; then
				signalPercentage=$(echo "$signalBars2 20 * p" | /data/ftp/uavpal/bin/dc)%
			fi
		fi

		# 3) Direct Huawei API probe (unauthenticated).
		if [ -z "$mode" ] || [ -z "$signalPercentage" ]; then
			hilink_info_xml=$(/data/ftp/uavpal/bin/curl -q -m 2 -s "http://${modem_api_ip}/api/device/information" 2>/dev/null)
			hilink_status_xml=$(/data/ftp/uavpal/bin/curl -q -m 2 -s "http://${modem_api_ip}/api/monitoring/status" 2>/dev/null)

			if echo "$hilink_info_xml" | grep -q "<error>"; then
				hilink_info_err=$(echo "$hilink_info_xml" | xmllint --xpath 'string(//error/code)' - 2>/dev/null)
				if [ "$hilink_info_err" = "100003" ] || [ "$hilink_info_err" = "125002" ]; then
					huawei_auth_needed=1
				fi
			fi
			if echo "$hilink_status_xml" | grep -q "<error>"; then
				hilink_status_err=$(echo "$hilink_status_xml" | xmllint --xpath 'string(//error/code)' - 2>/dev/null)
				if [ "$hilink_status_err" = "100003" ] || [ "$hilink_status_err" = "125002" ]; then
					huawei_auth_needed=1
				fi
			fi

			modeStr3=$(echo "$hilink_info_xml" | xmllint --xpath 'string(//workmode)' - 2>/dev/null)
			signalBars3=$(echo "$hilink_status_xml" | xmllint --xpath 'string(//SignalIcon)' - 2>/dev/null)
			if [ -z "$mode" ]; then
				case "$modeStr3" in
					LTE)
						mode="4G"
						;;
					NR5G*|5G*)
						mode="5G"
						;;
					WCDMA|UMTS|HSPA*)
						mode="3G"
						;;
					GSM|GPRS|EDGE)
						mode="2G"
						;;
					"")
						;;
					*)
						mode="$modeStr3"
						;;
				esac
			fi
			if [ -z "$signalPercentage" ] && echo "$signalBars3" | grep -Eq '^[0-9]+$'; then
				signalPercentage=$(echo "$signalBars3 20 * p" | /data/ftp/uavpal/bin/dc)%
			fi
		fi

		# 4) Authenticated Huawei API retry for generic_ethernet when telemetry endpoints are protected.
		if [ "$modem_profile" = "generic_ethernet" ] && [ "$huawei_auth_needed" -eq "1" ]; then
			if [ -z "$mode" ] || [ -z "$signalPercentage" ]; then
				saved_hilink_router_ip=""
				had_hilink_router_ip=0
				if [ -f "/tmp/hilink_router_ip" ]; then
					saved_hilink_router_ip=$(cat /tmp/hilink_router_ip)
					had_hilink_router_ip=1
				fi

				echo "$modem_api_ip" >/tmp/hilink_router_ip
				touch /tmp/hilink_login_required
				auth_info_xml=$(hilink_api "get" "/api/device/information")
				auth_status_xml=$(hilink_api "get" "/api/monitoring/status")
				rm -f /tmp/hilink_login_required

				if [ "$had_hilink_router_ip" -eq "1" ]; then
					echo "$saved_hilink_router_ip" >/tmp/hilink_router_ip
				else
					rm -f /tmp/hilink_router_ip
				fi

				modeStr4=$(echo "$auth_info_xml" | xmllint --xpath 'string(//workmode)' - 2>/dev/null)
				signalBars4=$(echo "$auth_status_xml" | xmllint --xpath 'string(//SignalIcon)' - 2>/dev/null)
				if [ -z "$mode" ]; then
					case "$modeStr4" in
						LTE)
							mode="4G"
							;;
						NR5G*|5G*)
							mode="5G"
							;;
						WCDMA|UMTS|HSPA*)
							mode="3G"
							;;
						GSM|GPRS|EDGE)
							mode="2G"
							;;
						"")
							;;
						*)
							mode="$modeStr4"
							;;
					esac
				fi
				if [ -z "$signalPercentage" ] && echo "$signalBars4" | grep -Eq '^[0-9]+$'; then
					signalPercentage=$(echo "$signalBars4 20 * p" | /data/ftp/uavpal/bin/dc)%
				fi
			fi
		fi

		# 5) Serial AT fallback (PPP sticks and mixed enumerations).
		if [ -z "$mode" ] || [ -z "$signalPercentage" ]; then
			if [ -z "$serial_ctrl_dev" ] || [ ! -c "/dev/${serial_ctrl_dev}" ]; then
				for dev in /dev/ttyUSB* /dev/ttyACM*; do
					if [ -c "$dev" ]; then
						serial_ctrl_dev=$(basename "$dev")
						break
					fi
				done
			fi
			if [ -n "$serial_ctrl_dev" ] && [ -c "/dev/${serial_ctrl_dev}" ]; then
				if [ -z "$mode" ]; then
					modeString=$(at_command "AT\^SYSINFOEX" "OK" "1" | grep "SYSINFOEX:" | tail -n 1)
					modeNum=$(echo "$modeString" | cut -d "," -f 8 | tr -dc '0-9')
					if echo "$modeNum" | grep -Eq '^[0-9]+$'; then
						if [ "$modeNum" -ge 101 ]; then
							mode="4G"
						elif [ "$modeNum" -ge 23 ] && [ "$modeNum" -le 65 ]; then
							mode="3G"
						elif [ "$modeNum" -ge 1 ] && [ "$modeNum" -le 3 ]; then
							mode="2G"
						fi
					fi
				fi
				if [ -z "$mode" ]; then
					# SYSINFOEX is not supported by some Huawei stick firmware variants.
					copsString=$(at_command "AT+COPS?" "OK" "1" | grep "+COPS:" | tail -n 1)
					copsAct=$(echo "$copsString" | awk -F',' '{ gsub(/[^0-9]/, "", $4); print $4 }')
					if echo "$copsAct" | grep -Eq '^[0-9]+$'; then
						case "$copsAct" in
						7 | 9 | 10)
							mode="4G"
							;;
						11 | 12 | 13)
							mode="5G"
							;;
						2 | 4 | 5 | 6)
							mode="3G"
							;;
						0 | 1 | 3 | 8)
							mode="2G"
							;;
						*)
							;;
						esac
					fi
				fi
				if [ -z "$mode" ]; then
					hcsqString=$(at_command "AT\^HCSQ?" "OK" "1" | grep "HCSQ:" | tail -n 1)
					hcsqRat=$(echo "$hcsqString" | sed -n 's/.*"\([^"]*\)".*/\1/p' | tr '[:lower:]' '[:upper:]')
					case "$hcsqRat" in
					LTE)
						mode="4G"
						;;
					NR5G* | 5G*)
						mode="5G"
						;;
					WCDMA | UMTS | HSPA*)
						mode="3G"
						;;
					GSM | GPRS | EDGE)
						mode="2G"
						;;
					*)
						;;
					esac
				fi
				if [ -z "$signalPercentage" ]; then
					signalString=$(at_command "AT+CSQ" "OK" "1" | grep "CSQ:" | tail -n 1)
					signalRSSI=$(echo "$signalString" | awk '{print $2}' | cut -d ',' -f 1 | tr -dc '0-9')
					if echo "$signalRSSI" | grep -Eq '^[0-9]+$' && [ "$signalRSSI" -ge 0 ] && [ "$signalRSSI" -le 31 ]; then
						signalPercentage=$(printf "%.0f\n" $(/data/ftp/uavpal/bin/dc -e "$(echo "$signalRSSI") 1 + 3.13 * p"))%
					fi
				fi
			fi
		fi

		if [ -z "$mode" ]; then
			mode="Cell"
		fi
		if [ -z "$signalPercentage" ]; then
			signalPercentage="n/a"
		fi
		signal="$mode/$signalPercentage"
	fi
	temp=""
	tempfile="/sys/devices/platform/p7-temperature/iio:device1/in_temp7_p7mu_raw"
	if [ -f $tempfile ]; then
		temp=$(cat $tempfile)"°C"
	fi

	droneLabel="${droneName} (${signal} ${altitude_rel}m ${bat_volts}V/${bat_percent}% ${temp} ${latency}${ztConn})"
	ulogger -s -t uavpal_glympse "... updating Glympse label ($(date +%Y-%m-%d-%H:%M:%S)): $droneLabel"

	/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -H "Authorization: Bearer ${access_token}" -X POST -d "[[$(date +%s)000,$(gpsDecimal $lat $latdir),$(gpsDecimal $long $longdir),$speed,$heading]]" "https://api.glympse.com/v2/tickets/$ticket/append_location" &
	curl_pid_location=$!
	/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -H "Authorization: Bearer ${access_token}" -X POST -d "[{\"t\": $(date +%s)000, \"pid\": 0, \"n\": \"name\", \"v\": \"${droneLabel}\"}]" "https://api.glympse.com/v2/tickets/$ticket/append_data" &
	curl_pid_data=$!

	if test -n "$ip_sc2"; then
		ping -c 1 $ip_sc2 |grep 'bytes from' | cut -d '=' -f 4 | tr -d ' ms' > /tmp/sc2ping &
		ping_pid=$!
	else
		rm /tmp/sc2ping 2>/dev/null
		ping_pid=""
	fi
	sleep 5
	wait $curl_pid_location 2>/dev/null
	wait $curl_pid_data 2>/dev/null
	if [ -n "$ping_pid" ]; then
		wait $ping_pid 2>/dev/null
	fi
done

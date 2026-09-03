#!/bin/sh

#History:
# 2021/1/6   Add function station_check_time
#			 Add WAN and WWAN are get the gateway at staic 
# 2021/1/20  Add AT&T disconnection detection
# 2022/10/18 Add gsm check

DEVPATH="/sys/bus/usb/devices"
#VID=12d1
#PID=1001 
WAN_IF='eth1' # enter name of WAN interface
WAN_GW=""
RETRY_WAN_GW=0

#WiFi Interface
WIFI_IF='wlan0-2'
WIFI_GW=""
RETRY_WIFI_GW=0
wifi_ip=""
check_link_threshold=0
check_interval=$(uci get system.@system[0].iot_interval)
if [ -z "$check_interval" ]; then
	check_interval=15
fi

GSM_IF="3g-cellular" # 3g interface
GSM_IMSI=""
ENABLE_USAGE="0"

PING_HOST='1.1.1.1' # enter IP of first host to check.
PING_HOST2='8.8.8.8' # enter IP of second host to check.
PING_WIFI_HOST="8.8.4.4" # Use this IP to check WiFi Connection. 
PING_WAN_HOST="139.130.4.5"  # Use this IP to check WAN connection (ns1.telstra.net)

check_gsm=0
gsm_poweroff_time=""
gsm_mode=0
gsm_enable=`uci get network.cellular.auto`
toggle_3g_time=90
last_check_3g_dial=0
RETRY_POWEROFF_GSM=5
RETRY_REBOOT_GSM=61
ONE="1"
ZERO="0"
retry_gsm=0
iot_online="1"
offline_flag="1"
is_lps8=`hexdump -v -e '11/1 "%_p"' -s $((0x908)) -n 11 /dev/mtd6 | grep -c -E "lps8|los8|ig16|ps8n|ps8g|os8n|os8l|ps8l"`
is_ps8n=`hexdump -v -e '11/1 "%_p"' -s $((0x908)) -n 11 /dev/mtd6 | grep -c -E "ps8n|ps8l"`

station_check_time=1

# Custom recovery for prolonged cellular pending/setup failure.
CELLULAR_PENDING_FAILURE_LIMIT=5
CELLULAR_RECOVERY_COOLDOWN=300
CELLULAR_PPP_STOP_TIMEOUT=15
CELLULAR_PPP_START_TIMEOUT=60
CELLULAR_MODEM_OFF_TIME=10
CELLULAR_MODEM_BOOT_TIMEOUT=60
CELLULAR_MODEM_START_TIMEOUT=90

cellular_pending_fail_count=0
cellular_last_recovery_time=0

cellular_is_pending()
{
	local status
	status=$(ifstatus cellular 2>/dev/null)
	[ -n "$status" ] || return 1

	echo "$status" | jsonfilter -e '@.pending' 2>/dev/null | grep -q '^true$'
}

cellular_is_up()
{
	local status
	status=$(ifstatus cellular 2>/dev/null)
	[ -n "$status" ] || return 1

	echo "$status" | jsonfilter -e '@.up' 2>/dev/null | grep -q '^true$'
}

find_cellular_pppd_pid()
{
	local pid
	local cmdline
	local cellular_tty

	cellular_tty=$(uci -q get network.cellular.device)

	for pid in $(pgrep pppd 2>/dev/null); do
		[ -r "/proc/$pid/cmdline" ] || continue
		cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline")

		if [ -n "$cellular_tty" ] && echo "$cmdline" | grep -Fq "$cellular_tty"; then
			echo "$pid"
			return 0
		fi

		if echo "$cmdline" | grep -Eq 'ipparam[[:space:]]+cellular|3g-cellular'; then
			echo "$pid"
			return 0
		fi
	done

	return 1
}

cleanup_stale_cellular_lock()
{
	local cellular_tty
	local lock_file
	local lock_pid

	cellular_tty=$(uci -q get network.cellular.device)
	[ -n "$cellular_tty" ] || return 0

	lock_file="/var/lock/LCK..$(basename "$cellular_tty")"
	[ -f "$lock_file" ] || return 0

	lock_pid=$(tr -cd '0-9' < "$lock_file" 2>/dev/null)
	[ -n "$lock_pid" ] || return 0

	if ! kill -0 "$lock_pid" 2>/dev/null; then
		logger -t iot_keep_alive "Removing stale cellular serial lock $lock_file for dead PID $lock_pid"
		rm -f "$lock_file"
	fi
}

check_cellular_internet()
{
	local cell_dev

	cell_dev=$(ifstatus cellular 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)

	[ -n "$cell_dev" ] || return 1
	ip link show "$cell_dev" >/dev/null 2>&1 || return 1

	fping -I "$cell_dev" "$PING_HOST" 2>/dev/null | grep -q alive && return 0
	fping -I "$cell_dev" "$PING_HOST2" 2>/dev/null | grep -q alive
}

power_cycle_cellular_modem()
{
local cellular_tty
local gpio_value
local i
local ppp_pid

gpio_value="/sys/class/gpio/gpio${Cellular_CTL}/value"
cellular_tty=$(uci -q get network.cellular.device)

if [ -z "$Cellular_CTL" ] || [ ! -w "$gpio_value" ]; then
logger -t iot_keep_alive "Cellular modem power-cycle aborted: control GPIO unavailable"
return 1
fi

logger -t iot_keep_alive "Stage 2 cellular recovery: power-cycling GSM module"

ifdown cellular

i=0
while [ "$i" -lt "$CELLULAR_PPP_STOP_TIMEOUT" ]; do
ppp_pid=$(find_cellular_pppd_pid)
[ -z "$ppp_pid" ] && break
sleep 1
i=$((i + 1))
done

ppp_pid=$(find_cellular_pppd_pid)

if [ -n "$ppp_pid" ]; then
logger -t iot_keep_alive "Stage 2: terminating cellular pppd PID $ppp_pid before modem power-cycle"
kill -TERM "$ppp_pid" 2>/dev/null
sleep 2

if kill -0 "$ppp_pid" 2>/dev/null; then
logger -t iot_keep_alive "Stage 2: cellular pppd PID $ppp_pid did not stop; sending SIGKILL"
kill -KILL "$ppp_pid" 2>/dev/null
fi
fi

cleanup_stale_cellular_lock

logger -t iot_keep_alive "Stage 2: turning GSM module off"
echo 1 > "$gpio_value"
sleep "$CELLULAR_MODEM_OFF_TIME"

logger -t iot_keep_alive "Stage 2: turning GSM module on"
echo 0 > "$gpio_value"

[ -n "$cellular_tty" ] || cellular_tty="/dev/ttyUSB3"

i=0
while [ "$i" -lt "$CELLULAR_MODEM_BOOT_TIMEOUT" ]; do
if [ -e "$cellular_tty" ]; then
logger -t iot_keep_alive "Cellular modem serial device $cellular_tty restored"
break
fi

sleep 5
i=$((i + 5))
done

if [ ! -e "$cellular_tty" ]; then
logger -t iot_keep_alive "Cellular modem serial device did not return after power-cycle; handing cellular back to netifd"
ifup cellular
return 1
fi

ifup cellular

i=0
while [ "$i" -lt "$CELLULAR_MODEM_START_TIMEOUT" ]; do
if cellular_is_up && check_cellular_internet; then
logger -t iot_keep_alive "Stage 2 modem power-cycle recovery successful"
cellular_pending_fail_count=0
return 0
fi

sleep 5
i=$((i + 5))
done

logger -t iot_keep_alive "Stage 2 modem power-cycle finished without stable Internet"
return 1
}
recover_pending_cellular_ppp()
{
local ppp_pid
local i

logger -t iot_keep_alive "Cellular has remained pending; starting Stage 1 targeted PPP recovery"

ifdown cellular

i=0
while [ "$i" -lt "$CELLULAR_PPP_STOP_TIMEOUT" ]; do
ppp_pid=$(find_cellular_pppd_pid)
[ -z "$ppp_pid" ] && break
sleep 1
i=$((i + 1))
done

ppp_pid=$(find_cellular_pppd_pid)

if [ -n "$ppp_pid" ]; then
logger -t iot_keep_alive "Terminating cellular pppd PID $ppp_pid"
kill -TERM "$ppp_pid" 2>/dev/null
sleep 2

if kill -0 "$ppp_pid" 2>/dev/null; then
logger -t iot_keep_alive "Cellular pppd PID $ppp_pid did not stop; sending SIGKILL"
kill -KILL "$ppp_pid" 2>/dev/null
fi
fi

cleanup_stale_cellular_lock

ifup cellular

i=0
while [ "$i" -lt "$CELLULAR_PPP_START_TIMEOUT" ]; do
if cellular_is_up && check_cellular_internet; then
logger -t iot_keep_alive "Stage 1 cellular PPP recovery successful"
cellular_pending_fail_count=0
return 0
fi

sleep 5
i=$((i + 5))
done

logger -t iot_keep_alive "Stage 1 cellular PPP recovery failed; escalating to modem power-cycle"
power_cycle_cellular_modem
}
cellular_pending_recovery_tick()
{
	local now

	now=$(date +%s)

	if cellular_is_up; then
		cellular_pending_fail_count=0
		return 0
	fi

	if ! cellular_is_pending; then
		cellular_pending_fail_count=0
		return 0
	fi

	if [ "$cellular_last_recovery_time" -gt 0 ] && \
	   [ $((now - cellular_last_recovery_time)) -lt "$CELLULAR_RECOVERY_COOLDOWN" ]; then

		cellular_pending_fail_count=0
		logger -t iot_keep_alive "Cellular recovery cooldown active; leaving Dragino/netifd retry logic in control"
		return 0
	fi

	cellular_pending_fail_count=$((cellular_pending_fail_count + 1))

	logger -t iot_keep_alive "Cellular pending check $cellular_pending_fail_count of $CELLULAR_PENDING_FAILURE_LIMIT"

	[ "$cellular_pending_fail_count" -ge "$CELLULAR_PENDING_FAILURE_LIMIT" ] || return 0

	cellular_last_recovery_time=$now
	cellular_pending_fail_count=0

	recover_pending_cellular_ppp
}

board=`cat /var/iot/board`
if [ "$board" = "LG01" ] || [ "$board" = "LG02" ];then
	Cellular_CTL=1
else
	Cellular_CTL=15
fi

if [ ! -d /sys/class/gpio/gpio$Cellular_CTL  ]; then
	echo $Cellular_CTL > /sys/class/gpio/export
	echo out > /sys/class/gpio/gpio$Cellular_CTL/direction
fi

chk_internet_connection()
{
	global_ping="$ZERO"
	global_ping=$( echo $(fping $PING_HOST || fping $PING_HOST2 )|grep alive -c)
	echo "$global_ping" > /var/iot/internet                                                                       
}

chk_eth1_connection()
{
local proto

wan_ping="$ZERO"
if [ `ifconfig | grep $WAN_IF -c` -gt 0 ];then
	#wan_ip="`ifconfig "$WAN_IF" | grep "inet " | awk -F'[: ]+' '{ print $4 }'`"
	wan_ip=$(ip addr show "$WAN_IF" | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
	if [ -n "$wan_ip" ]; then
		#Try to get WAN GW 
		proto=`uci get network.wan.proto`
		if [ -z $WAN_GW ] && [ "`uci get network.wan.proto`" = "dhcp" ] && [ $RETRY_WAN_GW -lt 5 ];then
			ifup wan
			RETRY_WAN_GW=`expr $RETRY_WAN_GW + 1`
			logger -t iot_keep_alive "Retry $RETRY_WAN_GW to get wan gateway"
			sleep 20
			WAN_GW=`ip route | grep "$WAN_IF" | grep default | awk '{print $3;}'`	
			[ -n $WAN_GW ] && ip route add $PING_WAN_HOST via $WAN_GW dev $WAN_IF
		elif [ -z $WAN_GW ] && [ "`uci get network.wan.proto`" = "static" ];then
			WAN_GW=`uci get network.wan.gateway`
			[ -n $WAN_GW ] && ip route add $PING_WAN_HOST via $WAN_GW dev $WAN_IF
			logger -t iot_keep_alive "$WAN_GW"
		fi

		# Ping Host to check eth1 connection. 
		if [ "`ip route | grep $PING_WAN_HOST | awk '{print $3;}'`" = "$WAN_GW"  ];then
			logger -t iot_keep_alive "Ping WAN via $WAN_GW"
			wan_ping=`fping $PING_WAN_HOST | grep -c alive`
		elif [ "`uci get network.wan.proto`" = "static" ]; then
			wan_ping=`fping $WAN_GW | grep -c alive`
		fi 
	fi
fi
}

chk_wlan0_connection()
{
    wifi_ping="$ZERO"

	if [ `ifconfig | grep $WIFI_IF -c` -gt 0 ];then 
		wifi_ip="`ifconfig "$WIFI_IF" | grep "inet " | awk -F'[: ]+' '{ print $4 }'`"
		

		if [ -n "$wifi_ip" ]; then
			#Try to get WiFi GW 
			if [ -z $WIFI_GW ] && [ "`uci get network.wwan.proto`" = "dhcp" ] && [ $RETRY_WIFI_GW -lt 5 ];then
				ifup wwan
				RETRY_WIFI_GW=`expr $RETRY_WIFI_GW + 1`
				logger -t iot_keep_alive "Retry $RETRY_WIFI_GW to get wifi GW"
				sleep 20
				WIFI_GW=`ip route | grep "$WIFI_IF" | grep default | awk '{print $3;}'` # get IP for default gateway on WIFI interface	
				[ -n $WIFI_GW ] && ip route add $PING_WIFI_HOST via $WIFI_GW dev $WIFI_IF
			
				
			elif [ -z $WIFI_GW ] && [ "`uci get network.wwan.proto`" = "static" ] && [ $RETRY_WIFI_GW -lt 5 ];then
				WIFI_GW='uci get network.wwan.gateway'
				[ -n $WIFI_GW ] && ip route add $PING_WIFI_HOST via $WIFI_GW dev $WIFI_IF
			fi
			
			# Ping  Host to check wifi connection. 
			if [ "`ip route | grep $PING_WIFI_HOST | awk '{print $3;}'`" = "$WIFI_GW"  ];then
				logger -t iot_keep_alive "Ping WiFi via $WIFI_GW"
				wifi_ping=`fping $PING_WIFI_HOST | grep -c alive`
			elif [ "`uci get network.wwan.proto`" = "static" ]; then
				wifi_ping= `fping $WIFI_GW | grep -c alive`
			fi 
		fi
	fi 	
}

reload_iot_service() {
    local type=$1
    local cur_reload_time=$(date +%s)

    if [ -z "$last_reload_time" ]; then
        last_reload_time=0
    fi

    if [ "$server_type" == "lorawan" ]; then
		if [ "$type" == "offline" ] && [ $((cur_reload_time - last_reload_time)) -gt 180 ]; then
			/etc/init.d/lora_gw restart
			logger -t iot_keep_alive "Reload completed. Current Mode: $mode, Date: $cur_reload_time"
			last_reload_time=$(date +%s)
		else
			logger -t iot_keep_alive "Reload not completed. Current Mode: $mode, Date: $cur_reload_time"
		fi
    fi
}

check_3g_connection()
{

	if [ -z "$GSM_IMSI" ]; then # Get Cellular GSM_IMSI
		killall comgt;
		GSM_IMSI='gcom -d /dev/ttyModemAT -s /etc/gcom/getimsi.gcom | cut -c 1,2,3,4,5,6'
		if [ -z "$(echo $GSM_IMSI | sed -n "/^[0-9]\+$/p")" ];then 
			GSM_IMSI=""
		fi
	fi

    #echo "3g"
	GSM_IF=`ifconfig |grep "3g-" | awk '{print $1}'` # 3g interface
	gsm_ping="$ZERO"
	[ -z $GSM_IF ] && return
    #modem_chk=`lsusb |grep ${VID}:${PID}`
    gsm_chk=`ifconfig |grep "$GSM_IF"`
    gsm_ip=`ifconfig | grep '3g-' -A 1 | grep 'inet' | awk -F'[: ]+' '{ print $4 }'`
    [ -n "$gsm_ip" ] && logger -t iot_keep_alive "Ping GSM $gsm_ip" && gsm_ping=`fping -I $GSM_IF $PING_HOST | grep -c alive`
	if [ "$gsm_ping" -eq "$ZERO" ];then
		gsm_ping=`fping -I $GSM_IF $PING_HOST2 | grep -c alive`
	fi
	[ "$gsm_ping" -gt "$ZERO" ] && logger -t iot_keep_alive "GSM Cellular is alive"
	GSM_GW=`ip route show| grep $GSM_IF | awk '{print $1}'`
	#echo "3g-end"
}

gsm3g_connect()
{
        # this function connects modem to 3G network -
        # usually used when we lose internet connection on WAN interface and failover occurs
        # or when 3G connection is disconnected by operator (example: Aero2 operator in Poland)
        logger -t iot_keep_alive "Connecting to 3G network..."
        ifup $GSM_NAME
        echo 1 > /root/gsm_mode
        sleep 15
}
 
gsm3g_disconnect()
{
        # this function disconnects modem from 3G network -
        # usually used when we recover internet connection on WAN interface
        logger -t iot_keep_alive "Disconnecting from 3G network..."
        ifdown $GSM_NAME
        echo 0 > /root/gsm_mode
        sleep 5
}
 
use_gsm_as_gateway()
{
        # this function add default gateway for 3G interface -
        # usually executed when moving internet connection from WAN to 3G interface
        logger -t iot_keep_alive "Moving internet connection to $GSM_IF (3G) via gateway $GSM_GW..."
      #  previous_gw=`ip route show | grep default | awk '{print $3}'`
      #  [ -n "$previous_gw" ] && ip route del $previous_gw
        ip route del default

        ip route add default via $GSM_GW dev $GSM_IF proto static
        #ip route add $GSM_GW dev $GSM_IF proto static scope link src $gsm_ip
}
 
use_wan_as_gateway()
{
        # this function remove default gateway for 3G interface -
        # usually executed when moving internet connection from 3G to WAN interface
        logger -t iot_keep_alive "Moving internet connection to $WAN_IF (WAN) via gateway $WAN_GW..."

        ip route del default
        ip route add default via $WAN_GW dev $WAN_IF proto static src $wan_ip
        #ip route add $WAN_GW dev $WAN_IF proto static scope link src $wan_ip

}

use_wifi_as_gateway()
{
        # this function remove default gateway for 3G interface -
        # usually executed when moving internet connection from 3G to WIFI interface
        logger -t iot_keep_alive "Moving internet connection to $WIFI_IF (WIFI) via gateway $WIFI_GW..."		
        ip route del default
        ip route add default via $WIFI_GW dev $WIFI_IF proto static src $wifi_ip
        #ip route add $WIFI_GW dev $WIFI_IF proto static scope link src $wifi_ip
}

gsm_poweroff()
{
    logger -t iot_keep_alive "Turning off GSM module"
    echo 1 > /sys/class/gpio/gpio$Cellular_CTL/value
}

gsm_poweron()
{
    logger -t iot_keep_alive "Turning on GSM module"
    echo 0 > /sys/class/gpio/gpio$Cellular_CTL/value
}

update_gateway()
{
    pid=$(cat "/var/run/udhcpc-$1.pid")
    kill -s SIGUSR2 "$pid" #release lease
    sleep 5
    kill -s SIGUSR1 "$pid" #get new lease
    sleep 5
}

gsm_status_check()
{
	local current_time
	local disable_time
	local gsm_enable
	gsm_enable=$(uci -q get network.cellular.auto)
	if [ "$gsm_enable" == "0" ]; then
		return 0
	fi

	if [ "$(cat /sys/class/gpio/gpio$Cellular_CTL/value)" == "0" ]; then
		gsm_hangup=$(logread |grep -e "Modem hangup" -c)
		if [ "$gsm_hangup" -ge "6" ]; then
			#uci set network.cellular.auto=0
			logger -t iot_keep_alive "Cellular network is not working properly"
			echo "Cellular multiple dialing failures detected, But the gateway can be accessed through other interfaces, so $(date) cellular is automatically turn down for the IoT service to work, and will try to dial again in 2 hours Please check the status of your SIM card" > /var/cell_poweroff.txt
			gsm_poweroff
			echo $(date +%s) > /usr/share/cell_disable.txt
		fi
	elif [ -f "/usr/share/cell_disable.txt" ]; then
		current_time=$(date +%s)
		disable_time=$(cat /usr/share/cell_disable.txt)
		if [  `expr $current_time - $disable_time` -gt 7200  ]; then
			gsm_poweron
			rm /usr/share/cell_disable.txt
		fi
	fi
}

toggle_3g()
{
    GSM_IF_SUF=`ifconfig |grep '3g-' | awk '{print $1}' | awk -F '-' '{print $2}'`
	ifdown $GSM_IF_SUF
    sleep 240
    ifup $GSM_IF_SUF
    logger -t iot_keep_alive "Restart 3G Interface"
}

enable_ue_usage()
{
	killall comgt;
	gcom -d /dev/ttyModemAT -s /etc/gcom/enable-usage.gcom > /var/iot/cell_usage.txt
	if [ `cat /var/iot/cell_usage.txt | grep "Start" -c` -ge "1" ]; then
		if [ `cat /var/iot/cell_usage.txt | grep "successfully" -c` -ge "1"]; then
			ENABLE_USAGE="1"
		fi
	fi

}

station_time_check()
{
if [ "$server_type" = "station" ] && [ -f /var/iot/station.log ]; then
	if [ "$station_check_time" = "1" ]; then 
		local syscurrent_time="$(date +"%Y-%m-%d")" 
		local stationcurrent_time="$(tail -n 1 /var/iot/station.log|grep -E -o '20[0-9]{2}-[0-9]{2}-[0-9]{2}')"
		if [ -z $syscurrent_time ] || [ -z $stationcurrent_time ]; then
			return
		fi
		local t1="$(date -d "$syscurrent_time" +%s)" 
		local t2="$(date -d "$stationcurrent_time" +%s)"
		if [ "$t1" -ne "$t2" ]; then
			logger -t iot_keep_alive "Detection of abnormal station times, so reload station process"
			/usr/bin/reload_iot_service.sh &
		fi 
		station_check_time=0
	fi 
else
	station_check_time=0
fi
}

chk_wlan0_client()
{
	local ap_carrier
    local sta_carrier
    local sta_ssid
    local sta_reload
    local sta_disable
    local sta_scan
    local sta_auth
    local nolink
    local i

    sta_reload=$(uci -q get wireless.sta_0.reload)
    if [ "$sta_reload" = "1" ]; then
        sta_ssid=$(uci get wireless.sta_0.ssid)
        sta_scan=$(iwinfo radio0 scan | grep "$sta_ssid" -c)
        if [ "$sta_scan" -gt 0 ]; then
            wifi
            uci set wireless.sta_0.reload=0
            uci commit wireless  
        fi
		return
    fi

    ap_carrier=$(ubus call network.device status '{"name":"wlan0"}' | grep '"carrier"'| awk '{print $2}' | sed 's/,//g')
    sta_disable=$(uci get wireless.sta_0.disabled)
    if [ "$ap_carrier" = "true" ] || [ "$sta_disable" = "1" ]; then
		echo 1 > /sys/class/gpio/gpio27/value
        return
    fi

    sta_carrier=$(ubus call network.device status '{"name":"wlan0-2"}' | grep '"carrier"'| awk '{print $2}' | sed 's/,//g')
    if [ "$sta_carrier" = "true" ]; then
        return
    fi

    sta_ssid=$(uci get wireless.sta_0.ssid)
    sta_scan=$(iwinfo radio0 scan | grep "$sta_ssid" -c)
    if [ "$sta_scan" == 0 ]; then
		sta_no_scan=$((sta_no_scan+1))
		if [ $sta_no_scan -gt 3 ]; then
			uci set wireless.sta_0.disabled=1
			uci set wireless.sta_0.reload=1
			#uci set wireless.sta_0.reload_time=$(date +%s)
			uci commit wireless
			wifi && sleep 5
			uci set wireless.sta_0.disabled=0
			uci commit wireless
			sta_no_scan=0
		fi
    else
        sta_carrier=$(ubus call network.device status '{"name":"wlan0-2"}' | grep '"carrier"'| awk '{print $2}' | sed 's/,//g')
        i=0
        nolink=0
        while [ $i -le 6 ]
        do
            sta_carrier=$(ubus call network.device status '{"name":"wlan0-2"}' | grep '"carrier"'| awk '{print $2}' | sed 's/,//g')
            if [ "$sta_carrier" = "false" ]; then
                nolink=$((nolink+1))
            fi
            i=$(($i+1))
            sleep 3
        done
        sta_auth=$(dmesg -r | grep "wlan0-2" | grep 4WAY_HANDSHAKE_TIMEOUT -c)
        if [ "$nolink" -gt "5" ] && [ "$sta_auth" -gt 3 ]; then
            dmesg -c > /dev/null 2>&1
            uci set wireless.sta_0.disabled=1
            #uci set wireless.sta_0.reload=1
            uci set wireless.sta_0.reload_time=$(date +%s)
            uci commit wireless
            wifi && sleep 5
            uci set wireless.sta_0.disabled=0
            uci commit wireless
			echo "Wifi client authentication failures, due to the wrong password" > /usr/share/wifi_handle.txt
        fi
    fi
}

while :
do

	chk_internet_connection

	# Only observe Dragino/netifd cellular setup state.
	# Do not select cellular or change routes/metrics.
	cellular_pending_recovery_tick

	# Control receive size < 2M
	receive_size=`du -h -k /var/iot/ -d 0 | awk '{print $1}'`
	if [ $receive_size -gt 1024 ];then
		rm -rf /var/iot/receive/*
		rm -rf /var/iot/channels/*
		rm -f /var/iot/station.log
	fi

	case $global_ping in
	1)
		has_internet_flag_time=$(date +%s) #record the time when the network is available
		ROUTE_DF=`ip route | grep default | awk '{print $5}'`
		logger -t iot_keep_alive "Internet Access OK: via $ROUTE_DF"
		has_internet=1
		station_time_check
	;;
	0)
		logger -t iot_keep_alive "Internet fail. Check interfaces for network connection"
		has_internet=0
		internetdetect=$(uci -q get system.@system[0].internet_detect)
		if [ "$internetdetect" == "checked" ] || [ -z $internetdetect ];then                                                                                                                                                                                                     
            cur_flag_time=$(date +%s)                                                                                                                     
            if [ -z $has_internet_flag_time ] ; then                                                                                                       
                    has_internet_flag_time=$(date +%s)                                                                                                    
            else                                                                                                                                                                                                              
                    time_diff=$((cur_flag_time - has_internet_flag_time))                                                                       
                    if [ $time_diff -gt 900 -a $time_diff -le 3000 ]; then                                                                            
                            reboot   #Execute reboot if the gateway loses Internet connectivity for more than 900 seconds                                 
                    fi                                                                                                                                                                         
            fi                                                                                                                                                                                 
        fi

		if [ "$iot_online" = "0" ]; then
			logger -t iot_keep_alive "No Internet Connection and IoT Service offline"
			if [ $server_type == "lorawan" ] || [ $server_type == "station" ]; then
				if [ "`uci get network.cellular.auto`" = "1" ];then
					check_3g_connection
					if [ "$gsm_ping" -eq "$ZERO" ]; then
						retry_gsm=`expr $retry_gsm + 1`
						if [ $(expr $retry_gsm % $RETRY_POWEROFF_GSM) -eq 0 ];then
							gsm_poweroff
							sleep 5
							gsm_poweron
						elif [ "`expr $retry_gsm % $RETRY_REBOOT_GSM`" -eq 0 ];then
							reboot
						fi
					fi
				fi
			fi
		else
			logger -t iot_keep_alive "No Internet Connection but IoT Service Online,No Action"
		fi 

	;;
	esac

	case $server_type in
		lorawan)
		if [ -z $(pgrep fwd) ];then
			logger -t iot_keep_alive "IoT Server is not Runing, So Reload IoT Service_flag"
			reload_iot_service offline
		else
			status_count=$(sqlite3 /var/lgwdb.sqlite "select * from gwdb where key like '/service/lorawan/server/network';")
			if [ -z $status_count ]; then
				status_count=$(sqlite3 /var/lgwdb.sqlite "select * from gwdb;"|grep network |grep online -c)
			else
				status_count=$(sqlite3 /var/lgwdb.sqlite "select * from gwdb where key like '/service/lorawan/server/network';" |grep online -c)
			fi

			if [ $status_count -gt 0 ];then
				echo "online" > /var/iot/status
			else
				offline_count=$(sqlite3 /var/lgwdb.sqlite "select * from gwdb;"|grep network |grep offline -c)
				if [ $offline_count -ge 15 ]; then
					echo "offline" > /var/iot/status
				fi
			fi
		fi
		iot_online=`cat /var/iot/status | grep online -c`
		;;

		station)
		station_status=$(cat /var/tmp/station_status.log )
		iot_online=1
		iot_status=online
		if [ $station_status == OFFLINE ]; then
			iot_online=0
			iot_status=offline
			logger -t iot_keep_alive "Detects a site TCP connection failure and switches the IoT state to offline"
		fi
		echo "$iot_status" > /var/iot/status
		;;

		mqtt)
		if [ "$(uci get mqtt.common.sub_enable)" == "checked" ]; then
			mqtt_subpid=$(pgrep mosquitto_sub)                                                                  
			if [ -z $mqtt_subpid ]; then                                    
				/etc/init.d/iot reload                                  
			fi
		fi                                                  
		;;
	esac

	#Show LED status
	# echo 1 > /sys/class/leds/dragino2\:red\:system/brightness GPIO28
	# LPS8:GPIO21: RED, GPIO28: Blue GLobal
	# LGxx: GPIO21: N/A. GPIO28: RED Global
	# LIG16: GPIO21(LOW): GREEN; GPIO28: RED; GPIO22(Low), RED
	# Check IoT Connection first. 
	#echo "iot"
	if [ "$is_lps8" == "1" ];then
		if [ ! -d /sys/class/gpio/gpio21/ ]; then 
			echo 21 > /sys/class/gpio/export
			echo out > /sys/class/gpio/gpio21/direction
		fi
	fi
	if [ "$is_ps8n" == "1" ];then
		if [ ! -d /sys/class/gpio/gpio27/ ]; then 
			echo 27 > /sys/class/gpio/export
			echo out > /sys/class/gpio/gpio27/direction
		fi
	fi

	/usr/bin/blink-stop
	if [ $iot_online == 1 ]; then
		# IoT Connection is ok
		[ $is_lps8 = 1 ] && echo 0 > /sys/class/gpio/gpio21/value
		echo 1 > /sys/class/leds/dragino2\:red\:system/brightness
		[ "$offline_flag" == "1" ] && offline_flag="0" && echo "`date`: switch to online" >> /var/status_log
	elif [ $has_internet -eq 1 ]; then
		# IoT Connection Fail, but Internet Up
		/usr/bin/blink-start 100   #GPIO28 blink, periodically: 200ms
		[ "$is_lps8" == "1" ] && echo 0 > /sys/class/gpio/gpio21/value
		if [ $offline_flag == 0 ]; then
			echo "`date`: switch to offline" >> /var/status_log
			offline_flag="1"
		elif [ $offline_flag == 1 ] && [ $server_type  == "lorawan" ]; then
			logger -t iot_keep_alive "Reload IoT Service due to offline status"
			reload_iot_service offline
			sleep 30
		fi
	else
		# IoT Connection Fail, Internet Down
		echo 0 > /sys/class/leds/dragino2\:red\:system/brightness
		[ $is_lps8 == 1 ] && echo 1 > /sys/class/gpio/gpio21/value
	fi

	AP_ENABLE=$(uci get wireless.ap_0.disabled)
	if [ "$AP_ENABLE" == "0" ]; then
		chk_wlan0_client
	else
		echo 0 > /sys/class/gpio/gpio27/value
	fi

	server_type=$(uci -q get gateway.general.server_type)
	sleep "$check_interval"
done

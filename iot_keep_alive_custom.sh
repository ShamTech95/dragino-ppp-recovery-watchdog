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

# Custom cellular PPP recovery policy
PPP_FAILURE_LIMIT=5
PPP_STOP_TIMEOUT=15
PPP_START_TIMEOUT=180
PPP_COOLDOWN_CHECK_INTERVAL=300
PPP_COOLDOWN_1=1800
PPP_COOLDOWN_2=3600
PPP_COOLDOWN_3=7200
AUTO_REBOOT_GUARD=21600
AUTO_REBOOT_TIMESTAMP_FILE="/root/.iot_last_auto_reboot"

ppp_fail_count=0
ppp_recovery_stage=0
ppp_state="NORMAL"
ppp_wait_deadline=0
ppp_cooldown_deadline=0
ppp_next_passive_check=0
last_auto_reboot=0

if [ -f "$AUTO_REBOOT_TIMESTAMP_FILE" ]; then
    last_auto_reboot=$(cat "$AUTO_REBOOT_TIMESTAMP_FILE" 2>/dev/null)
    case "$last_auto_reboot" in
        ''|*[!0-9]*) last_auto_reboot=0 ;;
    esac
fi

ONE="1"
ZERO="0"
retry_gsm=0
iot_online="1"
offline_flag="1"
is_lps8=`hexdump -v -e '11/1 "%_p"' -s $((0x908)) -n 11 /dev/mtd6 | grep -c -E "lps8|los8|ig16|ps8n|ps8g|os8n|os8l|ps8l"`
is_ps8n=`hexdump -v -e '11/1 "%_p"' -s $((0x908)) -n 11 /dev/mtd6 | grep -c -E "ps8n|ps8l"`

station_check_time=1

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

get_cellular_l3_dev()
{
    local cell_dev
    cell_dev=""

    if command -v ifstatus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
        cell_dev=$(ifstatus cellular 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
    fi

    if [ -z "$cell_dev" ]; then
        cell_dev=$(ifconfig 2>/dev/null | awk '/^3g-|^ppp[0-9]|^wwan/{print $1; exit}')
    fi

    [ -z "$cell_dev" ] && cell_dev="3g-cellular"
    echo "$cell_dev"
}

cellular_is_active_backhaul()
{
    local cell_dev
    local default_dev

    cell_dev=$(get_cellular_l3_dev)
    default_dev=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')

    [ -n "$cell_dev" ] && [ "$default_dev" = "$cell_dev" ]
}

check_cellular_internet()
{
    local cell_dev
    local gsm_ping

    cell_dev=$(get_cellular_l3_dev)

    if ! ifconfig "$cell_dev" >/dev/null 2>&1; then
        return 1
    fi

    gsm_ping=$(fping -I "$cell_dev" "$PING_HOST" 2>/dev/null | grep -c alive)

    if [ "$gsm_ping" -eq 0 ]; then
        gsm_ping=$(fping -I "$cell_dev" "$PING_HOST2" 2>/dev/null | grep -c alive)
    fi

    [ "$gsm_ping" -gt 0 ]
}

find_cellular_pppd_pid()
{
    local cell_tty
    local pid
    local cmdline

    cell_tty=$(uci -q get network.cellular.device)
    [ -z "$cell_tty" ] && cell_tty="/dev/ttyUSB3"

    for pid in $(pgrep pppd 2>/dev/null); do
        [ -r "/proc/$pid/cmdline" ] || continue

        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)

        if echo "$cmdline" | grep -q "$cell_tty" || \
           echo "$cmdline" | grep -q "ipparam cellular" || \
           echo "$cmdline" | grep -q "3g-cellular"; then
            echo "$pid"
            return 0
        fi
    done

    return 1
}

cleanup_stale_cellular_lock()
{
    local cell_tty
    local tty_base
    local lock_file
    local lock_pid

    cell_tty=$(uci -q get network.cellular.device)
    [ -z "$cell_tty" ] && cell_tty="/dev/ttyUSB3"

    tty_base=$(basename "$cell_tty")
    lock_file="/var/lock/LCK..$tty_base"

    [ -f "$lock_file" ] || return 0

    lock_pid=$(cat "$lock_file" 2>/dev/null | tr -d ' \n\r')

    case "$lock_pid" in
        ''|*[!0-9]*) return 0 ;;
    esac

    if ! kill -0 "$lock_pid" 2>/dev/null; then
        logger -t iot_keep_alive "Removing stale cellular serial lock $lock_file (dead PID: $lock_pid)"
        rm -f "$lock_file"
    fi
}

recover_cellular_ppp()
{
    local ppp_pid
    local waited

    logger -t iot_keep_alive "Starting targeted cellular PPP recovery"

    ifdown cellular 2>/dev/null

    waited=0

    while [ "$waited" -lt "$PPP_STOP_TIMEOUT" ]; do
        ppp_pid=$(find_cellular_pppd_pid)

        [ -z "$ppp_pid" ] && break

        sleep 1
        waited=$((waited + 1))
    done

    ppp_pid=$(find_cellular_pppd_pid)

    if [ -n "$ppp_pid" ] && kill -0 "$ppp_pid" 2>/dev/null; then
        logger -t iot_keep_alive "Cellular pppd still alive after ifdown; sending SIGTERM to PID $ppp_pid"

        kill -15 "$ppp_pid" 2>/dev/null
        sleep 2

        if kill -0 "$ppp_pid" 2>/dev/null; then
            logger -t iot_keep_alive "Cellular pppd still alive after SIGTERM; sending SIGKILL to PID $ppp_pid"
            kill -9 "$ppp_pid" 2>/dev/null
        fi
    fi

    cleanup_stale_cellular_lock

    ifup cellular 2>/dev/null

    ppp_wait_deadline=$(($(date +%s) + PPP_START_TIMEOUT))
    ppp_state="PPP_WAIT"
}

reset_ppp_recovery()
{
    if [ "$ppp_state" != "NORMAL" ] || [ "$ppp_fail_count" -ne 0 ]; then
        logger -t iot_keep_alive "Cellular Internet recovered; PPP recovery state reset to NORMAL"
    fi

    ppp_fail_count=0
    ppp_recovery_stage=0
    ppp_state="NORMAL"
    ppp_wait_deadline=0
    ppp_cooldown_deadline=0
    ppp_next_passive_check=0
}

request_guarded_reboot()
{
    local now
    local elapsed
    local remaining

    if check_cellular_internet; then
        logger -t iot_keep_alive "Final cellular Internet check passed; reboot cancelled"
        reset_ppp_recovery
        return
    fi

    now=$(date +%s)

    case "$last_auto_reboot" in
        ''|*[!0-9]*) last_auto_reboot=0 ;;
    esac

    if [ "$last_auto_reboot" -eq 0 ]; then
        elapsed=$AUTO_REBOOT_GUARD
    elif [ "$now" -ge "$last_auto_reboot" ]; then
        elapsed=$((now - last_auto_reboot))
    else
        elapsed=0
    fi

    if [ "$elapsed" -ge "$AUTO_REBOOT_GUARD" ]; then
        echo "$now" > "$AUTO_REBOOT_TIMESTAMP_FILE"
        last_auto_reboot=$now

        logger -t iot_keep_alive "Final PPP recovery failed; guarded gateway reboot authorized"

        sync
        sleep 3
        reboot
        return
    fi

    remaining=$((AUTO_REBOOT_GUARD - elapsed))

    logger -t iot_keep_alive "Gateway reboot blocked by 6-hour guard ($remaining seconds remaining); passive cellular checks continue"

    ppp_state="REBOOT_GUARD_WAIT"
    ppp_wait_deadline=$((now + remaining))
    ppp_next_passive_check=$now
}

cellular_ppp_recovery_tick()
{
    local now
    local cooldown_seconds

    now=$(date +%s)

    case "$ppp_state" in

        NORMAL)
            if check_cellular_internet; then
                reset_ppp_recovery
                return
            fi

            ppp_fail_count=$((ppp_fail_count + 1))

            logger -t iot_keep_alive "Cellular Internet failure $ppp_fail_count of $PPP_FAILURE_LIMIT"

            if [ "$ppp_fail_count" -ge "$PPP_FAILURE_LIMIT" ]; then
                ppp_recovery_stage=1
                recover_cellular_ppp
            fi
            ;;

        PPP_WAIT)
            if check_cellular_internet; then
                reset_ppp_recovery
                return
            fi

            [ "$now" -lt "$ppp_wait_deadline" ] && return

            if [ "$ppp_recovery_stage" -ge 4 ]; then
                logger -t iot_keep_alive "Final PPP recovery failed; evaluating guarded reboot"
                request_guarded_reboot
                return
            fi

            case "$ppp_recovery_stage" in
                1) cooldown_seconds=$PPP_COOLDOWN_1 ;;
                2) cooldown_seconds=$PPP_COOLDOWN_2 ;;
                3) cooldown_seconds=$PPP_COOLDOWN_3 ;;
            esac

            ppp_cooldown_deadline=$((now + cooldown_seconds))
            ppp_next_passive_check=$now
            ppp_state="COOLDOWN"

            logger -t iot_keep_alive "PPP recovery stage $ppp_recovery_stage failed; entering $cooldown_seconds second cooldown"
            ;;

        COOLDOWN)
            if [ "$now" -ge "$ppp_next_passive_check" ]; then
                ppp_next_passive_check=$((now + PPP_COOLDOWN_CHECK_INTERVAL))

                if check_cellular_internet; then
                    logger -t iot_keep_alive "Cellular Internet returned during cooldown"
                    reset_ppp_recovery
                    return
                fi

                logger -t iot_keep_alive "Cooldown passive cellular Internet check failed; no PPP action taken"
            fi

            [ "$now" -lt "$ppp_cooldown_deadline" ] && return

            ppp_recovery_stage=$((ppp_recovery_stage + 1))

            logger -t iot_keep_alive "Cooldown complete; starting PPP recovery stage $ppp_recovery_stage"

            recover_cellular_ppp

            ppp_cooldown_deadline=0
            ppp_next_passive_check=0
            ;;

        REBOOT_GUARD_WAIT)
            if [ "$now" -ge "$ppp_next_passive_check" ]; then
                ppp_next_passive_check=$((now + PPP_COOLDOWN_CHECK_INTERVAL))

                if check_cellular_internet; then
                    logger -t iot_keep_alive "Cellular Internet recovered while reboot guard was active"
                    reset_ppp_recovery
                    return
                fi
            fi

            if [ "$now" -ge "$ppp_wait_deadline" ]; then
                request_guarded_reboot
            fi
            ;;
    esac
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
if [ "$ppp_state" = "NORMAL" ] && ! cellular_is_active_backhaul; then
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
		fi

		if [ "$iot_online" = "0" ]; then
			logger -t iot_keep_alive "No Internet Connection and IoT Service offline"
			# Cellular PPP recovery is handled below only when cellular is the active backhaul.
		else
			logger -t iot_keep_alive "No Internet Connection but IoT Service Online,No Action"
		fi 

	;;
	esac

	# Custom recovery is intentionally limited to an already-active cellular backhaul.
	# It does not select WAN/WiFi/cellular, change routes, or power the modem down because Ethernet is healthy.

    if [ "$ppp_state" != "NORMAL" ]; then
        if [ "$global_ping" = "1" ] && ! cellular_is_active_backhaul; then
            logger -t iot_keep_alive "Internet restored through non-cellular backhaul; cancelling custom cellular PPP recovery"
            reset_ppp_recovery
        else
            cellular_ppp_recovery_tick
        fi
    elif cellular_is_active_backhaul; then
        cellular_ppp_recovery_tick
    elif [ "$ppp_fail_count" -ne 0 ]; then
        reset_ppp_recovery
	fi

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
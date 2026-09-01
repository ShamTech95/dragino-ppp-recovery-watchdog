#!/bin/sh

# ==============================================================================
# Dragino PPP Recovery Watchdog V2 (Production Refined)
#
# Hardware: Dragino LoRaWAN Gateways (LG08, LPS8, DLOS8, LG01/02, LIG16, etc.)
# Firmware: OpenWrt with pppd cellular backhaul
#
# Recovery Strategy (Non-blocking long recovery timers):
#   BOOT (180s grace) -> NORMAL (15s checks) -> 5 Consecutive Failures
#     -> SOFT_RECOVERY_1 (ifdown, pppd cleanup, ifup -> PPP_START_WAIT 180s)
#     -> SOFT_RECOVERY_2 (2nd targeted restart -> PPP_START_WAIT 180s)
#     -> MODEM_POWER_CYCLE (GPIO 15s -> USB poll -> ifup -> MODEM_START_WAIT 180s)
#     -> COOLDOWN (30 mins -> Return to NORMAL -> 5 fresh failures -> Cycle 2)
#     -> Cycle 2 Failure Evaluation:
#          - NO_INTERFACE / NO_IPV4: Guarded Gateway Reboot (6h)
#          - NO_INTERNET (Carrier Outage): UPSTREAM_OUTAGE_WAIT (No OS reboot / no thrashing)
#
# Backhaul Management (AUTO):
#   - Ethernet Healthy -> ETH_PRIMARY (Modem enters power-saving standby after 3m)
#   - Ethernet Down (~45s) -> CELL_PRIMARY (Wake modem, start PPP & Watchdog)
#   - Zero Ethernet Site -> CELL_PRIMARY automatically
#
# Boundary:
#   - Watchdog checks health strictly via interface-bound probes.
#   - NO route modification (Routing managed by gateway_failover_safe.sh).
# ==============================================================================

# --- Configuration Parameters ---
BOOT_GRACE_SECONDS=180            # 3-minute boot grace period (no failure accumulation)
GSM_FAILURE_LIMIT=5               # Consecutive failures before initiating recovery

# --- Automatic Ethernet / Cellular Backhaul Selection ---
ETH_FAILURE_LIMIT=3               # ~45s at 15s loop before cellular is required
ETH_STABLE_SECONDS=180            # Ethernet must remain healthy for 3 min before cellular standby
CELLULAR_STANDBY_ON_ETH=1         # 1 = power-save cellular when Ethernet is stable

PPP_SOFT_ATTEMPTS=2               # Soft PPP recovery attempts per cycle
PPP_STOP_TIMEOUT=15               # Max seconds to wait for pppd graceful exit
PPP_START_TIMEOUT=180             # Max seconds for PPP link negotiation (deadline)

MODEM_OFF_SECONDS=15              # Hardware power-off duration
MODEM_ENUM_TIMEOUT=30             # Max seconds to poll for configured modem TTY
MODEM_START_TIMEOUT=180           # Max seconds for modem boot + PPP (deadline)

RECOVERY_COOLDOWN=1800            # 30-minute cooldown (1800 seconds)
FAILED_CYCLES_BEFORE_REBOOT=2     # Total complete cycles before guarded reboot

AUTO_REBOOT_GUARD=21600           # 6-hour reboot guard (21600 seconds)
AUTO_REBOOT_TIMESTAMP_FILE="/root/.iot_last_auto_reboot"

PING_HOST="1.1.1.1"               # Primary ping target (Cloudflare DNS)
PING_HOST2="8.8.8.8"              # Secondary ping target (Google DNS)

# --- Original Dragino Global Variables (Preserved for vendor functions) ---
WAN_IF='eth1'
WAN_GW=""
RETRY_WAN_GW=0
wan_ip=""

WIFI_IF='wlan0-2'
WIFI_GW=""
RETRY_WIFI_GW=0
wifi_ip=""

GSM_IF="3g-cellular"
GSM_GW=""
GSM_IMSI=""
ENABLE_USAGE="0"

PING_WIFI_HOST="8.8.4.4"
PING_WAN_HOST="139.130.4.5"

check_link_threshold=0
sta_no_scan=0

# --- State Machine Tracking Variables ---
gsm_fail_count=0
soft_attempt=0
failed_cycles=0
wait_deadline=0
last_auto_reboot=0
cellular_state="NORMAL"
cell_health_reason="OK"
backhaul_mode="AUTO"
eth_fail_count=0
eth_ok_since=0
cellular_standby=0
cellular_required=1
has_internet=0
iot_online="1"
offline_flag="1"
last_reload_time=0
station_check_time=1

# --- Check Interval ---
check_interval=$(uci -q get system.@system[0].iot_interval)
if [ -z "$check_interval" ]; then
	check_interval=15
fi

# --- Hardware Board & GPIO Detection ---
board=$(cat /var/iot/board 2>/dev/null)
is_lps8=$(hexdump -v -e '11/1 "%_p"' -s $((0x908)) -n 11 /dev/mtd6 2>/dev/null | grep -c -E "lps8|los8|ig16|ps8n|ps8g|os8n|os8l|ps8l")
is_ps8n=$(hexdump -v -e '11/1 "%_p"' -s $((0x908)) -n 11 /dev/mtd6 2>/dev/null | grep -c -E "ps8n|ps8l")

is_board_supported_for_gpio()
{
	if [ "$board" = "LG01" ] || [ "$board" = "LG02" ] || [ "$board" = "LG08" ] || \
	   [ "$board" = "LPS8" ] || [ "$board" = "DLOS8" ] || [ "$board" = "LIG16" ] || \
	   [ "$is_lps8" = "1" ] || [ "$is_ps8n" = "1" ]; then
		return 0
	fi
	return 1
}

if [ "$board" = "LG01" ] || [ "$board" = "LG02" ]; then
	Cellular_CTL=1
else
	Cellular_CTL=15
fi

if is_board_supported_for_gpio; then
	if [ ! -d "/sys/class/gpio/gpio$Cellular_CTL" ]; then
		echo "$Cellular_CTL" > /sys/class/gpio/export 2>/dev/null
		echo out > "/sys/class/gpio/gpio$Cellular_CTL/direction" 2>/dev/null
	fi
fi

# Load last automatic reboot timestamp
if [ -f "$AUTO_REBOOT_TIMESTAMP_FILE" ]; then
	last_auto_reboot=$(cat "$AUTO_REBOOT_TIMESTAMP_FILE" 2>/dev/null)
	case "$last_auto_reboot" in
		''|*[!0-9]*) last_auto_reboot=0 ;;
	esac
fi

# ==============================================================================
# Helper Functions
# ==============================================================================

# Check system uptime for boot grace period
is_boot_grace_period()
{
	local uptime_sec
	uptime_sec=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	case "$uptime_sec" in
		''|*[!0-9]*) uptime_sec=0 ;;
	esac
	if [ "$uptime_sec" -lt "$BOOT_GRACE_SECONDS" ]; then
		return 0
	fi
	return 1
}

# Resolve dynamic Layer-3 cellular network device (e.g., 3g-cellular, ppp0, wwan0)
get_cellular_l3_dev()
{
	local dev=""
	if command -v ifstatus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
		dev=$(ifstatus cellular 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
	fi
	if [ -z "$dev" ]; then
		dev=$(ifconfig 2>/dev/null | awk '/^(3g-|ppp|wwan)/{print $1; exit}')
	fi
	if [ -z "$dev" ]; then
		dev="3g-cellular"
	fi
	echo "$dev"
}

# Targeted cellular pppd termination and safe lock cleanup
terminate_cellular_ppp()
{
	local old_ppp_pid=""
	old_ppp_pid=$(pgrep -f "pppd.*cellular" 2>/dev/null | head -n1)
	if [ -z "$old_ppp_pid" ]; then
		old_ppp_pid=$(pgrep -f "pppd.*3g-" 2>/dev/null | head -n1)
	fi

	logger -t iot_keep_alive "Stopping cellular interface (Captured pppd PID: ${old_ppp_pid:-none})"
	ifdown cellular 2>/dev/null

	if [ -n "$old_ppp_pid" ]; then
		local waited=0
		while [ "$waited" -lt "$PPP_STOP_TIMEOUT" ]; do
			if ! kill -0 "$old_ppp_pid" 2>/dev/null; then
				break
			fi
			sleep 1
			waited=$((waited + 1))
		done

		if kill -0 "$old_ppp_pid" 2>/dev/null; then
			if grep -q -E "cellular|3g-" "/proc/$old_ppp_pid/cmdline" 2>/dev/null; then
				logger -t iot_keep_alive "Sending SIGTERM to cellular pppd (PID: $old_ppp_pid)"
				kill -15 "$old_ppp_pid" 2>/dev/null
				sleep 2
				if kill -0 "$old_ppp_pid" 2>/dev/null; then
					logger -t iot_keep_alive "Sending SIGKILL to cellular pppd (PID: $old_ppp_pid)"
					kill -9 "$old_ppp_pid" 2>/dev/null
				fi
			fi
		fi
	fi

	# Clean only the specific configured cellular serial lock if stale and PID dead
	local cell_tty
	cell_tty=$(uci -q get network.cellular.device)
	if [ -n "$cell_tty" ]; then
		local tty_base
		tty_base=$(basename "$cell_tty")
		local lock_file="/var/lock/LCK..$tty_base"
		if [ -f "$lock_file" ]; then
			local lock_pid
			lock_pid=$(cat "$lock_file" 2>/dev/null | tr -d ' \n\r')
			case "$lock_pid" in
				''|*[!0-9]*)
					# Unknown or non-numeric lock content: do not delete automatically
					;;
				*)
					if ! kill -0 "$lock_pid" 2>/dev/null; then
						logger -t iot_keep_alive "Removing stale lock file $lock_file (dead PID: $lock_pid)"
						rm -f "$lock_file" 2>/dev/null
					fi
					;;
			esac
		fi
	fi
}

# Check cellular link health (Sets cell_health_reason: OK, NO_INTERFACE, NO_IPV4, NO_INTERNET)
check_cellular_connectivity()
{
	local cell_dev
	cell_dev=$(get_cellular_l3_dev)

	# Check A: Interface presence
	if ! ifconfig "$cell_dev" >/dev/null 2>&1; then
		cell_health_reason="NO_INTERFACE"
		return 1
	fi

	# Check B: IPv4 assigned
	local cell_ip
	cell_ip=$(ip -4 addr show dev "$cell_dev" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
	if [ -z "$cell_ip" ]; then
		cell_health_reason="NO_IPV4"
		return 1
	fi

	# Check C: Bound ping test via interface
	local ping_ok=0
	if command -v fping >/dev/null 2>&1; then
		if fping -I "$cell_dev" "$PING_HOST" >/dev/null 2>&1 || fping -I "$cell_dev" "$PING_HOST2" >/dev/null 2>&1; then
			ping_ok=1
		fi
	else
		if ping -c 1 -W 3 -I "$cell_dev" "$PING_HOST" >/dev/null 2>&1 || ping -c 1 -W 3 -I "$cell_dev" "$PING_HOST2" >/dev/null 2>&1; then
			ping_ok=1
		fi
	fi

	if [ "$ping_ok" -eq 1 ]; then
		cell_health_reason="OK"
		return 0
	fi

	cell_health_reason="NO_INTERNET"
	return 1
}

# Check Ethernet Internet independently from cellular
check_ethernet_connectivity()
{
	local eth_ip

	# Ethernet interface must exist and have IPv4
	eth_ip=$(ip -4 addr show dev "$WAN_IF" 2>/dev/null | \
		awk '/inet /{print $2; exit}' | cut -d/ -f1)

	if [ -z "$eth_ip" ]; then
		return 1
	fi

	# Probe specifically through Ethernet
	if command -v fping >/dev/null 2>&1; then
		if fping -I "$WAN_IF" "$PING_HOST2" >/dev/null 2>&1 || \
		   fping -I "$WAN_IF" "$PING_HOST" >/dev/null 2>&1; then
			return 0
		fi
	else
		if ping -c 1 -W 3 -I "$WAN_IF" "$PING_HOST2" >/dev/null 2>&1 || \
		   ping -c 1 -W 3 -I "$WAN_IF" "$PING_HOST" >/dev/null 2>&1; then
			return 0
		fi
	fi

	return 1
}

# ==============================================================================
# Hardware Modem Control
# ==============================================================================

gsm_poweroff()
{
	logger -t iot_keep_alive "Turning off GSM module (GPIO $Cellular_CTL HIGH)"
	echo 1 > "/sys/class/gpio/gpio$Cellular_CTL/value" 2>/dev/null
}

gsm_poweron()
{
	logger -t iot_keep_alive "Turning on GSM module (GPIO $Cellular_CTL LOW)"
	echo 0 > "/sys/class/gpio/gpio$Cellular_CTL/value" 2>/dev/null
}

poll_modem_device()
{
	local cell_tty
	cell_tty=$(uci -q get network.cellular.device)
	[ -z "$cell_tty" ] && cell_tty="/dev/ttyUSB3"

	local waited=0
	logger -t iot_keep_alive "Polling up to ${MODEM_ENUM_TIMEOUT}s for configured modem device ($cell_tty)..."
	while [ "$waited" -lt "$MODEM_ENUM_TIMEOUT" ]; do
		if [ -e "$cell_tty" ]; then
			logger -t iot_keep_alive "Modem serial device ($cell_tty) detected after ${waited}s"
			return 0
		fi
		sleep 2
		waited=$((waited + 2))
	done
	logger -t iot_keep_alive "Warning: Modem device ($cell_tty) did not enumerate within ${MODEM_ENUM_TIMEOUT}s"
	return 1
}

# ==============================================================================
# Backhaul Management (Automatic Ethernet / Cellular Selection)
# ==============================================================================

cancel_cellular_recovery_for_ethernet()
{
	if [ "$cellular_state" != "NORMAL" ] && \
	   [ "$cellular_state" != "ETH_STANDBY" ]; then
		logger -t iot_keep_alive \
			"Ethernet available; cancelling active cellular recovery state ($cellular_state)"
	fi

	gsm_fail_count=0
	soft_attempt=0
	failed_cycles=0
	wait_deadline=0

	if [ "$cellular_standby" = "1" ]; then
		cellular_state="ETH_STANDBY"
	else
		cellular_state="NORMAL"
	fi
}

enter_cellular_eth_standby()
{
	if [ "$cellular_standby" = "1" ]; then
		return
	fi

	logger -t iot_keep_alive \
		"Ethernet stable; placing cellular modem into power-saving standby"

	cancel_cellular_recovery_for_ethernet
	terminate_cellular_ppp

	if is_board_supported_for_gpio; then
		gsm_poweroff
	else
		logger -t iot_keep_alive \
			"GPIO modem power-off unsupported on board $board; cellular interface left down"
	fi

	cellular_standby=1
	cellular_state="ETH_STANDBY"
	backhaul_mode="ETH_PRIMARY"
}

wake_cellular_for_failover()
{
	logger -t iot_keep_alive \
		"Ethernet unavailable; cellular backhaul required"

	# Explicitly assert modem power ON.
	# This is safe even if the modem is already powered on and
	# protects against watchdog-process restarts while modem was in standby.
	if is_board_supported_for_gpio; then
		gsm_poweron
		poll_modem_device
	fi

	cellular_standby=0

	ifup cellular 2>/dev/null

	gsm_fail_count=0
	soft_attempt=0
	wait_deadline=0
	cellular_state="NORMAL"
	backhaul_mode="CELL_PRIMARY"
}

manage_backhaul_auto()
{
	local current_time
	current_time=$(date +%s)

	# --------------------------------------------------
	# Ethernet is healthy
	# --------------------------------------------------
	if check_ethernet_connectivity; then
		eth_fail_count=0

		if [ "$eth_ok_since" -eq 0 ]; then
			eth_ok_since="$current_time"
			logger -t iot_keep_alive \
				"Ethernet Internet detected; stability timer started"
		fi

		# Ethernet is already usable.
		# Do not waste energy performing cellular recovery.
		cellular_required=0
		cancel_cellular_recovery_for_ethernet

		# Do not toggle modem during boot grace.
		if is_boot_grace_period; then
			return
		fi

		# Only power cellular down after Ethernet has remained
		# continuously healthy for ETH_STABLE_SECONDS.
		if [ "$CELLULAR_STANDBY_ON_ETH" = "1" ] && \
		   [ $((current_time - eth_ok_since)) -ge "$ETH_STABLE_SECONDS" ]; then
			enter_cellular_eth_standby
		else
			backhaul_mode="ETH_PRIMARY"
		fi

		return
	fi

	# --------------------------------------------------
	# Ethernet unavailable
	# --------------------------------------------------
	eth_ok_since=0

	if [ "$eth_fail_count" -lt "$ETH_FAILURE_LIMIT" ]; then
		eth_fail_count=$((eth_fail_count + 1))
	fi

	# During boot grace we observe only.
	if is_boot_grace_period; then
		cellular_required=1
		return
	fi

	# Avoid switching because of one temporary Ethernet ping failure.
	if [ "$eth_fail_count" -lt "$ETH_FAILURE_LIMIT" ]; then
		cellular_required=0
		return
	fi

	# Cellular is now required.
	cellular_required=1

	if [ "$backhaul_mode" != "CELL_PRIMARY" ] || \
	   [ "$cellular_standby" = "1" ]; then
		wake_cellular_for_failover
	fi
}

# ==============================================================================
# Recovery State Machine Actions
# ==============================================================================

reset_cellular_recovery_state()
{
	if [ "$cellular_state" != "NORMAL" ] || [ "$gsm_fail_count" -ne 0 ] || \
	   [ "$soft_attempt" -ne 0 ] || [ "$failed_cycles" -ne 0 ] || \
	   [ "$wait_deadline" -ne 0 ]; then
		logger -t iot_keep_alive "Cellular connectivity verified via interface ping; recovery state reset to NORMAL"
	fi
	gsm_fail_count=0
	soft_attempt=0
	failed_cycles=0
	wait_deadline=0
	cellular_state="NORMAL"
	cell_health_reason="OK"
}

request_guarded_gateway_reboot()
{
	local current_time
	local elapsed_time
	local remaining_time
	current_time=$(date +%s)

	# Verify live health one more time before rebooting
	if [ "$cell_health_reason" = "NO_INTERNET" ]; then
		logger -t iot_keep_alive "Upstream carrier outage detected ($cell_health_reason); gateway reboot aborted, entering UPSTREAM_OUTAGE_WAIT"
		cellular_state="UPSTREAM_OUTAGE_WAIT"
		soft_attempt=0
		gsm_fail_count=0
		wait_deadline=0
		return
	fi

	case "$last_auto_reboot" in
		''|*[!0-9]*) last_auto_reboot=0 ;;
	esac

	if [ "$last_auto_reboot" -eq 0 ]; then
		elapsed_time="$AUTO_REBOOT_GUARD"
	elif [ "$current_time" -ge "$last_auto_reboot" ]; then
		elapsed_time=$((current_time - last_auto_reboot))
	else
		elapsed_time=0
	fi

	if [ "$elapsed_time" -ge "$AUTO_REBOOT_GUARD" ]; then
		echo "$current_time" > "$AUTO_REBOOT_TIMESTAMP_FILE"
		last_auto_reboot="$current_time"
		logger -t iot_keep_alive "All recovery cycles failed (Reason: $cell_health_reason); 6-hour guarded gateway reboot authorized"
		sync
		sleep 3
		reboot
		return
	fi

	remaining_time=$((AUTO_REBOOT_GUARD - elapsed_time))
	logger -t iot_keep_alive "Automatic reboot blocked by 6-hour guard ($remaining_time seconds remaining); entering REBOOT_GUARD_WAIT"

	soft_attempt=0
	failed_cycles=0
	gsm_fail_count=0
	wait_deadline=$((current_time + remaining_time))
	cellular_state="REBOOT_GUARD_WAIT"
}

cellular_recovery_tick()
{
	local current_time
	current_time=$(date +%s)

	# 1. Boot Grace Period (Zero failure accumulation)
	if is_boot_grace_period; then
		local up_sec
		up_sec=$(cut -d. -f1 /proc/uptime 2>/dev/null)
		logger -t iot_keep_alive "Boot grace period active (${up_sec}s < ${BOOT_GRACE_SECONDS}s); passive health logging only"
		gsm_fail_count=0
		return
	fi

	# 2. Passive Cellular Health Check (Bound to cellular L3 interface)
	if check_cellular_connectivity; then
		reset_cellular_recovery_state
		return
	fi

	# 3. State Machine Handling
	case "$cellular_state" in
		NORMAL)
			gsm_fail_count=$((gsm_fail_count + 1))
			logger -t iot_keep_alive "Cellular connectivity failure $gsm_fail_count of $GSM_FAILURE_LIMIT (Reason: $cell_health_reason)"
			if [ "$gsm_fail_count" -ge "$GSM_FAILURE_LIMIT" ]; then
				soft_attempt=1
				logger -t iot_keep_alive "Starting SOFT_RECOVERY_1 (Attempt 1 of $PPP_SOFT_ATTEMPTS, Cycle $((failed_cycles + 1)), Reason: $cell_health_reason)"
				terminate_cellular_ppp
				ifup cellular 2>/dev/null
				wait_deadline=$(($(date +%s) + PPP_START_TIMEOUT))
				cellular_state="PPP_START_WAIT"
			fi
			;;

		PPP_START_WAIT)
			if [ "$current_time" -ge "$wait_deadline" ]; then
				logger -t iot_keep_alive "PPP_START_WAIT timed out after ${PPP_START_TIMEOUT}s (Reason: $cell_health_reason)"
				if [ "$soft_attempt" -lt "$PPP_SOFT_ATTEMPTS" ]; then
					soft_attempt=$((soft_attempt + 1))
					logger -t iot_keep_alive "Starting SOFT_RECOVERY_$soft_attempt (Attempt $soft_attempt of $PPP_SOFT_ATTEMPTS, Cycle $((failed_cycles + 1)), Reason: $cell_health_reason)"
					terminate_cellular_ppp
					ifup cellular 2>/dev/null
					wait_deadline=$(($(date +%s) + PPP_START_TIMEOUT))
					cellular_state="PPP_START_WAIT"
				else
					if is_board_supported_for_gpio; then
						logger -t iot_keep_alive "Starting MODEM_POWER_CYCLE (Hardware GPIO reset on supported board $board, Reason: $cell_health_reason)"
						terminate_cellular_ppp
						gsm_poweroff
						sleep "$MODEM_OFF_SECONDS"
						gsm_poweron
						poll_modem_device
						ifup cellular 2>/dev/null
						wait_deadline=$(($(date +%s) + MODEM_START_TIMEOUT))
						cellular_state="MODEM_START_WAIT"
					else
						logger -t iot_keep_alive "Warning: Board '$board' not in GPIO reset list; skipping hardware power cycle"
						failed_cycles=$((failed_cycles + 1))
						if [ "$failed_cycles" -ge "$FAILED_CYCLES_BEFORE_REBOOT" ]; then
							if [ "$cell_health_reason" = "NO_INTERNET" ]; then
								logger -t iot_keep_alive "Cellular interface and IPv4 intact but public Internet unreachable (upstream carrier outage); entering UPSTREAM_OUTAGE_WAIT without hardware disruption"
								cellular_state="UPSTREAM_OUTAGE_WAIT"
								soft_attempt=0
								gsm_fail_count=0
								wait_deadline=0
							else
								request_guarded_gateway_reboot
							fi
						else
							wait_deadline=$(($(date +%s) + RECOVERY_COOLDOWN))
							cellular_state="COOLDOWN"
							soft_attempt=0
							gsm_fail_count=0
							logger -t iot_keep_alive "Recovery cycle $failed_cycles failed (Reason: $cell_health_reason); entering $RECOVERY_COOLDOWN seconds cooldown"
						fi
					fi
				fi
			fi
			;;

		MODEM_START_WAIT)
			if [ "$current_time" -ge "$wait_deadline" ]; then
				logger -t iot_keep_alive "MODEM_START_WAIT timed out after ${MODEM_START_TIMEOUT}s (Reason: $cell_health_reason)"
				failed_cycles=$((failed_cycles + 1))
				if [ "$failed_cycles" -ge "$FAILED_CYCLES_BEFORE_REBOOT" ]; then
					if [ "$cell_health_reason" = "NO_INTERNET" ]; then
						logger -t iot_keep_alive "Cellular interface and IPv4 intact but public Internet unreachable (upstream carrier outage); entering UPSTREAM_OUTAGE_WAIT without hardware disruption"
						cellular_state="UPSTREAM_OUTAGE_WAIT"
						soft_attempt=0
						gsm_fail_count=0
						wait_deadline=0
					else
						logger -t iot_keep_alive "Cellular stack/hardware failed after $failed_cycles cycles (Reason: $cell_health_reason); requesting guarded reboot"
						request_guarded_gateway_reboot
					fi
				else
					wait_deadline=$(($(date +%s) + RECOVERY_COOLDOWN))
					cellular_state="COOLDOWN"
					soft_attempt=0
					gsm_fail_count=0
					logger -t iot_keep_alive "Recovery cycle $failed_cycles failed (Reason: $cell_health_reason); entering $RECOVERY_COOLDOWN seconds cooldown"
				fi
			fi
			;;

		COOLDOWN)
			if [ "$current_time" -ge "$wait_deadline" ]; then
				logger -t iot_keep_alive "Recovery cooldown complete; returning to NORMAL monitoring (5 fresh consecutive failures required for Cycle $((failed_cycles + 1)))"
				cellular_state="NORMAL"
				soft_attempt=0
				gsm_fail_count=0
				wait_deadline=0
			fi
			;;

		UPSTREAM_OUTAGE_WAIT)
			# Interface and IPv4 are present; public ping is failing due to carrier outage.
			# No ifdown, no kill, no modem GPIO toggle, no gateway reboot.
			# If the link degrades (interface disappears or IPv4 lost), allow fresh recovery cycle.
			if [ "$cell_health_reason" = "NO_INTERFACE" ] || [ "$cell_health_reason" = "NO_IPV4" ]; then
				logger -t iot_keep_alive "Cellular link degraded from upstream outage to $cell_health_reason; starting fresh recovery"
				cellular_state="NORMAL"
				gsm_fail_count=1
				soft_attempt=0
				failed_cycles=0
			fi
			;;

		REBOOT_GUARD_WAIT)
			if [ "$current_time" -ge "$wait_deadline" ]; then
				logger -t iot_keep_alive "6-hour reboot guard elapsed; re-evaluating live cellular health before reboot"
				if [ "$cell_health_reason" = "NO_INTERNET" ]; then
					logger -t iot_keep_alive "Interface and IPv4 present (upstream carrier outage); aborting reboot and entering UPSTREAM_OUTAGE_WAIT"
					cellular_state="UPSTREAM_OUTAGE_WAIT"
					soft_attempt=0
					gsm_fail_count=0
					wait_deadline=0
				else
					logger -t iot_keep_alive "Cellular hardware/PPP still broken ($cell_health_reason); proceeding with guarded reboot"
					request_guarded_gateway_reboot
				fi
			fi
			;;
	esac
}

# ==============================================================================
# Preserved Dragino Vendor Fallback & Network Functions
# ==============================================================================

chk_eth1_connection()
{
	wan_ping=0
	if [ $(ifconfig 2>/dev/null | grep -c "$WAN_IF") -gt 0 ]; then
		wan_ip=$(ip addr show "$WAN_IF" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
		if [ -n "$wan_ip" ]; then
			if [ -z "$WAN_GW" ] && [ "$(uci -q get network.wan.proto)" = "dhcp" ] && [ "$RETRY_WAN_GW" -lt 5 ]; then
				ifup wan 2>/dev/null
				RETRY_WAN_GW=$((RETRY_WAN_GW + 1))
				logger -t iot_keep_alive "Retry $RETRY_WAN_GW to get wan gateway"
				sleep 20
				WAN_GW=$(ip route show dev "$WAN_IF" 2>/dev/null | awk '/default/{print $3}')
				[ -n "$WAN_GW" ] && ip route add "$PING_WAN_HOST" via "$WAN_GW" dev "$WAN_IF" 2>/dev/null
			elif [ -z "$WAN_GW" ] && [ "$(uci -q get network.wan.proto)" = "static" ]; then
				WAN_GW=$(uci -q get network.wan.gateway)
				[ -n "$WAN_GW" ] && ip route add "$PING_WAN_HOST" via "$WAN_GW" dev "$WAN_IF" 2>/dev/null
			fi

			if [ -n "$WAN_GW" ]; then
				wan_ping=$(fping "$PING_WAN_HOST" 2>/dev/null | grep -c alive)
			elif [ "$(uci -q get network.wan.proto)" = "static" ] && [ -n "$WAN_GW" ]; then
				wan_ping=$(fping "$WAN_GW" 2>/dev/null | grep -c alive)
			fi
		fi
	fi
}

chk_wlan0_connection()
{
	wifi_ping=0
	if [ $(ifconfig 2>/dev/null | grep -c "$WIFI_IF") -gt 0 ]; then
		wifi_ip=$(ifconfig "$WIFI_IF" 2>/dev/null | awk -F'[: ]+' '/inet /{print $4}')
		if [ -n "$wifi_ip" ]; then
			if [ -z "$WIFI_GW" ] && [ "$(uci -q get network.wwan.proto)" = "dhcp" ] && [ "$RETRY_WIFI_GW" -lt 5 ]; then
				ifup wwan 2>/dev/null
				RETRY_WIFI_GW=$((RETRY_WIFI_GW + 1))
				logger -t iot_keep_alive "Retry $RETRY_WIFI_GW to get wifi GW"
				sleep 20
				WIFI_GW=$(ip route show dev "$WIFI_IF" 2>/dev/null | awk '/default/{print $3}')
				[ -n "$WIFI_GW" ] && ip route add "$PING_WIFI_HOST" via "$WIFI_GW" dev "$WIFI_IF" 2>/dev/null
			elif [ -z "$WIFI_GW" ] && [ "$(uci -q get network.wwan.proto)" = "static" ] && [ "$RETRY_WIFI_GW" -lt 5 ]; then
				WIFI_GW=$(uci -q get network.wwan.gateway)
				[ -n "$WIFI_GW" ] && ip route add "$PING_WIFI_HOST" via "$WIFI_GW" dev "$WIFI_IF" 2>/dev/null
			fi

			if [ -n "$WIFI_GW" ]; then
				wifi_ping=$(fping "$PING_WIFI_HOST" 2>/dev/null | grep -c alive)
			fi
		fi
	fi
}

use_gsm_as_gateway()
{
	logger -t iot_keep_alive "Moving internet connection to $GSM_IF (3G)..."
	ip route del default 2>/dev/null
	ip route add default dev "$GSM_IF" proto static 2>/dev/null
}

use_wan_as_gateway()
{
	logger -t iot_keep_alive "Moving internet connection to $WAN_IF (WAN)..."
	ip route del default 2>/dev/null
	ip route add default via "$WAN_GW" dev "$WAN_IF" proto static src "$wan_ip" 2>/dev/null
}

use_wifi_as_gateway()
{
	logger -t iot_keep_alive "Moving internet connection to $WIFI_IF (WIFI)..."
	ip route del default 2>/dev/null
	ip route add default via "$WIFI_GW" dev "$WIFI_IF" proto static src "$wifi_ip" 2>/dev/null
}

update_gateway()
{
	local pid
	pid=$(cat "/var/run/udhcpc-$1.pid" 2>/dev/null)
	if [ -n "$pid" ]; then
		kill -s SIGUSR2 "$pid" 2>/dev/null
		sleep 5
		kill -s SIGUSR1 "$pid" 2>/dev/null
	fi
}

gsm_status_check()
{
	local current_time
	local disable_time
	local gsm_enable
	gsm_enable=$(uci -q get network.cellular.auto)
	[ "$gsm_enable" = "0" ] && return 0

	if [ "$(cat /sys/class/gpio/gpio$Cellular_CTL/value 2>/dev/null)" = "0" ]; then
		local gsm_hangup
		gsm_hangup=$(logread 2>/dev/null | grep -c -e "Modem hangup")
		if [ "$gsm_hangup" -ge 6 ]; then
			logger -t iot_keep_alive "Cellular multiple dialing failures detected"
			gsm_poweroff
			echo "$(date +%s)" > /usr/share/cell_disable.txt
		fi
	elif [ -f "/usr/share/cell_disable.txt" ]; then
		current_time=$(date +%s)
		disable_time=$(cat /usr/share/cell_disable.txt 2>/dev/null)
		if [ $((current_time - disable_time)) -gt 7200 ]; then
			gsm_poweron
			rm -f /usr/share/cell_disable.txt 2>/dev/null
		fi
	fi
}

toggle_3g()
{
	local gsm_if_suf
	gsm_if_suf=$(ifconfig 2>/dev/null | grep '3g-' | awk '{print $1}' | awk -F '-' '{print $2}')
	if [ -n "$gsm_if_suf" ]; then
		ifdown "$gsm_if_suf" 2>/dev/null
		sleep 15
		ifup "$gsm_if_suf" 2>/dev/null
		logger -t iot_keep_alive "Restarted 3G Interface $gsm_if_suf"
	fi
}

enable_ue_usage()
{
	killall comgt 2>/dev/null
	gcom -d /dev/ttyModemAT -s /etc/gcom/enable-usage.gcom > /var/iot/cell_usage.txt 2>/dev/null
}

# ==============================================================================
# Global Network and IoT Service Management
# ==============================================================================

chk_internet_connection()
{
	global_ping=0
	if command -v fping >/dev/null 2>&1; then
		global_ping=$( (fping "$PING_HOST" 2>/dev/null || fping "$PING_HOST2" 2>/dev/null) | grep -c alive )
	else
		if ping -c 1 -W 3 "$PING_HOST" >/dev/null 2>&1 || ping -c 1 -W 3 "$PING_HOST2" >/dev/null 2>&1; then
			global_ping=1
		fi
	fi
	echo "$global_ping" > /var/iot/internet
}

reload_iot_service()
{
	local type="$1"
	local cur_reload_time
	cur_reload_time=$(date +%s)

	if [ -z "$last_reload_time" ]; then
		last_reload_time=0
	fi

	if [ "$server_type" = "lorawan" ]; then
		if [ "$type" = "offline" ] && [ $((cur_reload_time - last_reload_time)) -gt 180 ]; then
			/etc/init.d/lora_gw restart 2>/dev/null
			logger -t iot_keep_alive "Reload completed. Current Mode: $server_type, Time: $cur_reload_time"
			last_reload_time=$(date +%s)
		fi
	fi
}

station_time_check()
{
	if [ "$server_type" = "station" ] && [ -f /var/iot/station.log ]; then
		if [ "$station_check_time" = "1" ]; then
			local syscurrent_time
			local stationcurrent_time
			syscurrent_time=$(date +"%Y-%m-%d")
			stationcurrent_time=$(tail -n 1 /var/iot/station.log 2>/dev/null | grep -E -o '20[0-9]{2}-[0-9]{2}-[0-9]{2}')
			if [ -n "$syscurrent_time" ] && [ -n "$stationcurrent_time" ]; then
				local t1
				local t2
				t1=$(date -d "$syscurrent_time" +%s 2>/dev/null)
				t2=$(date -d "$stationcurrent_time" +%s 2>/dev/null)
				if [ -n "$t1" ] && [ -n "$t2" ] && [ "$t1" -ne "$t2" ]; then
					logger -t iot_keep_alive "Abnormal station time detected; reloading station process"
					/usr/bin/reload_iot_service.sh &
				fi
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
		sta_ssid=$(uci -q get wireless.sta_0.ssid)
		sta_scan=$(iwinfo radio0 scan 2>/dev/null | grep -c "$sta_ssid")
		if [ "$sta_scan" -gt 0 ]; then
			wifi 2>/dev/null
			uci set wireless.sta_0.reload=0
			uci commit wireless
		fi
		return
	fi

	ap_carrier=$(ubus call network.device status '{"name":"wlan0"}' 2>/dev/null | grep '"carrier"' | awk '{print $2}' | sed 's/,//g')
	sta_disable=$(uci -q get wireless.sta_0.disabled)
	if [ "$ap_carrier" = "true" ] || [ "$sta_disable" = "1" ]; then
		echo 1 > /sys/class/gpio/gpio27/value 2>/dev/null
		return
	fi

	sta_carrier=$(ubus call network.device status '{"name":"wlan0-2"}' 2>/dev/null | grep '"carrier"' | awk '{print $2}' | sed 's/,//g')
	if [ "$sta_carrier" = "true" ]; then
		return
	fi

	sta_ssid=$(uci -q get wireless.sta_0.ssid)
	sta_scan=$(iwinfo radio0 scan 2>/dev/null | grep -c "$sta_ssid")
	if [ "$sta_scan" -eq 0 ]; then
		sta_no_scan=$((sta_no_scan + 1))
		if [ "$sta_no_scan" -gt 3 ]; then
			uci set wireless.sta_0.disabled=1
			uci set wireless.sta_0.reload=1
			uci commit wireless
			wifi && sleep 5
			uci set wireless.sta_0.disabled=0
			uci commit wireless
			sta_no_scan=0
		fi
	else
		i=0
		nolink=0
		while [ "$i" -le 6 ]; do
			sta_carrier=$(ubus call network.device status '{"name":"wlan0-2"}' 2>/dev/null | grep '"carrier"' | awk '{print $2}' | sed 's/,//g')
			if [ "$sta_carrier" = "false" ]; then
				nolink=$((nolink + 1))
			fi
			i=$((i + 1))
			sleep 3
		done
		sta_auth=$(dmesg -r 2>/dev/null | grep "wlan0-2" | grep -c 4WAY_HANDSHAKE_TIMEOUT)
		if [ "$nolink" -gt 5 ] && [ "$sta_auth" -gt 3 ]; then
			dmesg -c > /dev/null 2>&1
			uci set wireless.sta_0.disabled=1
			uci set wireless.sta_0.reload_time=$(date +%s)
			uci commit wireless
			wifi && sleep 5
			uci set wireless.sta_0.disabled=0
			uci commit wireless
			echo "Wifi client authentication failures, due to the wrong password" > /usr/share/wifi_handle.txt
		fi
	fi
}

# ==============================================================================
# Main Daemon Loop
# ==============================================================================

server_type=$(uci -q get gateway.general.server_type)

while :
do
	chk_internet_connection

	# Maintain /var/iot storage limit (< 2M)
	receive_size=$(du -k -s /var/iot/ 2>/dev/null | awk '{print $1}')
	if [ -n "$receive_size" ] && [ "$receive_size" -gt 1024 ]; then
		rm -rf /var/iot/receive/* /var/iot/channels/* /var/iot/station.log 2>/dev/null
	fi

	case "$global_ping" in
		1)
			has_internet_flag_time=$(date +%s)
			ROUTE_DF=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
			logger -t iot_keep_alive "Global Internet OK via: $ROUTE_DF"
			has_internet=1
			station_time_check
			;;
		0)
			logger -t iot_keep_alive "Global Internet access failed"
			has_internet=0
			;;
	esac

	# Automatic backhaul selection:
	# Ethernet healthy -> Ethernet primary, cellular may enter standby
	# Ethernet unavailable -> Cellular primary + PPP recovery watchdog
	cellular_auto=$(uci -q get network.cellular.auto)

	if [ "$cellular_auto" = "1" ]; then
		manage_backhaul_auto

		if [ "$cellular_required" = "1" ]; then
			cellular_recovery_tick
		fi

	elif [ "$iot_online" = "0" ]; then
		logger -t iot_keep_alive \
			"Cellular auto-recovery disabled; IoT Service offline"
	fi

	# Server Type Application Monitoring
	case "$server_type" in
		lorawan)
			if [ -z "$(pgrep fwd)" ]; then
				logger -t iot_keep_alive "IoT Server (fwd) is not running; reloading IoT service"
				reload_iot_service offline
			else
				status_count=$(sqlite3 /var/lgwdb.sqlite "select * from gwdb where key like '/service/lorawan/server/network';" 2>/dev/null | grep -c online)
				if [ "$status_count" -gt 0 ]; then
					echo "online" > /var/iot/status
				else
					offline_count=$(sqlite3 /var/lgwdb.sqlite "select * from gwdb;" 2>/dev/null | grep network | grep -c offline)
					if [ "$offline_count" -ge 15 ]; then
						echo "offline" > /var/iot/status
					fi
				fi
			fi
			iot_online=$(cat /var/iot/status 2>/dev/null | grep -c online)
			;;

		station)
			station_status=$(cat /var/tmp/station_status.log 2>/dev/null)
			iot_online=1
			iot_status="online"
			if [ "$station_status" = "OFFLINE" ]; then
				iot_online=0
				iot_status="offline"
				logger -t iot_keep_alive "Site TCP connection failure detected; switching state to offline"
			fi
			echo "$iot_status" > /var/iot/status
			;;

		mqtt)
			if [ "$(uci -q get mqtt.common.sub_enable)" = "checked" ]; then
				mqtt_subpid=$(pgrep mosquitto_sub)
				if [ -z "$mqtt_subpid" ]; then
					/etc/init.d/iot reload 2>/dev/null
				fi
			fi
			;;
	esac

	# LED Status Management
	if [ "$is_lps8" = "1" ]; then
		if [ ! -d /sys/class/gpio/gpio21/ ]; then
			echo 21 > /sys/class/gpio/export 2>/dev/null
			echo out > /sys/class/gpio/gpio21/direction 2>/dev/null
		fi
	fi
	if [ "$is_ps8n" = "1" ]; then
		if [ ! -d /sys/class/gpio/gpio27/ ]; then
			echo 27 > /sys/class/gpio/export 2>/dev/null
			echo out > /sys/class/gpio/gpio27/direction 2>/dev/null
		fi
	fi

	/usr/bin/blink-stop 2>/dev/null
	if [ "$iot_online" = "1" ]; then
		[ "$is_lps8" = "1" ] && echo 0 > /sys/class/gpio/gpio21/value 2>/dev/null
		echo 1 > /sys/class/leds/dragino2\:red\:system/brightness 2>/dev/null
		if [ "$offline_flag" = "1" ]; then
			offline_flag="0"
			echo "$(date): switch to online" >> /var/status_log
		fi
	elif [ "$has_internet" -eq 1 ]; then
		/usr/bin/blink-start 100 2>/dev/null
		[ "$is_lps8" = "1" ] && echo 0 > /sys/class/gpio/gpio21/value 2>/dev/null
		if [ "$offline_flag" = "0" ]; then
			echo "$(date): switch to offline" >> /var/status_log
			offline_flag="1"
		elif [ "$offline_flag" = "1" ] && [ "$server_type" = "lorawan" ]; then
			logger -t iot_keep_alive "Reloading IoT service due to offline status"
			reload_iot_service offline
			sleep 30
		fi
	else
		echo 0 > /sys/class/leds/dragino2\:red\:system/brightness 2>/dev/null
		[ "$is_lps8" = "1" ] && echo 1 > /sys/class/gpio/gpio21/value 2>/dev/null
	fi

	# WiFi Client Management
	ap_enable=$(uci -q get wireless.ap_0.disabled)
	if [ "$ap_enable" = "0" ]; then
		chk_wlan0_client
	else
		echo 0 > /sys/class/gpio/gpio27/value 2>/dev/null
	fi

	server_type=$(uci -q get gateway.general.server_type)
	sleep "$check_interval"
done
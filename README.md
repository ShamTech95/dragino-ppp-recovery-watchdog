# Dragino PPP Recovery Watchdog (V2 Production)

A lightweight, robust, non-blocking, and guarded PPP/PPPD recovery watchdog with **Automatic Backhaul Selection** for Dragino OpenWrt LoRaWAN gateways.

---

## License

This project is released under the **MIT License**.

---

## Author

**Ehtisham Ul Haq**  
IoT Engineer @ WIT, LUMS • LoRaWAN • Embedded Systems • OpenWrt • Edge Computing  

---

## Overview

Dragino LoRaWAN gateways deployed in remote field environments (such as off-grid solar/battery installations or hybrid Ethernet/Cellular sites) require resilient connectivity management.

This project unifies **Automatic Backhaul Selection** with a **Non-Blocking 4-Tier PPP Recovery Watchdog**:

1. **Automatic Backhaul Selection (Dual-Site Architecture)**:
   - **Sites with Ethernet**: Ethernet is detected and used as primary. When Ethernet remains continuously healthy for 3 minutes (`ETH_STABLE_SECONDS=180`), the cellular modem enters low-power standby (modem powered off via GPIO) to conserve battery. If Ethernet fails for ~45s (`ETH_FAILURE_LIMIT=3`), the cellular modem is automatically awakened, brought up, and monitored.
   - **Sites without Ethernet**: Instantly operates in `CELL_PRIMARY` mode with active PPP health checks and recovery watchdog.
2. **Boot Grace Period**: Enforces a 180-second (3-minute) window at startup with zero failure accumulation, giving modem, SIM registration, and Ethernet interfaces time to stabilize naturally.
3. **Targeted Process Management**: Captures the specific cellular `pppd` PID before calling `ifdown cellular`, issues graceful `SIGTERM` before `SIGKILL`, and cleans only the configured serial device's lock file if verified stale.
4. **Hardware Modem Power Cycle**: Uses Dragino's `Cellular_CTL` GPIO on verified supported hardware (LG08, LPS8, DLOS8, LG01/02, LIG16, PS8N) to cold power-cycle the modem hardware when software restarts fail.
5. **Recovery Cooldown**: Enforces a 30-minute recovery cooldown to allow network-side retry/back-off timers to clear, reduce repeated attach/session attempts, and provide a power-system recovery window.
6. **Outage Protection (`UPSTREAM_OUTAGE_WAIT`)**: Differentiates between local stack failure (`NO_INTERFACE`, `NO_IPV4`) and carrier outages (`NO_INTERNET`). Carrier outages prevent whole-OS reboots and avoid hardware thrashing.
7. **Guarded Gateway Reboot**: Limits automatic OS reboots to a maximum of once every 6 hours (`AUTO_REBOOT_GUARD=21600`) with a non-blocking `REBOOT_GUARD_WAIT` state.
8. **Strict Routing Separation**: Performs connectivity checks strictly via interface-bound ping (`fping -I "$CELL_DEV"` / `fping -I "$WAN_IF"`). It **never** modifies the system routing table, avoiding conflicts with routing and failover managers (e.g., `gateway_failover_safe.sh`).

---

## Recovery Strategy (V2 Architecture)

```text
                           [ Gateway Boot ]
                                  │
                       180s Boot Grace Period
                   (No failure counter accumulation)
                                  │
                       [ Backhaul Evaluation ]
                      ┌───────────┴───────────┐
             Ethernet Healthy             Ethernet Down
                      │                         │
             [ ETH_PRIMARY ]            [ CELL_PRIMARY ]
       (Modem standby after 3m)     (Cellular Ping OK every 15s)
                      │                         │
             If Ethernet fails          5 Consecutive Failures
                      │                         │
                      └────────────────> ┌──────▼───────────────┐
                                         │   SOFT_RECOVERY_1    │
                                         │ • Capture pppd PID   │
                                         │ • ifdown cellular    │
                                         │ • ifup & 180s wait   │
                                         └──────┬───────────────┘
                                                │
                                   ┌────────────┴────────────┐
                           Link Restored                 Timeout (180s)
                                   │                         │
                                NORMAL                       ▼
                                               ┌───────────────────────────┐
                                               │      SOFT_RECOVERY_2      │
                                               │  • 2nd targeted restart   │
                                               │  • State -> PPP_START_WAIT│
                                               └─────────────┬─────────────┘
                                                             │
                                                ┌────────────┴────────────┐
                                        Link Restored                 Timeout (180s)
                                                │                         │
                                             NORMAL                       ▼
                                                            ┌───────────────────────────┐
                                                            │    MODEM_POWER_CYCLE      │
                                                            │  • Board support check    │
                                                            │  • ifdown cellular        │
                                                            │  • gsm_poweroff (15s)     │
                                                            │  • gsm_poweron            │
                                                            │  • Poll for /dev/ttyUSB3  │
                                                            │  • ifup cellular          │
                                                            │  • State -> MODEM_START_WAIT
                                                            └─────────────┬─────────────┘
                                                                          │
                                                             ┌────────────┴────────────┐
                                                     Link Restored                 Timeout (180s)
                                                             │                         │
                                                          NORMAL               failed_cycles++
                                                                                       │
                                                                 ┌─────────────────────┴─────────────────────┐
                                                          failed_cycles = 1                           failed_cycles = 2
                                                                 │                                           │
                                                                 ▼                                           ▼
                                                       ┌───────────────────┐                       ┌───────────────────┐
                                                       │ 30-MIN COOLDOWN   │                       │ Reason Evaluation │
                                                       │ (State: COOLDOWN) │                       └─────────┬─────────┘
                                                       │ • Passive monitor │                                 │
                                                       │ • Cycle 2 on exp. │                ┌────────────────┴────────────────┐
                                                       └───────────────────┘                ▼                                 ▼
                                                                                ┌───────────────────────┐         ┌───────────────────────┐
                                                                                │ NO_INTERFACE / NO_IPV4│         │ NO_INTERNET (Carrier) │
                                                                                │ Guarded Gateway Reboot│         │ UPSTREAM_OUTAGE_WAIT  │
                                                                                │ (Max 1 per 6 hours)   │         │ (No OS reboot/thras.) │
                                                                                └───────────────────────┘         └───────────────────────┘
```

---

## Recovery Philosophy

The recovery logic follows key embedded principles:

> **Check frequently. Recover conservatively. Never block the daemon loop. Never fight routing managers.**

- **Non-Blocking Operation**: Long waits are handled as deadline timestamps. The main 15-second loop continues executing so LoRaWAN packet forwarders and LED status indicators never freeze.
- **Differentiated Failure Classification & Outage Protection**: Health checks categorize failures into `NO_INTERFACE`, `NO_IPV4`, and `NO_INTERNET`:
  - `NO_INTERFACE` / `NO_IPV4`: Indicates local modem, serial driver, or PPP negotiation failure; full escalation up to guarded gateway reboot is permitted.
  - `NO_INTERNET`: Indicates interface and IPv4 are assigned, but upstream public targets are unreachable (telecom operator outage). The watchdog attempts PPP and hardware modem resets, but **will NOT reboot the Linux gateway** upon cycle exhaustion; instead, it enters `UPSTREAM_OUTAGE_WAIT` to avoid disrupting local LoRa packet processing during external carrier outages.
- **Non-Blocking Recovery Cooldown**: Recovery cooldown is strictly non-blocking. During cooldown, passive health checks continue at the normal watchdog interval. Any successful cellular connectivity check immediately aborts the cooldown, clears all recovery counters, and returns the watchdog to NORMAL without waiting for the cooldown timer to expire. LoRaWAN packet forwarding and routing/failover services remain untouched throughout cooldown.
- **Cooldown Completion Transition**: When the 30-minute cooldown timer expires, the watchdog returns to NORMAL monitoring and requires 5 fresh consecutive failures before initiating Cycle 2, ensuring links negotiating naturally are not interrupted.
- **Boot Protection**: No recovery actions and zero failure counter accumulation during the first 180 seconds after boot.
- **Hardware Reset Before OS Reboot**: Baseband hangs are resolved by power-cycling the modem module via GPIO, avoiding full Linux reboots.
- **Immediate Cancellation**: If cellular connectivity is verified at any point, the state machine immediately resets to **NORMAL**.
- **Reboot Guard**: Automatic OS reboot is capped at **once per 6 hours** (`AUTO_REBOOT_GUARD=21600`).

---

## Configuration Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `BOOT_GRACE_SECONDS` | `180` | Boot grace period (3 minutes) with zero failure accumulation |
| `ETH_FAILURE_LIMIT` | `3` | Consecutive Ethernet failures (~45s) before cellular is required |
| `ETH_STABLE_SECONDS` | `180` | Required Ethernet stability (3 minutes) before cellular enters standby |
| `CELLULAR_STANDBY_ON_ETH`| `1` | Enable GPIO power-saving standby on cellular when Ethernet is stable |
| `GSM_FAILURE_LIMIT` | `5` | Consecutive failures before initiating recovery |
| `PPP_SOFT_ATTEMPTS` | `2` | Number of soft `pppd` restart attempts per cycle |
| `PPP_STOP_TIMEOUT` | `15` | Max seconds to wait for `pppd` graceful `SIGTERM` before `SIGKILL` |
| `PPP_START_TIMEOUT` | `180` | Non-blocking deadline allowed for PPP link negotiation |
| `MODEM_OFF_SECONDS` | `15` | Seconds modem power is cut during GPIO hardware reset |
| `MODEM_ENUM_TIMEOUT`| `30` | Max seconds to poll for serial modem device enumeration |
| `MODEM_START_TIMEOUT`| `180` | Non-blocking deadline allowed for post-reset link negotiation |
| `RECOVERY_COOLDOWN` | `1800` | Cooldown duration (30 minutes) between recovery cycles |
| `FAILED_CYCLES_BEFORE_REBOOT` | `2` | Total complete cycles before guarded reboot |
| `AUTO_REBOOT_GUARD` | `21600` | Minimum time (6 hours) between automatic gateway reboots |

---

## Supported Hardware (GPIO Hardware Cycle)

- Dragino LG08
- Dragino LPS8 / LPS8N / LPS8v2
- Dragino DLOS8 / DLOS8N
- Dragino LG01 / LG02
- Dragino LIG16
- Dragino PS8N / PS8G / OS8N / OS8L / PS8L

---

## Deployment & Bench Testing Guide

> [!IMPORTANT]
> Always validate new watchdog versions on a local bench/lab gateway before deploying to remote production sites.

### 1. Backup Existing Script
```bash
cp /usr/bin/iot_keep_alive.sh /usr/bin/iot_keep_alive.sh.bak
```

### 2. Copy and Set Permissions
Copy `iot_keep_alive_custom.sh` to `/usr/bin/iot_keep_alive.sh` on the gateway:
```bash
chmod +x /usr/bin/iot_keep_alive.sh
```

### 3. Syntax Verification
```bash
sh -n /usr/bin/iot_keep_alive.sh
```
*(Should return 0 errors)*

### 4. Restart Service
```bash
/etc/init.d/iot restart
```

---

## Monitoring and Logs

View real-time watchdog execution logs:
```bash
logread -f | grep iot_keep_alive
```

Check interface and backhaul status:
```bash
ifconfig
ip addr show
```
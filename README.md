
# dragino-ppp-recovery-watchdog
PPP recovery watchdog for Dragino OpenWrt LoRaWAN gateways using pppd.


## License

This project is released under the **MIT License**.

---

## Author

**Ehtisham Ul Haq**

IoT Engineer @ WIT,LUMS • LoRaWAN • Embedded Systems • OpenWrt • Edge Computing

If this project is useful, consider giving it a ⭐ on GitHub.


# Dragino PPP Recovery Watchdog

A lightweight PPP/PPPD recovery watchdog for Dragino OpenWrt LoRaWAN gateways using cellular (3G/4G) connectivity.

---

## Overview

Some Dragino LoRaWAN gateways that use **PPP (`pppd`)** for cellular connectivity may occasionally enter a continuous reconnection loop or become stuck after repeated network interruptions, modem instability, or frequent power cycling.

This project implements a **guarded recovery state machine** that attempts to recover the PPP connection in a controlled manner while avoiding unnecessary modem resets and continuous gateway reboots.

The goal is to improve gateway reliability and uptime in remote deployments.

---

## Features

- Detects persistent cellular connectivity failures
- Controlled PPP (`pppd`) recovery
- Progressive recovery strategy
- Configurable stabilization period
- Progressive cooldown intervals
- Immediate recovery cancellation when connectivity returns
- Guarded automatic gateway reboot
- Lightweight POSIX shell implementation
- Designed for Dragino OpenWrt gateways

---

## Recovery Strategy

Instead of continuously restarting `pppd`, the watchdog follows a staged recovery process.

```text
Normal Operation
       │
       ▼
5 consecutive connectivity failures
       │
       ▼
PPP Recovery
       │
       ▼
3-minute stabilization
       │
  ┌────┴────┐
  │         │
Recovered  Failed
  │         │
  ▼         ▼
NORMAL   30-minute cooldown
            │
            ▼
 Connectivity monitored
   every 15 seconds
            │
     ┌──────┴──────┐
     │             │
 Internet      Cooldown
 Restored      Completed
     │             │
     ▼             ▼
 NORMAL      PPP Recovery
                    │
                    ▼
           3-minute stabilization
                    │
              ┌─────┴─────┐
              │           │
          Recovered     Failed
              │           │
              ▼           ▼
           NORMAL    60-minute cooldown
                           │
                           ▼
                Connectivity monitored
                  every 15 seconds
                           │
                    ┌──────┴──────┐
                    │             │
                Internet      Cooldown
                Restored      Completed
                    │             │
                    ▼             ▼
                 NORMAL     PPP Recovery
                                 │
                                 ▼
                        3-minute stabilization
                                 │
                           ┌─────┴─────┐
                           │           │
                       Recovered     Failed
                           │           │
                           ▼           ▼
                        NORMAL    120-minute cooldown
                                        │
                                        ▼
                             Connectivity monitored
                               every 15 seconds
                                        │
                               ┌────────┴────────┐
                               │                 │
                         Internet           Cooldown
                         Restored           Completed
                               │                 │
                               ▼                 ▼
                            NORMAL        Final PPP Recovery
                                                │
                                                ▼
                                         3-minute stabilization
                                                │
                                          ┌─────┴─────┐
                                          │           │
                                      Recovered     Failed
                                          │           │
                                          ▼           ▼
                                       NORMAL   Guarded Gateway Reboot
```

---

## Recovery Philosophy

The recovery logic follows one simple principle:

> **Check frequently. Recover conservatively.**

- Connectivity is checked approximately every **15 seconds**.
- PPP recovery is performed only when persistent failures are detected.
- Only one controlled PPP recovery is attempted during each recovery stage.
- Cooldown periods prevent continuous PPP restart loops.
- If connectivity returns during stabilization or cooldown, all pending recovery actions are cancelled immediately and the gateway returns to **NORMAL** operation.

---

## Tested Hardware

The recovery logic has been tested on:

- Dragino LOS8
- Dragino OpenWrt firmware
- PPP (`pppd`) cellular backhaul

---

## Compatibility

This project is intended for **Dragino OpenWrt LoRaWAN gateways** that use **PPP (`pppd`)** for cellular connectivity.

The recovery strategy may also be adaptable to other OpenWrt-based LoRaWAN gateways using a similar PPP architecture. However, it has currently been tested only on Dragino hardware.

---

## Installation

1. Review the recovery parameters inside the script.
2. Test the script on a local gateway before deployment.
3. Validate the recovery behaviour by simulating cellular failures.
4. Deploy to remote gateways only after successful local testing.

---

## Configuration

Important recovery parameters:

| Parameter | Description |
|-----------|-------------|
| `GSM_FAILURE_LIMIT` | Number of consecutive failures before recovery starts |
| `PPP_STABILIZE_SECONDS` | Time allowed for PPP to stabilize |
| `COOLDOWN_ROUND_1` | First cooldown period |
| `COOLDOWN_ROUND_2` | Second cooldown period |
| `COOLDOWN_ROUND_3` | Third cooldown period |
| `AUTO_REBOOT_GUARD` | Minimum time between automatic gateway reboots |

---

## Disclaimer

This project modifies the gateway recovery behaviour.

Always validate the recovery logic on a **local gateway** before deploying it to production or remote installations.

The author is not responsible for any damage, service interruption, or data loss resulting from the use of this project.

---

## Future Improvements

Possible future enhancements include:

- Modem health monitoring
- SIM status monitoring
- Signal strength based recovery
- SMS recovery notifications
- MQTT health reporting
- Automatic recovery statistics
- Support for additional OpenWrt-based LoRaWAN gateways

---

## Contributing

Contributions, bug reports, suggestions, and pull requests are welcome.

If you discover improvements or compatibility with additional hardware, feel free to open an Issue or submit a Pull Request.

---

## License

This project is released under the **MIT License**.

---

## Author

**Ehtisham Ul Haq**

IoT Engineer • LoRaWAN • Embedded Systems • OpenWrt • Edge Computing

If this project is useful, consider giving it a ⭐ on GitHub.



---

# Deployment Guide

## Before Deployment

- Backup the original `iot_keep_alive.sh` script.
- Verify that the gateway uses `pppd` for cellular connectivity.
- Test the recovery logic on a local gateway before deploying it to a production site.

---

## Installation

1. Copy the modified script to the gateway.
2. Replace the existing `iot_keep_alive.sh`.
3. Ensure the script has execute permission:

```bash
chmod +x /usr/bin/iot_keep_alive.sh
```

4. Verify the script syntax:

```bash
sh -n /usr/bin/iot_keep_alive.sh
```

The command should return no errors.

---

## Restart

Restart the service or reboot the gateway:

```bash
reboot
```

or

```bash
/etc/init.d/iot restart
```

(depending on your firmware)

---

## Validation

After deployment, verify the following:

- Gateway boots normally.
- Cellular interface establishes a PPP connection.
- Internet connectivity is restored.
- LoRaWAN services reconnect successfully.
- Gateway resumes normal packet forwarding.

---

## Recovery Verification

To validate the recovery logic:

- Disconnect the cellular network.
- Observe PPP recovery.
- Verify the stabilization period.
- Verify cooldown behaviour.
- Restore connectivity during stabilization or cooldown.
- Confirm that the recovery state immediately resets to **NORMAL**.

---

## Log Monitoring

Useful commands:

```bash
logread -f
```

```bash
logread | grep iot_keep_alive
```

```bash
ifconfig
```

```bash
ip route
```

```bash
ps | grep pppd
```

---

## Notes

This recovery logic was designed for gateways using **PPP (`pppd`)** over a cellular connection.

Always validate new changes on a local test gateway before deploying them to remote production gateways.
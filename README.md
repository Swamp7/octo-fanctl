# octo-fanctl

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)

A small, dependency-free fan controller for **Octominer** mining-chassis fan boards
on a plain Linux host (built/tested on Ubuntu 24.04 with the NVIDIA driver).

The Octominer chassis fan board is a USB device (`16c0:05dc`) driven by a bundled
CLI. `octo-fanctl` wraps it in a proper systemd service that sets chassis fan speed
from a **GPU-temperature curve**, with a **CPU-temperature override** that can only
push the fans harder — never slow them below what the GPUs need.

## Quick start

```
git clone https://github.com/Swamp7/octo-fanctl
cd octo-fanctl
sudo ./install.sh          # runs a short setup wizard on first install
```

That's it — the service is enabled and running, and comes back on every boot.
Reconfigure anytime with `sudo /opt/octo-fanctl/octo-fanctl-configure.sh`.

## Features

- **GPU-driven linear curve** — fan duty ramps across an adjustable
  `GPU_TEMP_MIN → GPU_TEMP_MAX` window (`FAN_MIN_PCT → FAN_MAX_PCT`).
- **CPU override** — when the CPU runs hot it raises the fans via its own
  `CPU_TEMP_MIN → CPU_TEMP_MAX` curve; final duty is `max(gpu, cpu)`, so the CPU is a
  safety backstop, not the driver. Reads temps from hwmon sysfs (no lm-sensors dep).
- **Full-speed failsafe** — writes the board's **Default PWM** register to 100% once
  at launch, so if the host stops driving the controller the fans fall back to full.
  Optional board **watchdog** makes that fallback fire actively on a host/USB drop.
- **Gentle on the USB board** — 10 s poll and a write-deadband, to avoid the
  controller-overload a fast poll can cause.
- **First-run wizard** for single hosts; **non-interactive defaults** for fleet deploys.

## Deploy to many machines from a workstation

```
# SSH keys + passwordless sudo:
./deploy.sh user@host1 user@host2

# or with passwords:
SSHPASS='sshpw' SUDO_PASS='sudopw' ./deploy.sh user@host1 user@host2
```

Fleet installs run non-interactively and use the shipped defaults; tune later per host
via `octo-fanctl-configure.sh` or by editing `/etc/octo-fanctl.conf`.

## Configure

The wizard covers the common knobs; the full set lives in `/etc/octo-fanctl.conf`
(then `systemctl restart octo-fanctl`):

| Key | Meaning | Default |
|-----|---------|---------|
| `POLL_SECONDS` | seconds between reads (keep ≥10 for the USB board) | 10 |
| `GPU_TEMP_MIN` / `GPU_TEMP_MAX` | GPU curve window (°C) | 45 / 75 |
| `FAN_MIN_PCT` / `FAN_MAX_PCT` | duty at the ends of the window | 20 / 100 |
| `CPU_OVERRIDE` | enable CPU override (0/1) | 1 |
| `CPU_TEMP_MIN` / `CPU_TEMP_MAX` | CPU override window (°C) | 70 / 90 |
| `DEFAULT_PWM_PCT` | board Default-PWM fallback, set once at launch | 100 |
| `WATCHDOG_ENABLE` | arm board watchdog to force fallback on drop | 0 |
| `FAILSAFE_PCT` | duty on daemon stop / unreadable GPU temp | 100 |

## Watch it run

```
journalctl -u octo-fanctl -f
```

Each cycle logs the GPU/CPU temps, both curve outputs, the chosen duty, and which
input won.

## Requirements

- Linux host with an Octominer fan-controller board on USB (`16c0:05dc`)
- Root (the board's USB node is writable only by root)
- NVIDIA driver / `nvidia-smi` for the GPU curve
- `fan_controller_cli` — **bundled** (see below)

## Bundled `fan_controller_cli` (attribution)

`payload/fan_controller_cli` is Octominer's proprietary CLI (© C_Payne, 2019),
redistributed **as-is** so the tool works out of the box. It is **not** covered by
this repo's MIT license — see [NOTICE](NOTICE). It is a static x86-64 binary, so no
extra libraries are needed. To use your own copy instead, replace it with the
`fan_controller_cli` from your Octominer / SimpleMining install
(`/root/utils/octominer/fan_controller_cli`).

## How the controller board works

`fan_controller_cli -r` dumps all telemetry (serial, PSU voltages, chassis temps,
per-fan RPM/PWM). Fan channels are set with `-f <n> -v <pwm 0-255>` (current speed)
and `-d <n> -v <pwm>` (the Default-PWM register the chip falls back to). A channel is
"present" when its `RPM in percent` field is a number rather than `-nan`.

## License

MIT for the octo-fanctl scripts/service/installer — see [LICENSE](LICENSE).
The bundled `fan_controller_cli` is excluded; see [NOTICE](NOTICE).

#!/usr/bin/env bash
# install.sh — install octo-fanctl on THIS machine. Run as root: sudo ./install.sh
# On an interactive first install it runs a short setup wizard; over SSH / no TTY it
# falls back to the shipped defaults (good for fleet deploys).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/payload"

[[ $EUID -eq 0 ]] || { echo "Please run as root: sudo ./install.sh"; exit 1; }

if [[ ! -x "$SRC/fan_controller_cli" ]]; then
  echo "ERROR: $SRC/fan_controller_cli is missing. See README.md."
  exit 1
fi

command -v nvidia-smi >/dev/null || echo "WARN: nvidia-smi not found — GPU curve runs in failsafe until the driver is present."

install -d /opt/octo-fanctl
install -m 0755 "$SRC/fan_controller_cli"        /opt/octo-fanctl/fan_controller_cli
install -m 0755 "$SRC/octo-fanctl.sh"            /opt/octo-fanctl/octo-fanctl.sh
install -m 0755 "$SRC/octo-fanctl-configure.sh"  /opt/octo-fanctl/octo-fanctl-configure.sh
install -m 0644 "$SRC/octo-fanctl.conf"          /opt/octo-fanctl/octo-fanctl.conf.default
install -m 0644 "$SRC/octo-fanctl.service"       /etc/systemd/system/octo-fanctl.service

# --- config -----------------------------------------------------------------
if [[ -f /etc/octo-fanctl.conf ]]; then
  echo "Keeping existing /etc/octo-fanctl.conf (reconfigure anytime: sudo /opt/octo-fanctl/octo-fanctl-configure.sh)"
elif [[ -t 0 ]]; then
  # interactive first run -> wizard
  /opt/octo-fanctl/octo-fanctl-configure.sh || install -m 0644 "$SRC/octo-fanctl.conf" /etc/octo-fanctl.conf
else
  # non-interactive (deploy) -> defaults
  install -m 0644 "$SRC/octo-fanctl.conf" /etc/octo-fanctl.conf
  echo "Installed default /etc/octo-fanctl.conf (edit + restart, or run octo-fanctl-configure.sh)."
fi

systemctl daemon-reload
systemctl enable --now octo-fanctl

sleep 2
echo "----------------------------------------------------------------"
systemctl --no-pager --full status octo-fanctl | head -n 15 || true
echo "----------------------------------------------------------------"
echo "Done. Reconfigure: sudo /opt/octo-fanctl/octo-fanctl-configure.sh"
echo "Live log:          journalctl -u octo-fanctl -f"

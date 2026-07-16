#!/usr/bin/env bash
# octo-fanctl-configure.sh — interactive setup for octo-fanctl. Re-runnable anytime:
#   sudo /opt/octo-fanctl/octo-fanctl-configure.sh
# Press Enter at any prompt to keep the [current] value.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Please run as root: sudo $0"; exit 1; }

CONF=/etc/octo-fanctl.conf
TEMPLATE=/opt/octo-fanctl/octo-fanctl.conf.default
BASE="$CONF"; [[ -f "$BASE" ]] || BASE="$TEMPLATE"
[[ -f "$TEMPLATE" ]] || { echo "missing template $TEMPLATE"; exit 1; }

# load current values (from live conf if present, else shipped default) as prompt defaults
# shellcheck disable=SC1090
source "$BASE"

ask()    { local def=$1 prompt=$2 ans; read -rp "$prompt [$def]: " ans; printf '%s' "${ans:-$def}"; }
askint() { local v; while :; do v=$(ask "$1" "$2"); [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return; }; echo "  please enter a whole number"; done; }

echo
echo "=== octo-fanctl setup ==="
echo "GPU temperature drives the fans; CPU can only push them harder when it runs hot."
echo
echo "GPU curve (primary):"
GPU_TEMP_MIN=$(askint "${GPU_TEMP_MIN:-45}"  "  GPU temp at which fans sit at minimum (C)")
GPU_TEMP_MAX=$(askint "${GPU_TEMP_MAX:-75}"  "  GPU temp at which fans hit maximum (C)")
FAN_MIN_PCT=$(askint  "${FAN_MIN_PCT:-20}"   "  minimum fan duty (%)")
FAN_MAX_PCT=$(askint  "${FAN_MAX_PCT:-100}"  "  maximum fan duty (%)")
echo "CPU override (raises fans only when CPU is hot — never the main driver):"
CPU_OVERRIDE=$(askint "${CPU_OVERRIDE:-1}"   "  enable CPU override? (1=yes 0=no)")
CPU_TEMP_MIN=$(askint "${CPU_TEMP_MIN:-70}"  "  CPU temp where override starts (C)")
CPU_TEMP_MAX=$(askint "${CPU_TEMP_MAX:-90}"  "  CPU temp for max fan (C)")
echo "Safety / timing:"
DEFAULT_PWM_PCT=$(askint "${DEFAULT_PWM_PCT:-100}" "  board Default-PWM failsafe, set once at launch (%)")
POLL_SECONDS=$(askint "${POLL_SECONDS:-10}"  "  poll interval (s; keep >=10 for the USB board)")

# render conf from the template, swapping values but keeping every comment
tmp=$(mktemp); cp "$TEMPLATE" "$tmp"
set_conf() { sed -i -E "s|^($1=)[0-9]+([[:space:]]*#.*)?\$|\1$2\2|" "$tmp"; }
for k in GPU_TEMP_MIN GPU_TEMP_MAX FAN_MIN_PCT FAN_MAX_PCT \
         CPU_OVERRIDE CPU_TEMP_MIN CPU_TEMP_MAX DEFAULT_PWM_PCT POLL_SECONDS; do
  set_conf "$k" "${!k}"
done
install -m 0644 "$tmp" "$CONF"; rm -f "$tmp"
echo
echo "Wrote $CONF"

if systemctl is-active --quiet octo-fanctl 2>/dev/null; then
  read -rp "Restart octo-fanctl now to apply? [Y/n]: " a
  [[ "${a:-Y}" =~ ^[Nn] ]] || { systemctl restart octo-fanctl; echo "restarted."; }
fi

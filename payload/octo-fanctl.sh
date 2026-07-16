#!/usr/bin/env bash
#
# octo-fanctl.sh — Octominer chassis fan controller for plain Ubuntu + NVIDIA
#
# GPU temperature is the PRIMARY driver: fan % is linearly interpolated between
# GPU_TEMP_MIN (-> FAN_MIN_PCT) and GPU_TEMP_MAX (-> FAN_MAX_PCT).
# CPU temperature is an OVERRIDE only: it can raise the fans above what the GPU
# curve asks for, but never lower them, and contributes nothing below
# CPU_TEMP_MIN. The final duty is max(gpu_curve, cpu_curve).
#
# Talks to the Octominer controller board (USB, VID:PID 16c0:05dc) via the
# static fan_controller_cli. Runs as root (USB node is root-only for writes).
#
set -u

CONF=/etc/octo-fanctl.conf

# ---- defaults (overridable in $CONF) ----------------------------------------
CLI=/opt/octo-fanctl/fan_controller_cli
POLL_SECONDS=10      # matches SMOS cadence; keep >=10 to avoid USB-controller overload

GPU_TEMP_MIN=45      # at/below this GPU temp -> FAN_MIN_PCT
GPU_TEMP_MAX=75      # at/above this GPU temp -> FAN_MAX_PCT
FAN_MIN_PCT=20       # floor duty (%)
FAN_MAX_PCT=100      # ceiling duty (%)

CPU_TEMP_MIN=70      # CPU override starts contributing at this temp
CPU_TEMP_MAX=90      # CPU override reaches FAN_MAX_PCT at this temp
CPU_OVERRIDE=1       # 0 disables the CPU override entirely

FAILSAFE_PCT=100     # duty applied on daemon exit / when GPU temp unreadable
WRITE_DEADBAND=2     # only push a new duty when it moves at least this many %

DEFAULT_PWM_PCT=100      # the board's per-fan "Default PWM" register (-d, USB
                         # opcode WRITE_FAN_DEFAULT). Written once at launch. This is
                         # the value the controller falls back to when the host stops
                         # driving it, so a dropped/idle host runs fans at this speed.
                         # 100% = 255 PWM.

WATCHDOG_ENABLE=0        # 1 = arm the board watchdog so it actively forces the
                         # Default PWM when the host stops talking (USB/host drop).
WATCHDOG_SHORT=120       # -w short timeout (s)
WATCHDOG_LONG=732        # -w long timeout (s)
# -----------------------------------------------------------------------------

[[ -r "$CONF" ]] && source "$CONF"

log() { echo "$(date '+%F %T') $*"; }

pct_to_pwm() { echo $(( $1 * 255 / 100 )); }

clamp() { local v=$1 lo=$2 hi=$3; (( v < lo )) && v=$lo; (( v > hi )) && v=$hi; echo "$v"; }

# Highest GPU temp across all cards. Empty on driver failure.
read_gpu_temp() {
  nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null \
    | tr -d ' ' | grep -E '^[0-9]+$' | sort -rn | head -n1
}

# Highest CPU package/die temp via hwmon sysfs (no lm-sensors dependency).
# 0 when no CPU sensor is found (override simply stays inactive).
read_cpu_temp() {
  local max=0 t f name h
  for h in /sys/class/hwmon/hwmon*; do
    [[ -r "$h/name" ]] || continue
    name=$(cat "$h/name" 2>/dev/null)
    case "$name" in
      coretemp|k10temp|zenpower|cpu_thermal)
        for f in "$h"/temp*_input; do
          [[ -r "$f" ]] || continue
          t=$(cat "$f" 2>/dev/null); [[ "$t" =~ ^[0-9]+$ ]] || continue
          t=$(( t / 1000 ))
          (( t > max )) && max=$t
        done ;;
    esac
  done
  echo "$max"
}

# Linear GPU curve -> duty %
gpu_curve() {
  local t=$1
  (( t <= GPU_TEMP_MIN )) && { echo "$FAN_MIN_PCT"; return; }
  (( t >= GPU_TEMP_MAX )) && { echo "$FAN_MAX_PCT"; return; }
  echo $(( FAN_MIN_PCT + (t - GPU_TEMP_MIN) * (FAN_MAX_PCT - FAN_MIN_PCT) / (GPU_TEMP_MAX - GPU_TEMP_MIN) ))
}

# CPU override curve -> duty % (0 below CPU_TEMP_MIN so it never drives normally)
cpu_curve() {
  local t=$1
  (( CPU_OVERRIDE == 1 )) || { echo 0; return; }
  (( t <= CPU_TEMP_MIN )) && { echo 0; return; }
  (( t >= CPU_TEMP_MAX )) && { echo "$FAN_MAX_PCT"; return; }
  echo $(( (t - CPU_TEMP_MIN) * FAN_MAX_PCT / (CPU_TEMP_MAX - CPU_TEMP_MIN) ))
}

# Space-separated list of populated fan channel indices from a -r dump.
present_fans() {
  awk -F'[ :]+' '/FAN No\. [0-9]+ RPM in percent/ { if ($(NF) != "-nan") print $3 }'
}

set_all_fans() {
  local pwm=$1 data=$2 i
  for i in $(present_fans <<<"$data"); do
    timeout 5 "$CLI" -f "$i" -v "$pwm" >/dev/null 2>&1
  done
}

board_present() { grep -qi 'Serial No' <<<"$1"; }

# Run once at launch: write the board's "Default PWM" register (-d) so that when
# the host stops driving the controller (idle/USB/host drop) the fans fall back to
# DEFAULT_PWM_PCT, and optionally arm the watchdog so that fallback is actively
# forced on a drop. EEPROM write — do NOT call this in the poll loop.
set_board_default() {
  local data=$1 i pwm; pwm=$(pct_to_pwm "$DEFAULT_PWM_PCT")
  for i in $(present_fans <<<"$data"); do
    timeout 5 "$CLI" -d "$i" -v "$pwm" >/dev/null 2>&1
  done
  log "board Default PWM set to ${DEFAULT_PWM_PCT}% (${pwm}) on all present fans"
  if (( WATCHDOG_ENABLE == 1 )); then
    timeout 5 "$CLI" -w "$WATCHDOG_SHORT" -v "$WATCHDOG_LONG" >/dev/null 2>&1
    log "watchdog armed: short=${WATCHDOG_SHORT}s long=${WATCHDOG_LONG}s"
  fi
}

cleanup() {
  local fp; fp=$(pct_to_pwm "$FAILSAFE_PCT")
  local data; data=$("$CLI" -r 2>/dev/null)
  board_present "$data" && set_all_fans "$fp" "$data"
  log "exit: fans set to failsafe ${FAILSAFE_PCT}%"
  exit 0
}
trap cleanup TERM INT

log "octo-fanctl start: GPU ${GPU_TEMP_MIN}-${GPU_TEMP_MAX}C -> ${FAN_MIN_PCT}-${FAN_MAX_PCT}% | CPU override ${CPU_TEMP_MIN}-${CPU_TEMP_MAX}C (on=${CPU_OVERRIDE}) | poll ${POLL_SECONDS}s"

if [[ ! -x "$CLI" ]]; then log "FATAL: $CLI not found/executable"; exit 1; fi

last_pwm=-1
default_done=0
while :; do
  data=$("$CLI" -r 2>/dev/null)
  if ! board_present "$data"; then
    log "controller not responding (no Serial No) — retrying"
    sleep "$POLL_SECONDS"; continue
  fi

  # once, on first successful contact: write the board Default PWM (+ watchdog)
  if (( default_done == 0 )); then
    set_board_default "$data"
    default_done=1
  fi

  gpu=$(read_gpu_temp)
  cpu=$(read_cpu_temp)

  if [[ -z "$gpu" || "$gpu" == 0 ]]; then
    # can't trust GPU temp -> fail safe to cooling rather than risk cooking
    pct=$FAILSAFE_PCT
    log "WARN: GPU temp unreadable -> failsafe ${pct}%"
  else
    g=$(gpu_curve "$gpu")
    c=$(cpu_curve "${cpu:-0}")
    pct=$g
    src="gpu"
    (( c > pct )) && { pct=$c; src="cpu-override"; }
    pct=$(clamp "$pct" "$FAN_MIN_PCT" "$FAN_MAX_PCT")
    log "gpu=${gpu}C cpu=${cpu}C -> gpu_curve=${g}% cpu_curve=${c}% duty=${pct}% (${src})"
  fi

  pwm=$(pct_to_pwm "$pct")
  # deadband: skip USB write unless the duty moved enough
  if (( last_pwm < 0 || pwm > last_pwm + WRITE_DEADBAND*255/100 || pwm < last_pwm - WRITE_DEADBAND*255/100 )); then
    set_all_fans "$pwm" "$data"
    last_pwm=$pwm
  fi

  sleep "$POLL_SECONDS"
done

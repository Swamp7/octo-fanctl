#!/usr/bin/env bash
# deploy.sh — push octo-fanctl from this workstation to one or more servers.
#
#   ./deploy.sh user@host [user@host ...]
#
# Auth (optional env):
#   SSHPASS=...   ssh/scp password (uses sshpass). Omit if you use SSH keys.
#   SUDO_PASS=... remote sudo password (piped to sudo -S). Omit if sudo is NOPASSWD.
#
# Each target gets: /opt/octo-fanctl/{fan_controller_cli,octo-fanctl.sh},
# /etc/octo-fanctl.conf (preserved if already present), the systemd unit, and the
# service enabled + started.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
[[ $# -ge 1 ]] || { echo "usage: [SSHPASS=..] [SUDO_PASS=..] ./deploy.sh user@host [user@host ...]"; exit 1; }
[[ -x "$HERE/payload/fan_controller_cli" ]] || {
  echo "ERROR: payload/fan_controller_cli missing — supply the Octominer binary first (see README.md)."; exit 1; }

SSH=(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
SCP=(scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [[ -n "${SSHPASS:-}" ]]; then export SSHPASS; SSH=(sshpass -e "${SSH[@]}"); SCP=(sshpass -e "${SCP[@]}"); fi

TAR=$(mktemp --suffix=.tgz); trap 'rm -f "$TAR"' EXIT
tar -C "$HERE" -czf "$TAR" payload install.sh

# runs on the target; stdin stays free so sudo -S can read the password
REMOTE_SCRIPT='
set -e
d=$(mktemp -d); tar -C "$d" -xzf /tmp/octo-fanctl.tgz; cd "$d"
if [ -n "${SP:-}" ]; then printf "%s\n" "$SP" | sudo -S bash install.sh; else sudo bash install.sh; fi
rm -rf "$d" /tmp/octo-fanctl.tgz
'

rc=0
for T in "$@"; do
  echo "=================== $T ==================="
  if ! "${SCP[@]}" "$TAR" "$T:/tmp/octo-fanctl.tgz"; then echo "  scp failed"; rc=1; continue; fi
  if ! "${SSH[@]}" "$T" "SP='${SUDO_PASS:-}' bash -c '$REMOTE_SCRIPT'"; then echo "  install failed"; rc=1; fi
done
exit $rc

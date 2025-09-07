#!/usr/bin/env bash
set -euo pipefail

# Camera RTSP Service Uninstaller
# Removes systemd unit, optional user and install directory.

USER_NAME="camera"
PREFIX="/opt/camera-rtsp-service"
REMOVE_USER=0
PURGE=0

usage(){
  cat <<EOF
Usage: $0 [options]
  --user NAME      Service user (default camera)
  --prefix DIR     Install prefix (default /opt/camera-rtsp-service)
  --remove-user    Delete service user
  --purge          Remove install directory
  -h, --help       Help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --remove-user) REMOVE_USER=1; shift;;
    --purge) PURGE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

log(){ echo "[uninstall] $*"; }

if systemctl is-enabled --quiet camera-rtsp.service 2>/dev/null || systemctl is-active --quiet camera-rtsp.service 2>/dev/null; then
  systemctl disable --now camera-rtsp.service || true
fi
rm -f /etc/systemd/system/camera-rtsp.service
systemctl daemon-reload || true

if [[ $PURGE -eq 1 ]]; then
  log "Removing prefix $PREFIX"
  rm -rf "$PREFIX"
fi

if [[ $REMOVE_USER -eq 1 ]]; then
  log "Removing user $USER_NAME"
  userdel "$USER_NAME" 2>/dev/null || true
fi

log "Done"

#!/usr/bin/env bash
# Uninstaller for camera-rtsp-service
# Removes systemd unit, optional install directory, and optionally service user.
# Usage:
#   sudo ./uninstall_service.sh [--install-dir /opt/camera-rtsp-service] [--user rtspcam] [--remove-user] [--purge]
# --purge also deletes logs.
set -euo pipefail

INSTALL_DIR="/opt/camera-rtsp-service"
SERVICE_USER="rtspcam"
SERVICE_NAME="camera-rtsp.service"
REMOVE_USER=false
PURGE=false

log() { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[-]\033[0m %s\n" "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="$2"; shift 2;;
    --user) SERVICE_USER="$2"; shift 2;;
    --remove-user) REMOVE_USER=true; shift;;
    --purge) PURGE=true; shift;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# //'; exit 0;
      ;;
    *) err "Unknown arg: $1"; exit 1;;
  esac
done

if [[ $(id -u) -ne 0 ]]; then err "Run as root."; exit 1; fi

log "Stopping service if running"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true

UNIT_PATH="/etc/systemd/system/$SERVICE_NAME"
if [[ -f $UNIT_PATH ]]; then
  log "Disabling and removing unit file"
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$UNIT_PATH"
  systemctl daemon-reload
else
  warn "Unit file not found ($UNIT_PATH)"
fi

if [[ -d $INSTALL_DIR ]]; then
  if [[ $PURGE == true ]]; then
    log "Removing install directory $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
  else
    warn "Install dir retained (use --purge to remove): $INSTALL_DIR"
  fi
else
  warn "Install dir not found: $INSTALL_DIR"
fi

if [[ $REMOVE_USER == true ]]; then
  if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    log "Removing service user $SERVICE_USER"
    userdel "$SERVICE_USER" 2>/dev/null || warn "Could not remove user (active processes?)"
  else
    warn "User $SERVICE_USER not present"
  fi
fi

log "Uninstall complete."

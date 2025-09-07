#!/usr/bin/env bash
# Automated installer for camera-rtsp-service
# Installs code to /opt (default), creates service user, sets up venv, installs systemd unit, starts service.
# Usage:
#   sudo ./install_service.sh [--install-dir /opt/camera-rtsp-service] [--user rtspcam] \
#        [--port 8554] [--device /dev/video0] [--no-start] [--force] [--codec auto]
#
set -euo pipefail

INSTALL_DIR="/opt/camera-rtsp-service"
SERVICE_USER="rtspcam"
SERVICE_NAME="camera-rtsp.service"
DEVICE="/dev/video0"
PORT=8554
CODEC="auto"
NO_START=false
FORCE=false
PREFER_RAW=false
HARDWARE_PRIORITY="auto"
RECREATE_VENV=false
VERBOSE=false

log() { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[-]\033[0m %s\n" "$*" >&2; }

need_root() { if [[ $(id -u) -ne 0 ]]; then err "Run as root (sudo)."; exit 1; fi; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="$2"; shift 2;;
    --user) SERVICE_USER="$2"; shift 2;;
    --device) DEVICE="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --codec) CODEC="$2"; shift 2;;
    --prefer-raw) PREFER_RAW=true; shift;;
    --hardware-priority) HARDWARE_PRIORITY="$2"; shift 2;;
    --no-start) NO_START=true; shift;;
    --force) FORCE=true; shift;;
    --recreate-venv) RECREATE_VENV=true; shift;;
    --verbose) VERBOSE=true; shift;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# //'; exit 0;
      ;;
    *) err "Unknown arg: $1"; exit 1;;
  esac
done

if [[ $VERBOSE == true ]]; then
  set -x
fi

need_root

if ! command -v systemctl >/dev/null; then err "systemd not found"; exit 1; fi

REPO_ROOT=$(pwd)
if [[ ! -f "$REPO_ROOT/src/main.py" ]]; then
  err "Run this script from the repository root containing src/main.py"; exit 1
fi

if [[ -d "$INSTALL_DIR" && $FORCE == false ]]; then
  warn "Directory $INSTALL_DIR exists (use --force to overwrite)"
else
  if [[ -d "$INSTALL_DIR" && $FORCE == true ]]; then
    warn "Removing existing $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
  fi
  log "Creating install dir $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
fi

if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  log "Creating service user $SERVICE_USER (nologin, video group)"
  useradd -r -s /usr/sbin/nologin -G video "$SERVICE_USER" || {
    warn "Could not create user; attempting usermod"; usermod -a -G video "$SERVICE_USER" || true; }
else
  log "User $SERVICE_USER exists; ensuring video group membership"
  id -nG "$SERVICE_USER" | grep -qw video || usermod -a -G video "$SERVICE_USER"
fi

log "Syncing repository contents"
rsync -a --delete --exclude '.git' --exclude '.venv' "$REPO_ROOT/" "$INSTALL_DIR/"
chown -R "$SERVICE_USER":video "$INSTALL_DIR"

pushd "$INSTALL_DIR" >/dev/null

if [[ ! -f config.ini ]]; then
  if [[ -f config.example.ini ]]; then
    log "Creating config.ini from example"
    cp config.example.ini config.ini
  else
    warn "config.example.ini missing; creating minimal config.ini"
    cat > config.ini <<EOF
[camera]
preflight = true
device = $DEVICE
width = 0
height = 0
framerate = 0
prefer_raw = $PREFER_RAW

[encoding]
codec = $CODEC
bitrate_kbps = 0
auto_bitrate = true
auto_bitrate_factor = 0.00007
hardware_priority = $HARDWARE_PRIORITY
gop_size = 60
tune = zerolatency
speed_preset = ultrafast
profile = baseline

[rtsp]
port = $PORT
mount_path = /stream
kill_existing = false

[logging]
level = INFO
verbose = false
python_log_file = /opt/camera-rtsp-service/app.log
EOF
  fi
else
  log "config.ini already present (not overwriting)"
fi

log "Running environment setup (may install system deps separately if missing)"
# Use system site packages to access gi and gstreamer libs; optionally recreate venv
ENV_CMD="USE_SYSTEM_SITE_PACKAGES=true"
if [[ $RECREATE_VENV == true ]]; then
  ENV_CMD+=" REMOVE_VENV=true"
fi
sudo -u "$SERVICE_USER" bash -c "cd '$INSTALL_DIR' && $ENV_CMD ./setup_env.sh" || {
  warn "Environment setup reported issues";
}

if [[ ! -x "$INSTALL_DIR/.venv/bin/python" ]]; then
  warn "Primary setup did not create venv. Attempting fallback creation.";
  python3 -m venv --system-site-packages "$INSTALL_DIR/.venv" || {
    err "Fallback venv creation failed"; exit 1; }
  chown -R "$SERVICE_USER":video "$INSTALL_DIR/.venv"
fi

if [[ ! -x "$INSTALL_DIR/.venv/bin/python" ]]; then
  err "Virtual environment still missing at $INSTALL_DIR/.venv (aborting).";
  exit 1
fi
log "Virtual environment OK: $INSTALL_DIR/.venv/bin/python"

UNIT_PATH="/etc/systemd/system/$SERVICE_NAME"
log "Writing systemd unit $UNIT_PATH"
cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Camera RTSP Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
Environment=PYTHONUNBUFFERED=1
ExecStart=$INSTALL_DIR/.venv/bin/python src/main.py --config $INSTALL_DIR/config.ini
User=$SERVICE_USER
Group=video
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

log "Reloading systemd daemon"
systemctl daemon-reload

if [[ $NO_START == false ]]; then
  log "Enabling and starting service"
  systemctl enable --now "$SERVICE_NAME"
  systemctl --no-pager status "$SERVICE_NAME" || true
  log "Service installed. RTSP URL: rtsp://$(hostname -f 2>/dev/null || hostname):$PORT/stream"
else
  log "Service unit installed but not started (--no-start). Start with: systemctl start $SERVICE_NAME"
fi

popd >/dev/null

log "Done."

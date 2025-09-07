#!/usr/bin/env bash
set -euo pipefail

# Camera RTSP Service Headless Installer (Debian/Ubuntu & Arch/Manjaro)
# Added distro detection and optional system dependency installation.

USER_NAME="camera"
PREFIX="/opt/camera-rtsp-service"
CONFIG_NAME="config.ini"
PYTHON_BIN="python3"
EXTRA_PIP_ARGS=""
PORT=8554
HEALTH_PORT=0
METRICS_PORT=0
INSTALL_DEPS=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --user NAME              Service user (default: camera)
  --prefix DIR             Install directory (default: /opt/camera-rtsp-service)
  --python PATH            Python executable (default: python3)
  --pip-args "ARGS"        Extra pip install args
  --install-deps           Install required system dependencies (apt / pacman)
  --port N                 RTSP port (default 8554)
  --health-port N          Health endpoint port (0=disabled)
  --metrics-port N         Metrics endpoint port (0=disabled)
  --force                  Reinstall package force
  --no-editable            Do normal install even in git checkout
  --device DEV             Override camera device (default auto)
  --codec CODEC            Override codec (auto|h264|jpeg)
  --bitrate N              Override bitrate_kbps
  -h, --help               Show this help
EOF
}

FORCE=0
NO_EDITABLE=0
DEVICE_OVERRIDE=""
CODEC_OVERRIDE=""
BITRATE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-deps) INSTALL_DEPS=1; shift;;
    --user) USER_NAME="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --python) PYTHON_BIN="$2"; shift 2;;
    --pip-args) EXTRA_PIP_ARGS="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --health-port) HEALTH_PORT="$2"; shift 2;;
    --metrics-port) METRICS_PORT="$2"; shift 2;;
    --force) FORCE=1; shift;;
    --no-editable) NO_EDITABLE=1; shift;;
    --device) DEVICE_OVERRIDE="$2"; shift 2;;
    --codec) CODEC_OVERRIDE="$2"; shift 2;;
    --bitrate) BITRATE_OVERRIDE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

log() { echo "[install] $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  if [[ $INSTALL_DEPS -eq 0 ]]; then
    return
  fi
  if have pacman; then
    log "Installing dependencies via pacman"
    sudo pacman -Sy --needed --noconfirm \
      gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly \
      gst-libav gst-rtsp-server python-gobject python-pip
    # Optional hardware extras suggestions (not auto):
    echo "[install] (Optional) For VAAPI: pacman -S --needed libva-intel-driver libva-mesa-driver" >&2
    echo "[install] (Optional) For NVIDIA NVENC ensure proprietary driver installed" >&2
  elif have apt-get; then
    log "Installing dependencies via apt"
    sudo apt-get update
    sudo apt-get install -y python3-gi gir1.2-gst-rtsp-server-1.0 \
      gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
      gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav python3-pip
  else
    log "No supported package manager found (pacman or apt-get). Skipping system dependencies." >&2
  fi
}

install_deps

# Adjust nologin path (Arch uses /usr/bin/nologin)
NOLOGIN_BIN=$(command -v nologin || echo /usr/sbin/nologin)

# Create user if needed
if id "$USER_NAME" >/dev/null 2>&1; then
  log "User $USER_NAME exists"
else
  log "Creating system user $USER_NAME"
  useradd -r -s "$NOLOGIN_BIN" -d "$PREFIX" "$USER_NAME" || {
    log "useradd failed; trying adduser"; adduser --system --home "$PREFIX" --shell "$NOLOGIN_BIN" "$USER_NAME"; }
fi
usermod -aG video "$USER_NAME" || true

mkdir -p "$PREFIX"
chown "$USER_NAME":"$USER_NAME" "$PREFIX"

# Install package
if [[ -f "pyproject.toml" && $NO_EDITABLE -eq 0 ]]; then
  if [[ $FORCE -eq 1 ]]; then
    log "Editable install (force)"
    pip install --upgrade --force-reinstall -e . $EXTRA_PIP_ARGS
  else
    log "Editable install"
    pip install -e . $EXTRA_PIP_ARGS
  fi
else
  if [[ $FORCE -eq 1 ]]; then
    pip install --upgrade --force-reinstall camera-rtsp-service $EXTRA_PIP_ARGS
  else
    pip install camera-rtsp-service $EXTRA_PIP_ARGS
  fi
fi

CONFIG_PATH="$PREFIX/$CONFIG_NAME"
if [[ ! -f "$CONFIG_PATH" ]]; then
  log "Deploying default config"
  if [[ -f config.example.ini ]]; then
    cp config.example.ini "$CONFIG_PATH"
  else
    cat > "$CONFIG_PATH" <<EOC
[camera]
device = auto
preflight = true
width = 0
height = 0
framerate = 0
prefer_raw = false

[encoding]
codec = auto
bitrate_kbps = 0
auto_bitrate = true
auto_bitrate_factor = 0.00007
gop_size = 60
tune = zerolatency
speed_preset = ultrafast
profile = baseline
hardware_priority = auto

[rtsp]
port = $PORT
mount_path = /stream
kill_existing = false

[logging]
level = INFO
verbose = false
python_log_file =

[health]
health_port = $HEALTH_PORT
metrics_port = $METRICS_PORT
EOC
  fi
fi

# Apply overrides (idempotent inline edits)
if [[ -n "$DEVICE_OVERRIDE" ]]; then
  sed -i "s/^device = .*/device = $DEVICE_OVERRIDE/" "$CONFIG_PATH" || true
fi
if [[ -n "$CODEC_OVERRIDE" ]]; then
  sed -i "s/^codec = .*/codec = $CODEC_OVERRIDE/" "$CONFIG_PATH" || true
fi
if [[ -n "$BITRATE_OVERRIDE" ]]; then
  sed -i "s/^bitrate_kbps = .*/bitrate_kbps = $BITRATE_OVERRIDE/" "$CONFIG_PATH" || true
fi

UNIT_FILE="/etc/systemd/system/camera-rtsp.service"
cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=Camera RTSP Service
After=network.target

[Service]
Type=simple
User=$USER_NAME
Group=$USER_NAME
WorkingDirectory=$PREFIX
Environment=PYTHONUNBUFFERED=1
ExecStart=$(command -v cam-rtsp) run -c $CONFIG_PATH
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now camera-rtsp.service

log "Installed. URL: rtsp://$(hostname -f):$PORT/stream"
exit 0

#!/usr/bin/env bash
# Camera RTSP Service Headless Installer (Debian/Ubuntu & Arch/Manjaro)
# Added distro detection, optional system dependency installation, Arch venv handling.
set -euo pipefail

USER_NAME="camera"
PREFIX="/opt/camera-rtsp-service"
CONFIG_NAME="config.ini"
PYTHON_BIN="python3"
EXTRA_PIP_ARGS=""
PORT=8554
HEALTH_PORT=0
METRICS_PORT=0
INSTALL_DEPS=0
FORCE=0
NO_EDITABLE=0
DEVICE_OVERRIDE=""
CODEC_OVERRIDE=""
BITRATE_OVERRIDE=""
USE_SYSTEM=0  # force system pip (Arch needs --break-system-packages)

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --user NAME              Service user (default: camera)
  --prefix DIR             Install directory (default: /opt/camera-rtsp-service)
  --python PATH            Python executable (default: python3)
  --pip-args "ARGS"        Extra pip install args
  --install-deps           Install required system dependencies (apt / pacman)
  --system                 Force system site install (pass --break-system-packages on Arch)
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-deps) INSTALL_DEPS=1; shift;;
    --system) USE_SYSTEM=1; shift;;
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
err() { echo "[install][error] $*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  if [[ $INSTALL_DEPS -eq 0 ]]; then return; fi
  if have pacman; then
    log "Installing dependencies via pacman"
    sudo pacman -Sy --needed --noconfirm \
      gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly \
      gst-libav gst-rtsp-server python-gobject python-pip
    echo "[install] (Optional) VAAPI: pacman -S --needed libva-intel-driver libva-mesa-driver" >&2
    echo "[install] (Optional) NVIDIA: ensure proprietary driver installed" >&2
  elif have apt-get; then
    log "Installing dependencies via apt"
    sudo apt-get update
    sudo apt-get install -y python3-gi gir1.2-gst-rtsp-server-1.0 \
      gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
      gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav python3-pip
  else
    log "No supported package manager (apt-get/pacman) found; skipping system deps" >&2
  fi
}

install_deps

if ! have "$PYTHON_BIN"; then err "Python not found: $PYTHON_BIN"; exit 2; fi
have systemctl || { err "systemctl required"; exit 2; }

NOLOGIN_BIN=$(command -v nologin || echo /usr/sbin/nologin)
mkdir -p "$PREFIX"
if ! id "$USER_NAME" >/dev/null 2>&1; then
  log "Creating system user $USER_NAME"
  useradd -r -s "$NOLOGIN_BIN" -d "$PREFIX" "$USER_NAME" || adduser --system --home "$PREFIX" --shell "$NOLOGIN_BIN" "$USER_NAME" || true
fi
usermod -aG video "$USER_NAME" || true
chown "$USER_NAME":"$USER_NAME" "$PREFIX"

# Decide installation mode (Arch default: venv)
VENV_DIR="$PREFIX/venv"
USE_VENV=0
if have pacman && [[ $USE_SYSTEM -eq 0 ]]; then
  USE_VENV=1
fi

PIP_CMD="pip"
if [[ $USE_VENV -eq 1 ]]; then
  if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating virtualenv $VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  "$VENV_DIR/bin/pip" install --upgrade pip
  PIP_CMD="$VENV_DIR/bin/pip"
fi

if [[ $USE_SYSTEM -eq 1 && have pacman ]]; then
  EXTRA_PIP_ARGS="$EXTRA_PIP_ARGS --break-system-packages"
fi

# Install package
if [[ -f "pyproject.toml" && $NO_EDITABLE -eq 0 ]]; then
  if [[ $FORCE -eq 1 ]]; then
    log "Editable install (force)"
    $PIP_CMD install --upgrade --force-reinstall -e . $EXTRA_PIP_ARGS
  else
    log "Editable install"
    $PIP_CMD install -e . $EXTRA_PIP_ARGS
  fi
else
  if [[ $FORCE -eq 1 ]]; then
    $PIP_CMD install --upgrade --force-reinstall camera-rtsp-service $EXTRA_PIP_ARGS
  else
    $PIP_CMD install camera-rtsp-service $EXTRA_PIP_ARGS
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

# Apply overrides
[[ -n "$DEVICE_OVERRIDE" ]] && sed -i "s/^device = .*/device = $DEVICE_OVERRIDE/" "$CONFIG_PATH" || true
[[ -n "$CODEC_OVERRIDE" ]] && sed -i "s/^codec = .*/codec = $CODEC_OVERRIDE/" "$CONFIG_PATH" || true
[[ -n "$BITRATE_OVERRIDE" ]] && sed -i "s/^bitrate_kbps = .*/bitrate_kbps = $BITRATE_OVERRIDE/" "$CONFIG_PATH" || true

CAM_RTSP_BIN=$(command -v cam-rtsp)
if [[ $USE_VENV -eq 1 ]]; then
  CAM_RTSP_BIN="$VENV_DIR/bin/cam-rtsp"
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
ExecStart=$CAM_RTSP_BIN run -c $CONFIG_PATH
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now camera-rtsp.service

log "Installed. URL: rtsp://$(hostname -f):$PORT/stream (venv=$USE_VENV)"

#!/usr/bin/env bash
# Camera RTSP Service Headless Installer (Debian/Ubuntu & Arch/Manjaro)
# Always creates isolated virtualenv at <prefix>/venv unless --system supplied.
# Installs system prerequisites by default (disable with --no-deps).
set -euo pipefail

USER_NAME="camera"
PREFIX="/opt/camera-rtsp-service"
CONFIG_NAME="config.ini"
PYTHON_BIN="python3"
EXTRA_PIP_ARGS=""
PORT=8554
HEALTH_PORT=0
METRICS_PORT=0
INSTALL_DEPS=1
FORCE=0
NO_EDITABLE=0
DEVICE_OVERRIDE=""
CODEC_OVERRIDE=""
BITRATE_OVERRIDE=""
USE_SYSTEM=0
UPGRADE_ENV=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --user NAME              Service user (default: camera)
  --prefix DIR             Install directory (default: /opt/camera-rtsp-service)
  --python PATH            Python executable (default: python3)
  --pip-args "ARGS"        Extra pip install args passed to pip
  --no-deps                Skip system dependency installation
  --install-deps           (Deprecated / no-op) System deps are installed by default
  --system                 Install into system site-packages (NOT recommended)
  --upgrade                Recreate/upgrade virtualenv & update package
  --port N                 RTSP port (default 8554)
  --health-port N          Health endpoint port (0=disabled)
  --metrics-port N         Metrics endpoint port (0=disabled)
  --force                  Force reinstall (pip --force-reinstall)
  --no-editable            Disable editable install even in checkout
  --device DEV             Override camera.device
  --codec CODEC            Override encoding.codec (auto|h264|jpeg)
  --bitrate N              Override encoding.bitrate_kbps
  -h, --help               Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-deps) INSTALL_DEPS=0; shift;;
    --install-deps) INSTALL_DEPS=1; shift;;
    --system) USE_SYSTEM=1; shift;;
    --upgrade) UPGRADE_ENV=1; shift;;
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

# Auto-disable editable if installing for different service user or prefix != repo path
if [[ $NO_EDITABLE -eq 0 ]]; then
  if [[ "$USER_NAME" != "$(id -un 2>/dev/null || echo root)" || "$PREFIX" != "$PWD" ]]; then
    echo "[install] Disabling editable install (service user or prefix differs)"
    NO_EDITABLE=1
  fi
fi

log(){ echo "[install] $*"; }
err(){ echo "[install][error] $*" >&2; }

command -v "$PYTHON_BIN" >/dev/null || { err "Python not found: $PYTHON_BIN"; exit 2; }
command -v systemctl >/dev/null || { err "systemctl required"; exit 2; }

if [[ $INSTALL_DEPS -eq 1 ]]; then
  if command -v pacman >/dev/null 2>&1; then
    log "Installing dependencies (pacman)"
    # Core + ffmpeg and jq for testing / config inspection
    sudo pacman -Sy --needed --noconfirm \
      gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly \
      gst-libav gst-rtsp-server python-gobject python-pip ffmpeg jq
    log "Optional VAAPI: pacman -S --needed libva-intel-driver libva-mesa-driver"
    log "Optional NVIDIA: proprietary driver already installed if using NVENC"
  elif command -v apt-get >/dev/null 2>&1; then
    log "Installing dependencies (apt)"
    sudo apt-get update
    sudo apt-get install -y python3-gi gir1.2-gst-rtsp-server-1.0 \
      gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
      gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav python3-pip ffmpeg jq
  else
    log "Skipping system deps (neither pacman nor apt-get found)"
  fi
else
  log "Skipping dependency installation (user requested --no-deps)"
fi

NOLOGIN_BIN=$(command -v nologin || echo /usr/sbin/nologin)
mkdir -p "$PREFIX"
if ! id "$USER_NAME" >/dev/null 2>&1; then
  log "Creating user $USER_NAME"
  useradd -r -s "$NOLOGIN_BIN" -d "$PREFIX" "$USER_NAME" 2>/dev/null || adduser --system --home "$PREFIX" --shell "$NOLOGIN_BIN" "$USER_NAME" || true
fi
usermod -aG video "$USER_NAME" || true
chown "$USER_NAME":"$USER_NAME" "$PREFIX"

VENV_DIR="$PREFIX/venv"
PIP="pip"
if [[ $USE_SYSTEM -eq 0 ]]; then
  VENV_ARGS="--upgrade-deps"
  if command -v pacman >/dev/null 2>&1; then
    VENV_ARGS="$VENV_ARGS --system-site-packages"
    log "Using --system-site-packages so python-gobject (gi) from system is visible"
  fi
  if [[ ! -d "$VENV_DIR" || $UPGRADE_ENV -eq 1 ]]; then
    log "Creating/Updating virtualenv: $VENV_DIR ($VENV_ARGS)"
    "$PYTHON_BIN" -m venv "$VENV_DIR" $VENV_ARGS || "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  PIP="$VENV_DIR/bin/pip"
  if command -v pacman >/dev/null 2>&1; then
    if ! python -c 'import gi' 2>/dev/null; then
      log "gi not found inside venv; injecting system site-packages path fallback"
      SYS_SITE=$($PYTHON_BIN -c 'import site,sys; print(next(p for p in site.getsitepackages() if p.endswith("site-packages")))') || SYS_SITE="/usr/lib/python$(python -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')/site-packages"
      echo "$SYS_SITE" > "$VENV_DIR/lib/python$(python -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')/site-packages/_system_site_fix.pth" || true
      if python -c 'import gi' 2>/dev/null; then
        log "gi import succeeded after path injection"
      else
        err "Still cannot import gi; attempting source build (PyGObject + pycairo)"
        # Attempt to install build prerequisites (best effort)
        sudo pacman -Sy --needed --noconfirm gobject-introspection pkgconf cairo glib2 base-devel || true
        $PIP install --no-binary=:all: pycairo || true
        $PIP install --no-binary=:all: PyGObject || true
        if python -c 'import gi' 2>/dev/null; then
          log "gi available after PyGObject build"
        else
          err "PyGObject build fallback failed; please ensure system python-gobject supports Python version and retry."
        fi
      fi
    fi
  fi
else
  if command -v pacman >/dev/null 2>&1; then
    EXTRA_PIP_ARGS="$EXTRA_PIP_ARGS --break-system-packages"
  fi
fi

# Install / upgrade package
if [[ -f pyproject.toml && $NO_EDITABLE -eq 0 ]]; then
  if [[ $FORCE -eq 1 ]]; then
    log "Editable force reinstall"
    $PIP install --upgrade --force-reinstall -e . $EXTRA_PIP_ARGS
  else
    log "Editable install"
    $PIP install -e . $EXTRA_PIP_ARGS
  fi
else
  if [[ $NO_EDITABLE -eq 1 ]]; then
    log "Standard (non-editable) install"
  fi
  if [[ -f pyproject.toml ]]; then
    log "Local source (sdist/wheel) install from current checkout"
    if [[ $FORCE -eq 1 ]]; then
      $PIP install --upgrade --force-reinstall . $EXTRA_PIP_ARGS
    else
      $PIP install --upgrade . $EXTRA_PIP_ARGS
    fi
  else
    if [[ $FORCE -eq 1 ]]; then
      $PIP install --upgrade --force-reinstall camera-rtsp-service $EXTRA_PIP_ARGS || { err "Package camera-rtsp-service not found on index and no local source present"; exit 3; }
    else
      $PIP install --upgrade camera-rtsp-service $EXTRA_PIP_ARGS || { err "Package camera-rtsp-service not found on index and no local source present"; exit 3; }
    fi
  fi
fi

CONFIG_PATH="$PREFIX/$CONFIG_NAME"
if [[ ! -f "$CONFIG_PATH" ]]; then
  log "Writing default config: $CONFIG_PATH"
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

# Overrides
[[ -n "$DEVICE_OVERRIDE" ]] && sed -i "s/^device = .*/device = $DEVICE_OVERRIDE/" "$CONFIG_PATH" || true
[[ -n "$CODEC_OVERRIDE" ]] && sed -i "s/^codec = .*/codec = $CODEC_OVERRIDE/" "$CONFIG_PATH" || true
[[ -n "$BITRATE_OVERRIDE" ]] && sed -i "s/^bitrate_kbps = .*/bitrate_kbps = $BITRATE_OVERRIDE/" "$CONFIG_PATH" || true

CAM_BIN=$(command -v cam-rtsp)
if [[ $USE_SYSTEM -eq 0 ]]; then
  CAM_BIN="$VENV_DIR/bin/cam-rtsp"
fi

UNIT_FILE="/etc/systemd/system/camera-rtsp.service"
log "Creating systemd unit $UNIT_FILE"
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
ExecStart=$CAM_BIN run -c $CONFIG_PATH
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now camera-rtsp.service

log "Install complete"
log "  Stream: rtsp://$(hostname -f):$PORT/stream"
if [[ $HEALTH_PORT -ne 0 ]]; then log "  Health: http://$(hostname -f):$HEALTH_PORT/"; fi
if [[ $METRICS_PORT -ne 0 ]]; then log " Metrics: http://$(hostname -f):$METRICS_PORT/"; fi
log "   Mode: $( [[ $USE_SYSTEM -eq 0 ]] && echo venv || echo system )"
log "Next steps:";
log "  1) Dump config: sudo $CAM_BIN dump-config -c $CONFIG_PATH | jq";
log "  2) Preflight:  sudo $CAM_BIN preflight -c $CONFIG_PATH";
log "  3) Test:      ffplay -rtsp_transport tcp rtsp://$(hostname -f):$PORT/stream";
log "  4) Logs:      journalctl -u camera-rtsp.service -f";

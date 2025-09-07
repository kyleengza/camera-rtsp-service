#!/usr/bin/env bash
# Camera RTSP Service environment setup script
# Supports Debian/Ubuntu/RPi and Arch/Manjaro. Installs/validates system deps,
# creates venv (optionally with system site packages for gi), bootstraps pip, and
# verifies GStreamer bindings and x264enc presence.

set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-python3}"
VENVDIR=".venv"
NO_INSTALL="${NO_INSTALL:-false}"   # set NO_INSTALL=true to only check
REMOVE_VENV="${REMOVE_VENV:-false}"  # set REMOVE_VENV=true to delete existing venv first
USE_SYSTEM_SITE_PACKAGES="${USE_SYSTEM_SITE_PACKAGES:-false}" # true: venv sees system gi
RUN_PREFLIGHT="${RUN_PREFLIGHT:-false}"  # run a basic camera preflight after setup
CAMERA_DEVICE="${CAMERA_DEVICE:-/dev/video0}"

REQ_DEB=(python3-gi python3-gi-cairo gir1.2-gst-rtsp-server-1.0 \
  gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav v4l-utils)
REQ_ARCH=(gstreamer python-gobject gst-rtsp-server gst-plugins-base gst-plugins-good \
  gst-plugins-bad gst-plugins-ugly gst-libav v4l-utils gobject-introspection)

color() { printf '\033[%sm%s\033[0m' "$1" "$2"; }

os_id=""; os_like=""; if [ -f /etc/os-release ]; then . /etc/os-release; os_id="${ID:-}"; os_like="${ID_LIKE:-}"; fi
is_deb=false; is_arch=false
[[ $os_id =~ (debian|ubuntu|raspbian) || $os_like =~ (debian|ubuntu) ]] && is_deb=true
[[ $os_id =~ (arch|manjaro|endeavouros|arcolinux) || $os_like =~ arch ]] && is_arch=true
command -v pacman >/dev/null && ! $is_arch && is_arch=true
command -v apt-get >/dev/null && ! $is_deb && is_deb=true

check_installed_deb() { dpkg -s "$1" &>/dev/null; }
check_installed_arch() { pacman -Qi "$1" &>/dev/null; }

missing=()
if $is_deb; then
  for p in "${REQ_DEB[@]}"; do check_installed_deb "$p" || missing+=("$p"); done
elif $is_arch; then
  for p in "${REQ_ARCH[@]}"; do check_installed_arch "$p" || missing+=("$p"); done
else
  echo "$(color 33 'WARN') Unknown distro – skipping automated system package check" >&2
fi

if [ ${#missing[@]} -gt 0 ]; then
  echo "$(color 31 '[MISSING]') System packages: ${missing[*]}"
  if [ "$NO_INSTALL" = true ]; then
    echo "Skipping install (NO_INSTALL=true)"
  else
    if $is_deb; then
      echo "Attempting: sudo apt update && sudo apt install -y ${missing[*]}"
      sudo apt update && sudo apt install -y "${missing[@]}"
    elif $is_arch; then
      echo "Attempting: sudo pacman -Syu --needed ${missing[*]}"
      sudo pacman -Syu --needed "${missing[@]}"
    fi
  fi
else
  echo "$(color 32 '[OK]') Required system packages present"
fi

echo "[*] Checking Python executable..."
command -v "$PYTHON_BIN" >/dev/null || { echo "Python not found: $PYTHON_BIN" >&2; exit 1; }

if [ "$REMOVE_VENV" = true ] && [ -d "$VENVDIR" ]; then
  echo "[*] Removing existing virtual environment ($VENVDIR)"
  rm -rf "$VENVDIR"
fi

if [ ! -d "$VENVDIR" ]; then
  echo "[*] Creating virtual environment in $VENVDIR (system-site-packages=$USE_SYSTEM_SITE_PACKAGES)"
  if [ "$USE_SYSTEM_SITE_PACKAGES" = true ]; then
    "$PYTHON_BIN" -m venv --system-site-packages "$VENVDIR" || { echo "Failed to create venv" >&2; exit 1; }
  else
    "$PYTHON_BIN" -m venv "$VENVDIR" || { echo "Failed to create venv" >&2; exit 1; }
  fi
fi

# shellcheck disable=SC1091
source "$VENVDIR/bin/activate"

if ! python -c 'import pip' 2>/dev/null; then
  echo "[*] Bootstrapping pip with ensurepip"
  python -m ensurepip --upgrade || echo "WARNING: ensurepip failed; install system python-pip"
fi

echo "[*] Upgrading pip/setuptools/wheel"
python -m pip install -q --upgrade pip setuptools wheel || echo "WARNING: pip upgrade failed"

echo "[*] Installing Python requirements"
if [ -s requirements.txt ]; then
  pip install -r requirements.txt
else
  echo "(requirements.txt empty – skipping)"
fi

echo "[*] Verifying GStreamer Python bindings"
python - <<'EOF'
try:
    import gi
    gi.require_version('Gst', '1.0')
    from gi.repository import Gst
    Gst.init(None)
    print('GStreamer bindings OK')
except Exception as e:
    print('WARNING: GStreamer not ready ->', e)
EOF

if command -v gst-inspect-1.0 >/dev/null; then
  if ! gst-inspect-1.0 x264enc >/dev/null 2>&1; then
    echo 'WARNING: x264enc plugin missing (install ugly/bad plugin sets)' >&2
  fi
else
  echo 'WARNING: gst-inspect-1.0 not found – GStreamer runtime likely incomplete' >&2
fi

echo "[*] Setup complete. Activate with: source $VENVDIR/bin/activate"

if ! python -c 'import gi, gi.repository.Gst' 2>/dev/null; then
  echo 'Hint: try USE_SYSTEM_SITE_PACKAGES=true REMOVE_VENV=true ./setup_env.sh or install python-gobject system-wide.' >&2
fi

if [ "$RUN_PREFLIGHT" = true ]; then
  echo "[*] Running preflight test on $CAMERA_DEVICE (5s timeout)"
  GST_DEBUG=1 gst-launch-1.0 -q v4l2src device="$CAMERA_DEVICE" num-buffers=5 ! fakesink || \
    echo 'Preflight pipeline failed (non-fatal here; main app will attempt its own)'
fi

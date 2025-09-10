#!/usr/bin/env sh
###############################################################################
# prep.sh
#
# PURPOSE:
#   Minimal preparation script for the two‑step POC camera streaming setup.
#   1) Verifies required system packages / tools (gst-rtsp-launch OR gst-launch-1.0,
#      and optionally ffmpeg for testing) plus Python + OpenCV if HTTP MJPEG used.
#   2) Creates a lightweight Python virtual environment only if you request MJPEG
#      HTTP preview (optional) – RTSP itself is run purely with GStreamer.
#   3) Writes an example run command for the second script.
#
# USAGE:
#   sh scripts/prep.sh            # default auto-detect device
#   DEVICE=/dev/video2 sh scripts/prep.sh
#   SKIP_HTTP=1 sh scripts/prep.sh   # skip installing python/opencv, only RTSP
#
# OUTPUT:
#   - Prints chosen video device and suggested run command.
#   - Creates .env file with DEVICE and PORT variables for run_rtsp.sh.
#
# REQUIREMENTS (system):
#   - GStreamer runtime with RTSP helper: packages usually named:
#       Debian/Ubuntu: sudo apt install -y gstreamer1.0-tools gstreamer1.0-plugins-base \
#                                   gstreamer1.0-plugins-good gstreamer1.0-libav \
#                                   gstreamer1.0-rtsp
#     (If gstreamer1.0-rtsp not available, it may be bundled in gst-rtsp-server pkg.)
#   - For H.264 encoding (software): x264 via x264enc in -plugins-ugly or libav.
#       sudo apt install -y gstreamer1.0-plugins-ugly
#
# NOTES:
#   - We intentionally keep EVERYTHING in two scripts; no daemon units, no Python
#     package install required for RTSP. Pure gst-rtsp-launch is the simplest path.
#   - Unauthenticated RTSP on port 8554; network access controls are up to you.
###############################################################################
set -eu

DEVICE="${DEVICE:-auto}"
PORT="${PORT:-8554}"
FRAMERATE="${FRAMERATE:-30}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
BITRATE_KBPS="${BITRATE_KBPS:-2000}"      # Approx target bitrate for x264enc
GOP_SECONDS="${GOP_SECONDS:-1}"          # Keyframe interval seconds
SKIP_HTTP="${SKIP_HTTP:-0}"               # If 1, skip python MJPEG prep

# Locate gst-rtsp-launch (preferred) else fallback plan using gst-rtsp-server examples
GST_RTSP_LAUNCH=$(command -v gst-rtsp-launch || true)
if [ -z "$GST_RTSP_LAUNCH" ]; then
  echo "[WARN] gst-rtsp-launch not found. Trying gst-launch-1.0 presence just to warn early." >&2
  if ! command -v gst-launch-1.0 >/dev/null 2>&1; then
    echo "[ERROR] Neither gst-rtsp-launch nor gst-launch-1.0 present. Install GStreamer packages." >&2
    exit 1
  fi
  echo "[ERROR] gst-rtsp-launch missing; install gst-rtsp-server package providing the helper." >&2
  exit 1
fi

echo "[INFO] Found gst-rtsp-launch: $GST_RTSP_LAUNCH"

# Auto-pick device if requested
if [ "$DEVICE" = "auto" ]; then
  CANDIDATE=$(for d in /dev/video*; do [ -r "$d" ] && echo "$d"; done | head -n1 || true)
  if [ -z "$CANDIDATE" ]; then
    echo "[ERROR] No readable /dev/video* devices found." >&2
    exit 1
  fi
  DEVICE="$CANDIDATE"
fi

echo "[INFO] Using device: $DEVICE"

# Optional MJPEG HTTP preview (OpenCV) env
if [ "$SKIP_HTTP" != "1" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[WARN] python3 not found; skipping HTTP preview setup." >&2
  else
    if [ ! -d ".venv" ]; then
      echo "[INFO] Creating virtualenv (.venv)";
      python3 -m venv .venv
    fi
    # shellcheck disable=SC1091
    . ./.venv/bin/activate
    pip install --upgrade pip >/dev/null 2>&1 || true
    pip install opencv-python-headless >/dev/null 2>&1 || {
      echo "[WARN] Failed to install OpenCV; HTTP preview will be unavailable." >&2
    }
    deactivate || true
  fi
else
  echo "[INFO] SKIP_HTTP=1 set; skipping python env.";
fi

# Calculate key-int (GOP) in frames
KEY_INT=$((FRAMERATE * GOP_SECONDS))

cat > .env <<EOF
DEVICE=$DEVICE
PORT=$PORT
FRAMERATE=$FRAMERATE
WIDTH=$WIDTH
HEIGHT=$HEIGHT
BITRATE_KBPS=$BITRATE_KBPS
KEY_INT=$KEY_INT
EOF

echo "[INFO] Wrote .env with runtime parameters.";

cat <<EONOTE
------------------------------------------------------------------------------
NEXT STEP:
  sh scripts/run_rtsp.sh
OR modify .env then run again.

RTSP URL (no auth): rtsp://<host>:$PORT/stream
------------------------------------------------------------------------------
Pipeline elements chosen:
  v4l2src device=$DEVICE ! video/x-raw,width=$WIDTH,height=$HEIGHT,framerate=$FRAMERATE/1 \
    ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast bitrate=$BITRATE_KBPS key-int-max=$KEY_INT \
    ! rtph264pay name=pay0 pt=96 config-interval=1
------------------------------------------------------------------------------
EONOTE

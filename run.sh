#!/usr/bin/env sh
# Purpose: Launch an unauthenticated RTSP H.264 stream on port 8554 from a V4L2 camera using gst-rtsp-launch.
# This is the runtime half of the 2-script POC (prep.sh + run.sh).
#
# Requirements:
#   - GStreamer RTSP server helper (gst-rtsp-launch) installed (see prep.sh)
#   - A V4L2 camera device (e.g., /dev/video0)
#
# Usage:
#   sh run.sh                 # Uses defaults
#   DEVICE=/dev/video2 FPS=15 BITRATE=1500 PORT=8554 MOUNT=stream sh run.sh
#
# Environment variables (all optional):
#   DEVICE   - V4L2 device path (default: first /dev/video* found)
#   WIDTH    - Frame width (optional cap)
#   HEIGHT   - Frame height (optional cap)
#   FPS      - Frames per second (default: 30)
#   BITRATE  - kbps target for x264enc (default: 2000)
#   PORT     - TCP port for RTSP server (default: 8554)
#   MOUNT    - Mount name (rtsp://host:PORT/MOUNT) (default: stream)
#   EXTRA    - Extra elements inserted after v4l2src caps (e.g., "videoflip method=horizontal-flip !")
#
# Notes:
#   - Unauthenticated (deliberately minimal POC).
#   - To stop: Ctrl+C (SIGINT) — we rely on gst-rtsp-launch to exit.
#   - For low latency we use tune=zerolatency, ultrafast preset, key-int-max=FPS, config-interval=1.
#   - If hardware encoders are desired, replace x264enc with something like v4l2h264enc or vaapih264enc (ensure installed).
#
# Troubleshooting:
#   - If you see "Could not open resource for reading": check DEVICE path and permissions.
#   - If stream is inaccessible: verify nothing else is bound to PORT and firewall allows it.
#   - Test with: ffplay rtsp://127.0.0.1:8554/${MOUNT:-stream}

set -eu

if ! command -v gst-rtsp-launch >/dev/null 2>&1; then
  echo "[run][error] gst-rtsp-launch not found. Run ./prep.sh first or install gstreamer1.0-rtsp." >&2
  exit 1
fi

# Resolve defaults
DEVICE=${DEVICE:-$(ls -1 /dev/video* 2>/dev/null | head -n1 || true)}
FPS=${FPS:-30}
BITRATE=${BITRATE:-2000}
PORT=${PORT:-8554}
MOUNT=${MOUNT:-stream}
WIDTH=${WIDTH:-}
HEIGHT=${HEIGHT:-}
EXTRA=${EXTRA:-}

if [ -z "$DEVICE" ]; then
  echo "[run][error] No video device found and DEVICE not set." >&2
  exit 1
fi

if [ ! -e "$DEVICE" ]; then
  echo "[run][error] DEVICE '$DEVICE' does not exist." >&2
  exit 1
fi

CAPS="video/x-raw,framerate=${FPS}/1"
if [ -n "$WIDTH" ]; then
  CAPS="${CAPS},width=${WIDTH}"
fi
if [ -n "$HEIGHT" ]; then
  CAPS="${CAPS},height=${HEIGHT}"
fi

# Build pipeline. Parentheses required by gst-rtsp-launch syntax.
# Single media factory at /$MOUNT
PIPELINE="( v4l2src device=${DEVICE} ! ${CAPS} ! ${EXTRA} videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast bitrate=${BITRATE} key-int-max=${FPS} ! rtph264pay name=pay0 pt=96 config-interval=1 )"

echo "[run] Launching RTSP stream on rtsp://0.0.0.0:${PORT}/${MOUNT} from ${DEVICE}" \
     "(FPS=${FPS} BITRATE=${BITRATE}kbps ${WIDTH:+WIDTH=$WIDTH} ${HEIGHT:+HEIGHT=$HEIGHT})"

echo "[run] Pipeline: $PIPELINE"

gst-rtsp-launch -p "$PORT" "$PIPELINE" --mount=/$MOUNT

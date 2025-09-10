#!/usr/bin/env sh
###############################################################################
# run_rtsp.sh
#
# PURPOSE:
#   Launch a minimal unauthenticated RTSP H.264 stream on port 8554 (configurable)
#   using gst-rtsp-launch and environment values prepared by prep.sh (.env file).
#
# RATIONALE:
#   - Keep proof-of-concept to TWO scripts with all docs inline.
#   - Avoid Python RTSP libs / GI dependencies; rely on battle‑tested GStreamer tool.
#   - Provide adjustable resolution, framerate, bitrate, and GOP size.
#
# USAGE:
#   sh scripts/run_rtsp.sh             # uses ./.env produced by prep.sh
#   FRAMERATE=25 WIDTH=640 HEIGHT=480 sh scripts/run_rtsp.sh   # ad-hoc override
#
# STOPPING:
#   Ctrl+C to terminate. Script traps INT/TERM and cleans child process.
#
# OUTPUT:
#   - Logs pipeline, restarts not attempted (simplicity). If the process exits
#     unexpectedly a non-zero exit code is returned.
#
# SECURITY:
#   - No authentication, encryption, or access control. Keep network restricted.
#
# DEPENDENCIES:
#   - gst-rtsp-launch (from gst-rtsp-server package or similar)
#   - v4l2 camera device
#
###############################################################################
set -eu

# Load .env if present
if [ -f .env ]; then
  # shellcheck disable=SC1091
  . ./.env
fi

DEVICE="${DEVICE:-/dev/video0}"
PORT="${PORT:-8554}"
FRAMERATE="${FRAMERATE:-30}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
BITRATE_KBPS="${BITRATE_KBPS:-2000}"
KEY_INT="${KEY_INT:-30}"  # if .env absent, fallback ~1s at 30fps

GST_RTSP_LAUNCH=$(command -v gst-rtsp-launch || true)
if [ -z "$GST_RTSP_LAUNCH" ]; then
  echo "[ERROR] gst-rtsp-launch not found. Run prep.sh or install GStreamer RTSP helper." >&2
  exit 1
fi

PIPELINE="( v4l2src device=$DEVICE ! video/x-raw,width=$WIDTH,height=$HEIGHT,framerate=$FRAMERATE/1 ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast bitrate=$BITRATE_KBPS key-int-max=$KEY_INT ! rtph264pay name=pay0 pt=96 config-interval=1 )"

echo "[INFO] Starting RTSP server on rtsp://0.0.0.0:$PORT/stream"
# Show final parameters
cat <<EOP
[INFO] Parameters:
  DEVICE=$DEVICE
  RES=${WIDTH}x${HEIGHT}
  FPS=$FRAMERATE
  BITRATE_KBPS=$BITRATE_KBPS
  KEY_INT=$KEY_INT
  PIPELINE=$PIPELINE
EOP

# Trap for clean termination
child_pid=""
cleanup() {
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    echo "[INFO] Stopping RTSP server (PID $child_pid)";
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
}
trap cleanup INT TERM EXIT

# Exec gst-rtsp-launch in background to allow trap to run
# Using --gst-plugin-spew can help debugging if needed.
$GST_RTSP_LAUNCH -p "$PORT" "$PIPELINE" &
child_pid=$!
echo "[INFO] gst-rtsp-launch PID: $child_pid"

# Wait on child
wait "$child_pid"
exit_code=$?
if [ "$exit_code" -ne 0 ]; then
  echo "[ERROR] RTSP process exited with code $exit_code" >&2
fi
exit "$exit_code"

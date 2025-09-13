#!/usr/bin/env sh
set -eu

# Simple unauthenticated RTSP server on port 8554 using ffmpeg + rtsp-simple-server (MediaMTX)
# Requirements (auto-installed if missing): curl, tar, ffmpeg (with v4l2), mediaMTX binary
# Stream name: webcam
# Resulting RTSP URL: rtsp://0.0.0.0:8554/webcam

BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BIN_DIR="$BASE_DIR/bin"
MTX_VERSION="${MTX_VERSION:-v1.14.0}" # can set MTX_VERSION=latest to auto
MTX_BIN="$BIN_DIR/mediamtx"

VERBOSE="${VERBOSE:-0}"  # 0=minimal, 1=verbose
LOG_FILE="${LOG_FILE:-}" # set to path to capture ffmpeg output; empty = discard

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    return 1
  fi
}

# Args: --noreap (skip cleanup) --health (force health probe) --nohealth (disable) --reap (legacy) --help
SKIP_REAP=0
DO_HEALTH=1 # default enabled now
for arg in "$@"; do
  case "$arg" in
    --noreap) SKIP_REAP=1 ;;
    --reap) ;; # legacy no-op
    --health|--health-check) DO_HEALTH=1 ;;
    --nohealth) DO_HEALTH=0 ;;
    -h|--help)
      echo "Usage: $0 [--noreap] [--nohealth]"; exit 0 ;;
  esac
done

# Ensure argument parsing variables exist early
SKIP_REAP=${SKIP_REAP:-0}
DO_HEALTH=${DO_HEALTH:-0}

# Robust cleanup of prior processes before anything else
FORCE_KILL="${FORCE_KILL:-1}"
RTSP_PORT=8554
STREAM_NAME="${STREAM_NAME:-stream}"
RTSP_URL="rtsp://127.0.0.1:${RTSP_PORT}/$STREAM_NAME"

proc_kill_port() {
  PORT="$1"
  # Scan /proc for sockets referencing :PORT (limited approach using ss absence)
  if command -v grep >/dev/null 2>&1; then
    for pid in $(ls /proc | grep -E '^[0-9]+$'); do
      cmdline="/proc/$pid/cmdline"
      if [ -r "$cmdline" ]; then
        if tr '\0' ' ' < "$cmdline" | grep -q ":$PORT"; then
          kill "$pid" 2>/dev/null || true
        fi
      fi
    done
  fi
}

kill_conflicts() {
  # Initial pattern-based kills
  pkill -f 'ffmpeg .*list_formats' 2>/dev/null || true
  pkill -f 'ffmpeg .*rtsp://127.0.0.1:' 2>/dev/null || true
  pkill -x mediamtx 2>/dev/null || true
  pkill -f '/mediamtx ' 2>/dev/null || true
  proc_kill_port "$RTSP_PORT"
  if command -v fuser >/dev/null 2>&1; then
    fuser -k ${RTSP_PORT}/tcp 2>/dev/null || true
  fi
  # Corrected awk usage
  PIDS=$(ps -eo pid,cmd | awk '($2 ~ /mediamtx/ || $2 ~ /ffmpeg/) {print $1}' 2>/dev/null | grep -v "^$$" || true)
  if [ -n "${PIDS:-}" ]; then
    echo "Terminating lingering processes: $PIDS" >&2
    kill $PIDS 2>/dev/null || true
    sleep 0.5
    # Re-check
    SURV=$(echo "$PIDS" | while read -r p; do [ -d "/proc/$p" ] && echo $p; done)
    if [ -n "${SURV:-}" ]; then
      echo "Force killing stubborn PIDs: $SURV" >&2
      kill -9 $SURV 2>/dev/null || true
    fi
  fi
}

wait_port_free() {
  # Wait until port no longer accepts connections (meaning listener gone)
  for i in $(seq 1 20); do
    if (echo >/dev/tcp/127.0.0.1/${RTSP_PORT}) 2>/dev/null; then
      # still listening
      sleep 0.25
    else
      return 0
    fi
  done
  echo "Port ${RTSP_PORT} still busy after waiting." >&2
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:${RTSP_PORT} -sTCP:LISTEN || true
  elif command -v fuser >/dev/null 2>&1; then
    fuser -v ${RTSP_PORT}/tcp || true
  else
    echo "(Install lsof or psmisc for better diagnostics)" >&2
  fi
  exit 1
}

# Dynamic port fallback function (if UDP RTP ports busy under --noreap)
choose_rtp_ports() {
  # If skipping reap and previous ports busy, pick alternative pair (increment)
  if [ $SKIP_REAP -eq 1 ]; then
    BASE=8002
    for offset in 0 2 4 6 8 10 12; do
      CAND_RTP=$((BASE+offset))
      CAND_RTCP=$((BASE+offset+1))
      if ! (echo >/dev/tcp/127.0.0.1/${RTSP_PORT}) 2>/dev/null; then
        # RTSP port unaffected here; check if these UDP ports appear in /proc (best effort)
        if ! grep -qa ":$(printf '%04X' $CAND_RTP)" /proc/net/udp 2>/dev/null; then
          RTP_PORT=$CAND_RTP
          RTCP_PORT=$CAND_RTCP
          return 0
        fi
      fi
    done
  fi
  RTP_PORT=8002
  RTCP_PORT=8003
}

# (Delay conflict cleanup until after arg parsing)
# Remove earlier unconditional kill_conflicts and wait_port_free calls if present below.

# Ensure kill_conflicts and wait_port_free defined above their first use.
# After definitions, perform cleanup:
# --- CLEANUP START ---
# Default: perform cleanup unless --noreap passed
if [ $SKIP_REAP -eq 0 ]; then
  kill_conflicts
  wait_port_free
else
  echo "(Skipping reap due to --noreap)" >&2
fi
# --- CLEANUP END ---

download_mtx() {
  if [ -x "$MTX_BIN" ]; then
    return 0
  fi
  if [ "$MTX_VERSION" = "latest" ]; then
    echo "Resolving latest MediaMTX version..." >&2
    MTX_VERSION=$(curl -sL https://api.github.com/repos/bluenviron/mediamtx/releases/latest | awk -F '"' '/tag_name/ {print $4}' )
  fi
  VER_TRIM=$(echo "$MTX_VERSION" | sed 's/^v//')
  echo "Downloading MediaMTX $MTX_VERSION ..." >&2
  archive="mediamtx_${MTX_VERSION}_linux_amd64.tar.gz"
  # Some releases use mediamtx_v<ver> pattern; ensure both tried
  url1="https://github.com/bluenviron/mediamtx/releases/download/${MTX_VERSION}/mediamtx_${MTX_VERSION}_linux_amd64.tar.gz"
  url2="https://github.com/bluenviron/mediamtx/releases/download/${MTX_VERSION}/mediamtx_v${VER_TRIM}_linux_amd64.tar.gz"
  if ! curl -fL "$url1" -o "$BIN_DIR/$archive"; then
    echo "Primary URL failed, trying alternate naming..." >&2
    if ! curl -fL "$url2" -o "$BIN_DIR/$archive"; then
      echo "Failed to download MediaMTX archive." >&2
      exit 1
    fi
  fi
  tar -xzf "$BIN_DIR/$archive" -C "$BIN_DIR" mediamtx || { echo "Extract failed" >&2; exit 1; }
  rm "$BIN_DIR/$archive"
  chmod +x "$MTX_BIN"
}

# Check basic deps
for dep in curl tar; do
  if ! need "$dep"; then
    echo "Please install $dep" >&2
    exit 1
  fi
 done

# ffmpeg may not be present - try install via apt if available
if ! command -v ffmpeg >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    echo "Installing ffmpeg via apt-get (sudo required) ..." >&2
    sudo apt-get update && sudo apt-get install -y ffmpeg
  else
    echo "ffmpeg not found. Please install ffmpeg manually." >&2
    exit 1
  fi
fi

download_mtx

# Detect first video device
VIDEO_DEV="${VIDEO_DEV:-}";
if [ -z "$VIDEO_DEV" ]; then
  VIDEO_DEV=$(ls /dev/video* 2>/dev/null | head -n1 || true)
fi
if [ -z "$VIDEO_DEV" ]; then
  echo "No /dev/video* device found. Plug in a webcam or set VIDEO_DEV explicitly." >&2
  exit 1
fi

echo "Using video device: $VIDEO_DEV" >&2

# Video mode env: VIDEO_MODE="<WIDTH>x<HEIGHT>@<FPS>" e.g. 640x480@30 (default 1280x720@25)
VIDEO_MODE="${VIDEO_MODE:-1280x720@25}"
if echo "$VIDEO_MODE" | grep -q '@'; then
  RES_PART=${VIDEO_MODE%@*}
  FPS_PART=${VIDEO_MODE##*@}
else
  RES_PART=$VIDEO_MODE
  FPS_PART=25
fi
# Validate
if ! echo "$RES_PART" | grep -Eq '^[0-9]+x[0-9]+$'; then
  echo "Invalid resolution in VIDEO_MODE: $RES_PART" >&2; exit 1; fi
if ! echo "$FPS_PART" | grep -Eq '^[0-9]+$'; then
  echo "Invalid FPS in VIDEO_MODE: $FPS_PART" >&2; exit 1; fi
VIDEO_RES="$RES_PART"
VIDEO_FPS="$FPS_PART"
echo "Selected mode: ${VIDEO_RES}@${VIDEO_FPS}fps" >&2

# Create a minimal mediamtx config (no auth, listen 8554)
MTX_CONFIG="$BIN_DIR/mediamtx-webcam.yml"
choose_rtp_ports
cat > "$MTX_CONFIG" <<EOF
paths:
  all:
    source: publisher
rtspAddress: :${RTSP_PORT}
rtpAddress: :${RTP_PORT}
rtcpAddress: :${RTCP_PORT}
EOF

# Start MediaMTX in background
# Newer MediaMTX takes config file as positional argument (no --config flag)
"$MTX_BIN" "$MTX_CONFIG" &
MTX_PID=$!
trap 'kill $MTX_PID 2>/dev/null || true' EXIT INT TERM

# Give server a moment
sleep 1

# Start pushing the webcam via ffmpeg as MJPEG (try native mjpeg fallback)
# Adjust -r (fps) and -video_size as needed.

# Replace earlier H264 capability probe with a quicker check using v4l2-ctl if available to avoid blocking ffmpeg
if command -v v4l2-ctl >/dev/null 2>&1; then
  if v4l2-ctl --device="$VIDEO_DEV" --list-formats 2>/dev/null | grep -qi mjpeg; then
    INPUT_FMT_ARGS="-f v4l2 -input_format mjpeg"
    ENCODE_ARGS="-c copy"
    SELECTED_ENCODER="mjpeg (native)"
  else
    INPUT_FMT_ARGS="-f v4l2"
    # Select best available encoder: mjpeg > libx264 > libopenh264 > mpeg4
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q '\bmjpeg\b'; then
      SELECTED_ENCODER="mjpeg (software)"
      ENCODE_ARGS="-c:v mjpeg -q:v 5"
    elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -q '\blibx264\b'; then
      SELECTED_ENCODER="libx264"
      ENCODE_ARGS="-c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -pix_fmt yuv420p -b:v 1500k"
    elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -q '\blibopenh264\b'; then
      SELECTED_ENCODER="libopenh264"
      ENCODE_ARGS="-c:v libopenh264 -pix_fmt yuv420p -b:v 1500k"
    elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -q '\bmpeg4\b'; then
      SELECTED_ENCODER="mpeg4"
      ENCODE_ARGS="-c:v mpeg4 -pix_fmt yuv420p -q:v 5"
    else
      echo "No suitable MJPEG/H264/MPEG4 encoder found in this ffmpeg build. Aborting." >&2
      exit 1
    fi
    echo "Using encoder: $SELECTED_ENCODER" >&2
  fi
fi

# If ENCODE_ARGS still unset, perform encoder selection (ffmpeg -list_formats was removed to avoid blocking)
if [ -z "${ENCODE_ARGS:-}" ]; then
  INPUT_FMT_ARGS="-f v4l2"
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q '\bmjpeg\b'; then
    SELECTED_ENCODER="mjpeg (software)"
    ENCODE_ARGS="-c:v mjpeg -q:v 5"
  elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -q '\blibx264\b'; then
    SELECTED_ENCODER="libx264"
    ENCODE_ARGS="-c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -pix_fmt yuv420p -b:v 1500k"
  elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -q '\blibopenh264\b'; then
    SELECTED_ENCODER="libopenh264"
    ENCODE_ARGS="-c:v libopenh264 -pix_fmt yuv420p -b:v 1500k"
  elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -q '\bmpeg4\b'; then
    SELECTED_ENCODER="mpeg4"
    ENCODE_ARGS="-c:v mpeg4 -pix_fmt yuv420p -q:v 5"
  else
    echo "No suitable encoder found." >&2
    exit 1
  fi
  echo "Using encoder: $SELECTED_ENCODER" >&2
fi

# Audio (optional): if you have a mic at hw:0,0 add: -f alsa -i hw:0 -c:a aac -b:a 128k
# For simplicity we stream video only.

# Quick server readiness probe (wait until port 8554 accepts connections)
for i in 1 2 3 4 5 6 7 8 9 10; do
  if (echo > /dev/tcp/127.0.0.1/8554) 2>/dev/null; then
    break
  fi
  sleep 0.3
  [ "$i" = 10 ] && echo "RTSP server did not become ready" >&2
done

# Track ffmpeg PID
FFMPEG_PID=""

health_probe() {
  [ "${DO_HEALTH}" = "1" ] || return 0
  [ "$VERBOSE" = 1 ] && echo "Performing RTSP health probe (OPTIONS)..." >&2 || true
  OK=0
  for i in 1 2 3 4 5; do
    if (echo >/dev/tcp/127.0.0.1/${RTSP_PORT}) 2>/dev/null; then
      { printf 'OPTIONS rtsp://127.0.0.1:%s/%s RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: healthcheck\r\n\r\n' "$RTSP_PORT" "$STREAM_NAME" \
        >/dev/tcp/127.0.0.1/${RTSP_PORT} 2>/dev/null && OK=1 && break; } || true
    fi
    sleep 0.3
  done
  if [ $OK -eq 1 ]; then
    echo "Health probe success." >&2
  elif [ "$VERBOSE" = 1 ]; then
    echo "Health probe inconclusive." >&2
  fi
}

publish_stream() {
  [ "$VERBOSE" = 1 ] && echo "Publishing to $RTSP_URL (device=$VIDEO_DEV encoder=$SELECTED_ENCODER args=$ENCODE_ARGS mode=${VIDEO_RES}@${VIDEO_FPS})" >&2 || echo "Publishing to $RTSP_URL" >&2
  if [ -n "$LOG_FILE" ]; then
    FFMPEG_LOG="$LOG_FILE"
  elif [ "$VERBOSE" = 1 ]; then
    FFMPEG_LOG="$BIN_DIR/ffmpeg-publish.log"
  else
    FFMPEG_LOG="/dev/null"
  fi
  [ "$FFMPEG_LOG" != "/dev/null" ] && : > "$FFMPEG_LOG" || true
  (
    ffmpeg -hide_banner -loglevel $( [ "$VERBOSE" = 1 ] && echo warning || echo error ) \
      $INPUT_FMT_ARGS -framerate "$VIDEO_FPS" -video_size "$VIDEO_RES" -i "$VIDEO_DEV" \
      -an $ENCODE_ARGS -f rtsp -rtsp_transport tcp "$RTSP_URL"
  ) >> "$FFMPEG_LOG" 2>&1 &
  FFMPEG_PID=$!
  sleep 2
  if ! kill -0 $FFMPEG_PID 2>/dev/null; then
    if [ -n "$LOG_FILE" ] || [ "$VERBOSE" = 1 ]; then
      [ -f "$FFMPEG_LOG" ] && sed -n '1,40p' "$FFMPEG_LOG" >&2 || true
    fi
    if grep -qi 'Device or resource busy' "$FFMPEG_LOG" 2>/dev/null && [ $SKIP_REAP -eq 1 ]; then
      echo "Device busy (existing publisher)." >&2
      return 0
    fi
    return 1
  fi
  [ "$VERBOSE" = 1 ] && echo "ffmpeg running (pid=$FFMPEG_PID)" >&2 || true
  start_quit_watcher
  return 0
}

# Update trap later after FFMPEG_PID defined; define a function for graceful shutdown
shutdown_all() {
  echo "Shutting down..." >&2
  [ -n "${FFMPEG_PID:-}" ] && kill $FFMPEG_PID 2>/dev/null || true
  kill $MTX_PID 2>/dev/null || true
  [ -n "${QUIT_WATCH_PID:-}" ] && kill $QUIT_WATCH_PID 2>/dev/null || true
}

# Replace existing trap line with:
trap 'shutdown_all' EXIT INT TERM

# After successful publish (inside publish_stream already calling health_probe) start quit watcher if interactive
start_quit_watcher() {
  [ -t 0 ] || return 0
  ( while read -r line; do
      if [ "$line" = "q" ]; then
        echo "Received 'q' request" >&2
        shutdown_all
        exit 0
      fi
    done ) &
  QUIT_WATCH_PID=$!
  echo "Press 'q' + Enter to quit." >&2
}

# Attempt publish with fallback logic
ATTEMPT=1
MAX_ATTEMPTS=3
FAILED_ENCODERS=""
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
  if publish_stream; then
    echo "Stream started: $RTSP_URL" >&2
    health_probe
    break
  fi
  [ "$VERBOSE" = 1 ] && echo "Publish attempt $ATTEMPT failed." >&2 || true
  FAILED_ENCODERS="$FAILED_ENCODERS $SELECTED_ENCODER"
  # Fallback chain logic
  if echo "$ENCODE_ARGS" | grep -q '\-c copy'; then
    # Device copy failed -> choose software/hw encoder
    if ffmpeg -hide_banner -encoders | grep -q '\blibx264\b'; then
      SELECTED_ENCODER="libx264"
      ENCODE_ARGS="-c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -pix_fmt yuv420p -b:v 1500k"
    elif ffmpeg -hide_banner -encoders | grep -q '\blibopenh264\b'; then
      SELECTED_ENCODER="libopenh264"
      ENCODE_ARGS="-c:v libopenh264 -pix_fmt yuv420p -b:v 1500k"
    elif ffmpeg -hide_banner -encoders | grep -q '\bmpeg4\b'; then
      SELECTED_ENCODER="mpeg4"
      ENCODE_ARGS="-c:v mpeg4 -pix_fmt yuv420p -q:v 5"
    else
      echo "No alternative encoder available." >&2
      break
    fi
  elif [ "$SELECTED_ENCODER" = "libopenh264" ] && ffmpeg -hide_banner -encoders | grep -q '\bmpeg4\b'; then
    SELECTED_ENCODER="mpeg4"
    ENCODE_ARGS="-c:v mpeg4 -pix_fmt yuv420p -q:v 5"
  elif [ "$SELECTED_ENCODER" = "libopenh264" ] && ffmpeg -hide_banner -encoders | grep -q '\blibx264\b'; then
    SELECTED_ENCODER="libx264"
    ENCODE_ARGS="-c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline -pix_fmt yuv420p -b:v 1500k"
  else
    # No more fallbacks
    break
  fi
  echo "Retrying with encoder: $SELECTED_ENCODER" >&2
  ATTEMPT=$((ATTEMPT+1))
  sleep 1
done

if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
  echo "All attempts failed (tried:$FAILED_ENCODERS)." >&2
  exit 1
fi

# Remove final blocking wait on ffmpeg; keep mediamtx wait to hold script open
wait $MTX_PID

#!/usr/bin/env sh
# Purpose: Minimal one-time (or occasional) preparation for the camera RTSP POC.
# This installs required system packages (Debian/Ubuntu style) and tests the camera device.
# Adjust if using a different distro/package manager.
#
# Usage:
#   sh prep.sh              # Installs dependencies & prints detected video devices
#
# Environment (optional):
#   PKG_INSTALL=0           # Skip package installation (just enumerate devices)
#
# After running this successfully, use:  ./run.sh

set -eu

echo "[prep] Starting preparation"

if [ "${PKG_INSTALL:-1}" = "1" ]; then
  echo "[prep] Installing system packages (requires sudo)"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      gstreamer1.0-tools \
      gstreamer1.0-rtsp \
      gstreamer1.0-plugins-base \
      gstreamer1.0-plugins-good \
      v4l-utils
  else
    echo "[prep][warn] apt-get not found. Install GStreamer RTSP server tools and v4l-utils manually." >&2
  fi
else
  echo "[prep] Skipping package installation (PKG_INSTALL=0)"
fi

echo "[prep] Listing video devices"
ls -1 /dev/video* 2>/dev/null || echo "[prep] No /dev/video* devices found"

# Quick capability probe for first device (non-fatal)
FIRST_DEV=$(ls -1 /dev/video* 2>/dev/null | head -n1 || true)
if [ -n "$FIRST_DEV" ]; then
  if command -v v4l2-ctl >/dev/null 2>&1; then
    echo "[prep] Probing $FIRST_DEV capabilities"
    v4l2-ctl -d "$FIRST_DEV" --list-formats-ext || true
  else
    echo "[prep][info] v4l2-ctl not installed (part of v4l-utils)"
  fi
fi

echo "[prep] Done. Run ./run.sh (adjust env vars if needed)."

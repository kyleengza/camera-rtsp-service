# Camera RTSP Service

Modern, modular RTSP streaming daemon for V4L2 / USB cameras using GStreamer (gst-rtsp-server).
Supports H.264 (software x264 + multiple hardware encoders) or MJPEG passthrough, auto device
selection, bitrate heuristics, health & Prometheus metrics endpoints, and systemd integration.

## Key Features
- Auto camera detection & device listing
- H.264 (software x264) or MJPEG passthrough; optional hardware encoders (v4l2h264enc, vaapih264enc, nvh264enc, omxh264enc, qsvh264enc)
- Auto bitrate heuristic (resolution * fps * factor)
- Preflight capture probe with fallback (MJPEG -> raw)
- Layered configuration (defaults < INI < env vars < CLI)
- Health (HTTP) & Prometheus metrics endpoints
- Structured CLI subcommands (`cam-rtsp run …`)
- Systemd unit generation (no large shell scripts)
- JSON config dump, pipeline inspection, dry-run

## TL;DR Quick Start (Development Checkout)
```bash
# 1. System packages (Debian/Ubuntu example)
sudo apt update && sudo apt install -y \
  python3-gi gir1.2-gst-rtsp-server-1.0 \
  gstreamer1.0-tools gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-ugly gstreamer1.0-libav

# 2. Clone & install editable with dev extras
pip install -e .[dev]

# 3. Create config
test -f config.ini || cp config.example.ini config.ini

# 4. Run (verbose + metrics + health)
cam-rtsp run -c config.ini --verbose --metrics-port 9300 --health-port 8080

# Stream URL (default): rtsp://<host>:8554/stream
# Test:
ffplay -rtsp_transport tcp rtsp://localhost:8554/stream
```

## Common Commands
```bash
cam-rtsp list-devices                # enumerate cameras
cam-rtsp preflight -c config.ini     # test capture capability
cam-rtsp print-pipeline -c config.ini
cam-rtsp dump-config -c config.ini | jq
```

## Systemd Deployment (Recommended)
```bash
sudo useradd -r -s /usr/sbin/nologin camera || true
sudo usermod -aG video camera
sudo mkdir -p /opt/camera-rtsp-service && sudo chown camera:camera /opt/camera-rtsp-service
cp config.example.ini config.ini  # adjust if needed
pip install .
sudo cam-rtsp generate-systemd --user camera --prefix /opt/camera-rtsp-service --config /opt/camera-rtsp-service/config.ini
sudo systemctl daemon-reload
sudo systemctl enable --now camera-rtsp.service
```

### Uninstall
```bash
sudo systemctl disable --now camera-rtsp.service
sudo rm /etc/systemd/system/camera-rtsp.service
sudo systemctl daemon-reload
pip uninstall -y camera-rtsp-service
sudo userdel camera  # optional
sudo rm -rf /opt/camera-rtsp-service  # optional
```

## Configuration (INI Example)
```
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
port = 8554
mount_path = /stream
kill_existing = false

[logging]
level = INFO
verbose = false
python_log_file =
# gst_debug_level = 4
# gst_debug_categories = *:4,v4l2:5
# gst_debug_file = gst_debug.log

[health]
health_port = 0
metrics_port = 0
```

## Environment Variable Overrides
Pattern: `CAMRTSP_<SECTION>__<KEY>=value`
```bash
export CAMRTSP_ENCODING__BITRATE_KBPS=5000
export CAMRTSP_RTSP__PORT=9554
```

## Metrics & Health
- Metrics: `--metrics-port 9300` -> `http://<host>:9300/` Prometheus text format
- Health:  `--health-port 8080`  -> `http://<host>:8080/` returns `OK`

## Troubleshooting Cheatsheet
| Symptom | Action |
|---------|--------|
| 400 Bad Request | Confirm mount path & URL; increase GST_DEBUG; run foreground `cam-rtsp run --verbose` |
| not-negotiated | Remove fixed caps (set width/height=0) or disable prefer_raw |
| High latency | Use hardware encoder, lower GOP, ensure TCP transport, or MJPEG passthrough |
| High CPU | Enable hardware encoder; reduce resolution/fps; prefer_raw=true if raw supported |
| Missing x264enc | Install `gstreamer1.0-plugins-ugly` |
| No devices found | Check `v4l2-ctl --list-devices`; permissions (user in `video` group) |

## Full Manual
See `MANUAL.md` for an end‑to‑end installation, architecture, and tuning guide.

## Changelog
Refer to `CHANGELOG.md` (current dev version 0.2.0.dev0).

## License
MIT

## One-Line Headless Install (from checkout)
```bash
sudo bash scripts/install.sh --user camera --prefix /opt/camera-rtsp-service --port 8554
```
Resulting stream: `rtsp://<host>:8554/stream`

## Headless Uninstall
```bash
sudo bash scripts/uninstall.sh --purge --remove-user
```

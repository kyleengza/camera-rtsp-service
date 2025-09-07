# camera-rtsp-service

Lightweight RTSP streamer for USB / V4L2 webcams using GStreamer gst-rtsp-server.
Provides H.264 (software x264, optional hardware encoders) or MJPEG passthrough.
Includes preflight camera check, auto bitrate heuristic, hardware encoder auto-detect,
latency tuning, and detailed logging / GStreamer debug controls.

## Features
- H.264 software (x264) or MJPEG passthrough
- Optional hardware encoder auto-detect (v4l2h264enc, vaapih264enc, nvh264enc, omxh264enc)
- Auto bitrate heuristic with configurable factor
- Preflight camera probe before starting RTSP
- Width/height/framerate optional (0 = let camera pick)
- Prefer raw capture toggle (avoid JPEG decode when raw available)
- Verbose Python + GStreamer debug output to file
- Graceful signal handling for systemd
- systemd unit example

## Quick Start
```
git clone https://github.com/kyleengza/camera-rtsp-service.git
cd camera-rtsp-service
./setup_env.sh USE_SYSTEM_SITE_PACKAGES=true
source .venv/bin/activate
cp config.example.ini config.ini
python src/main.py --config config.ini
```
RTSP URL: `rtsp://<host>:8554/stream`

## CLI Options
```
python src/main.py [--config CONFIG] [--print-pipeline] [--dry-run] [--version]
```
- `--print-pipeline`: Show resolved GStreamer pipeline then exit
- `--dry-run`: Load config, perform preflight & pipeline build, no server start

## Configuration
Copy `config.example.ini` to `config.ini` and adjust.
```
[camera]
preflight = true
device = auto
width = 0
height = 0
framerate = 0
prefer_raw = false             # if true and raw caps available, avoid MJPEG path

[encoding]
codec = auto                   # auto|h264|jpeg
bitrate_kbps = 0               # if 0 and auto_bitrate=true -> heuristic
auto_bitrate = true
auto_bitrate_factor = 0.00007  # width*height*fps*factor
hardware_priority = auto       # auto|off|list e.g. v4l2h264enc,nvh264enc
 gop_size = 60
tune = zerolatency
speed_preset = ultrafast
profile = baseline

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
```

### Codec Selection Logic (auto)
1. If `hardware_priority` is a comma list: first available encoder from list
2. Else if `hardware_priority=auto`: pick first available from predefined list
3. Else fallback to `x264enc` if present
4. Else MJPEG passthrough

### Heuristic Bitrate
`bitrate_kbps = int(width*height*fps*auto_bitrate_factor)` capped & minimum. If resolution/FPS unknown until runtime, default 2000 kbps.

## Pipelines (Examples)
MJPEG passthrough:
```
v4l2src ! image/jpeg ! queue leaky=downstream max-size-buffers=1 ! rtpjpegpay name=pay0 pt=26
```
Software H.264 (MJPEG cam):
```
v4l2src ! image/jpeg ! jpegdec ! videoconvert ! queue ! x264enc ... ! h264parse ! rtph264pay name=pay0 pt=96
```
Hardware example (auto-detected):
```
v4l2src ! video/x-raw,... ! queue ! v4l2h264enc extra-controls=... ! h264parse ! rtph264pay name=pay0 pt=96
```

## Systemd Service
```
sudo cp camera-rtsp.service.example /etc/systemd/system/camera-rtsp-service
sudo systemctl daemon-reload
sudo systemctl enable --now camera-rtsp-service
```
Adjust `User=` to a dedicated service account added to `video` group.

## Troubleshooting
| Issue | Action |
|-------|--------|
| Client can’t connect | Check logs; preflight errors? port blocked? |
| not-negotiated | Set width/height/framerate to 0 or enable prefer_raw=false |
| High CPU | Lower resolution, use hardware encoder, or MJPEG passthrough |
| Missing x264enc | Install ugly plugins or rely on hardware encoder |
| Latency high | Use MJPEG passthrough or tune H.264 (ultrafast, low GOP) |

## Changelog
See `CHANGELOG.md` for release history. Current version: 0.1.0b1

## Development / Git
```
# After cloning
cp config.example.ini config.ini
# Commit changes
# Tag beta
git tag -a v0.1.0-beta.1 -m "Beta 1"
git push --tags
```

## License
MIT

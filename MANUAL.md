# Camera RTSP Service – Detailed Manual

## 1. Overview
The Camera RTSP Service is a lean daemon providing an RTSP endpoint for a V4L2 / USB camera using GStreamer. It emphasizes:
- Minimal moving parts (single process, gst-rtsp-server based)
- Adaptive configuration & environment layering
- Hardware acceleration when present, sensible fallbacks when not
- Operational visibility (health + metrics)

## 2. Architecture
```
+---------------------------+
| cam-rtsp CLI              |
|  (argparse subcommands)   |
+-------------+-------------+
              | build_config()
              v
      +-----------------+         +------------------+
      | Pydantic Config |<--------| INI / Env / CLI  |
      +--------+--------+         +------------------+
               |
               | pipeline.build_pipeline(cfg)
               v
        +--------------+          +---------------------+
        | Pipeline Str |  ----->  | GstRtspServer Mount |
        +------+-------+          +----------+----------+
               |                             |
               v                             v
      +-----------------+           +-----------------------+
      | GStreamer Graph |           | Health / Metrics HTTP |
      +-----------------+           +-----------------------+
```

Major modules:
- `config.py`: layered config -> `AppConfig` (defaults, INI, env, CLI)
- `detect.py`: device listing, auto-select, preflight
- `pipeline.py`: build GStreamer launch string (encoders, bitrate, caps)
- `server.py`: RTSP server wrapper + optional HTTP threads (health & metrics)
- `cli.py`: subcommands and orchestration

## 3. Installation Methods
### 3.1 Development (Editable)
```bash
sudo apt install -y python3-gi gir1.2-gst-rtsp-server-1.0 \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav
pip install -e .[dev]
cp config.example.ini config.ini
cam-rtsp run -c config.ini --verbose
```

### 3.2 Production (Systemd + Single Install Command Set)
```bash
sudo useradd -r -s /usr/sbin/nologin camera || true
sudo usermod -aG video camera
sudo mkdir -p /opt/camera-rtsp-service && sudo chown camera:camera /opt/camera-rtsp-service
cp config.example.ini /opt/camera-rtsp-service/config.ini
pip install camera-rtsp-service  # or pip install . in checkout
sudo cam-rtsp generate-systemd --user camera --prefix /opt/camera-rtsp-service --config /opt/camera-rtsp-service/config.ini
sudo systemctl daemon-reload
sudo systemctl enable --now camera-rtsp.service
```

### 3.3 Uninstall
```bash
sudo systemctl disable --now camera-rtsp.service
sudo rm /etc/systemd/system/camera-rtsp.service
sudo systemctl daemon-reload
pip uninstall -y camera-rtsp-service
sudo userdel camera   # optional
sudo rm -rf /opt/camera-rtsp-service  # optional
```

### 3.4 Minimal Runtime Dependencies
At minimum you need GStreamer core + base/good plugins and whichever encoders you want (ugly/bad for x264, hardware specifics for VAAPI/NVENC etc.).

## 4. Configuration Layering
Precedence (later wins):
1. Built-in defaults
2. INI file values
3. Environment variables (CAMRTSP_<SECTION>__<KEY>)
4. CLI overrides

Inspect effective configuration:
```bash
cam-rtsp dump-config -c config.ini | jq
```

### 4.1 Environment Examples
```bash
export CAMRTSP_CAMERA__DEVICE=/dev/video2
export CAMRTSP_ENCODING__BITRATE_KBPS=4500
export CAMRTSP_HEALTH__METRICS_PORT=9300
```

## 5. Device Handling
`device = auto` attempts detection via GStreamer DeviceMonitor, falling back to scanning `/dev/video*`. Use `cam-rtsp list-devices` to enumerate.

## 6. Preflight
Two-phase if codec=auto or jpeg:
1. MJPEG test (if desired)
2. Raw fallback if MJPEG fails

Output example (preflight subcommand):
```bash
cam-rtsp preflight -c config.ini --device auto
{"ok": true, "reason": "playing", "device": "/dev/video0"}
```

## 7. Bitrate Heuristic
If `bitrate_kbps=0` and `auto_bitrate=true`, compute:
```
bitrate_kbps = width * height * framerate * auto_bitrate_factor
```
Clamped into [300, 25000]. If dimensions unknown -> default 2000.

## 8. Encoder Selection (codec=auto)
Priority:
1. First available encoder from `hardware_priority` list (if not `off`)
2. x264enc (software)
3. MJPEG passthrough

## 9. Health & Metrics
- Health: `http://<host>:<health_port>/` returns `OK` (200) if process alive.
- Metrics (Prometheus): `http://<host>:<metrics_port>/` exposes counters:
  - `rtsp_connections_total`
  - `rtsp_sessions_total`

Add scrape config:
```yaml
- job_name: cam-rtsp
  static_configs:
    - targets: ['cam-host:9300']
```

## 10. Systemd Integration
Generate a unit:
```bash
sudo cam-rtsp generate-systemd --user camera --prefix /opt/camera-rtsp-service --config /opt/camera-rtsp-service/config.ini
sudo systemctl daemon-reload
sudo systemctl enable --now camera-rtsp.service
```
Unit fields:
- `User` / `Group`: service account (must access `/dev/videoX` -> add to `video` group)
- `WorkingDirectory`: prefix directory containing config
- `ExecStart`: invokes CLI run subcommand

### 10.1 Journald Logs
```bash
journalctl -u camera-rtsp.service -f
```

### 10.2 Updating
```bash
pip install --upgrade camera-rtsp-service
sudo systemctl restart camera-rtsp.service
```

## 11. Security Hardening (Optional)
Suggested additions to unit:
```
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
DeviceAllow=/dev/video0 rw
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_UNIX
```
Tune DeviceAllow per camera(s).

## 12. Troubleshooting
| Problem | Likely Cause | Remedy |
|---------|--------------|--------|
| 400 Bad Request | Wrong mount path or no factory mounted | Verify mount, run foreground with `--verbose` |
| not-negotiated | Unsupported caps | Set width/height=0 or adjust framerate |
| High latency | Large GOP / UI pipeline buffering | Lower GOP, choose TCP in client, hardware encoder |
| High CPU | Software x264 at high res | Use hardware encoder or MJPEG passthrough |
| No devices found | Permissions | Add user to `video`, check `ls -l /dev/video*` |
| Missing encoder | Plugin not installed | Install correct GStreamer plugin pack |

## 13. Development
Lint & tests:
```bash
ruff check .
mypy src/camera_rtsp_service
pytest -q
```

## 14. Roadmap
- Optional RTSP Basic/Digest auth
- Snapshot HTTP endpoint (single frame)
- Recording / ring buffer
- More detailed metrics (bitrate, FPS)

## 15. Versioning
Semantic versioning. Dev builds use `.devN`. See `CHANGELOG.md`.

## 16. License
MIT

# Camera RTSP Service

Simple helper to stream a local Linux webcam (/dev/videoX) over RTSP (unauthenticated) on port 8554.

Default stream URL:
```
rtsp://<host>:8554/stream
```

## Quick Start
```sh
sh scripts/run-rtsp.sh
```
Test playback:
```sh
ffplay -rtsp_transport tcp rtsp://localhost:8554/stream
```

## Features
- Auto‑download and run MediaMTX (successor to rtsp-simple-server)
- Auto device detection (`/dev/video*`)
- Encoder auto-selection (native MJPEG → software MJPEG → libx264/libopenh264 → mpeg4)
- Adjustable resolution & FPS via `VIDEO_MODE` (e.g. `640x480@30`)
- Aggressive cleanup / reap mode
- Retry & fallback logic
- Optional RTSP health probe

## Script Flags
- `--noreap` : skip automatic cleanup (default run reaps)
- `--nohealth` : disable default RTSP OPTIONS health probe
- `--health` : (forced, default already on) run health probe
- (`--reap` legacy no-op)

## Interactive Quit
While running in a terminal, press `q` then Enter to gracefully stop ffmpeg and MediaMTX.

## Environment Variables
- `VIDEO_DEV` : force video device (`/dev/video2` etc.)
- `STREAM_NAME` : path component (default `stream`)
- `MTX_VERSION` : pin or set `latest`
- `VIDEO_MODE` : `<WIDTH>x<HEIGHT>@<FPS>` (default `1280x720@25`)

Example custom mode:
```sh
VIDEO_MODE=640x480@30 sh scripts/run-rtsp.sh
```

## What the script does
1. Cleans lingering processes on port 8554.
2. Waits for free port.
3. Ensures deps.
4. Downloads MediaMTX if needed.
5. Generates minimal config.
6. Starts MediaMTX.
7. Chooses encoder & starts ffmpeg in background.
8. (Optional) health probe.

## Troubleshooting
- Change mode: `VIDEO_MODE=1920x1080@15`
- Lower bitrate: edit `-b:v` in script.
- Connection issues: use `--reap` then restart.

## Security
No auth; visible to network peers.

## License
MIT

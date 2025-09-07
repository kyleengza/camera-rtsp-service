# Changelog

## v0.1.0-beta.2 (2025-09-07)
- Added uninstaller script
- Added device listing (--list-devices)
- Preflight MJPEG->raw fallback
- Removed placeholder files (gi, os, socket, subprocess, sys, threading, time)
- Documentation updates (uninstall, devices)

## v0.1.0-beta.1 (2025-09-07)
- Initial public beta
- RTSP streaming with MJPEG passthrough or H.264 (software or hardware auto-detect)
- Auto bitrate heuristic + configurable factor
- Preflight capture validation
- Camera auto-detection (device=auto)
- Hardware encoder priority selection
- CLI: --print-pipeline, --dry-run, --version
- Systemd installer script with venv setup & diagnostics
- Detailed logging + GST_DEBUG integration

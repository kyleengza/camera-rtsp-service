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

## [0.2.0.dev0] - 2025-09-07
### Added
- Modular package refactor (`camera_rtsp_service`) with structured config & CLI subcommands.
- Pydantic-based configuration layering and JSON dump.
- Health and Prometheus metrics endpoints.
- Systemd unit generation CLI command.
- Tests (config layering, pipeline, detection) and dev dependencies (ruff, mypy, pytest).
- Logging centralization with GST debug integration.

### Changed
- Previous monolithic `src/main.py` replaced by package entry `cam-rtsp run`.

### Deprecated
- Legacy shell scripts (install_service.sh, uninstall_service.sh, setup_env.sh) – to be removed next release.

## [0.2.0-beta.1] - 2025-09-07
### Added
- First beta of modular architecture (promotion from dev0).
- CI workflow (lint, type check, tests).
- INSTALL.md and MANUAL.md detailed docs.
- Headless installer `scripts/install.sh` and uninstaller `scripts/uninstall.sh`.

### Changed
- Refined README with single install/uninstall flow.

### Removed
- Legacy scripts fully removed (install_service.sh, uninstall_service.sh, setup_env.sh).

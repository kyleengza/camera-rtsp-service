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

## [0.2.0-beta.2] - 2025-09-07
### Added
- Manjaro/Arch support in headless installer (pacman dependency installation).
### Changed
- Installer now defaults to virtualenv on Arch/Manjaro to satisfy PEP 668; `--system` bypasses.
### Added
- Installer flags: --upgrade, enforced venv by default.

## [0.2.0-beta.3] - 2025-09-07
### Added
- Installer: automatic PyGObject (gi) fallback build (pycairo + PyGObject) on Arch if system python-gobject not importable (Python version mismatch).
- Installer: local source fallback when index package unavailable in non-editable mode.
### Changed
- Installer: logs clearer when editable install auto-disabled.
### Fixed
- Hardware encoder pipeline: detect supported bitrate property (bitrate vs target-bitrate) to avoid parse errors (e.g. nvh264enc).
- RTSP factory configure TypeError suppressed (GI quirk) by removing base call.

## 0.3.0 - 2025-09-07
### Added
- Per-file Ruff ignores for GI import ordering (keeps functional GI initialization pattern).
- Version bump to stable 0.3.0.

### Changed
- Ruff configuration migrated to new [tool.ruff.lint] table.
- Legacy monolithic files explicitly excluded via in-file `ruff: noqa` markers (kept only for reference).

### Fixed
- Lint baseline now clean (all checks passing).

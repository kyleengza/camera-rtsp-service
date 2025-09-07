"""Command line interface entry point."""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys

from . import __version__
from .config import build_config
from .detect import auto_select, list_devices, preflight
from .logging_setup import configure_gst_debug, configure_logging
from .pipeline import build_pipeline
from .server import RtspServer


def _add_common_args(p: argparse.ArgumentParser):
    p.add_argument('-c','--config', default='config.ini', help='Path to INI config file')
    p.add_argument('--device', help='Override camera.device')
    p.add_argument('--width', type=int)
    p.add_argument('--height', type=int)
    p.add_argument('--framerate', type=int)
    p.add_argument('--codec')
    p.add_argument('--bitrate-kbps', type=int)
    p.add_argument('--no-preflight', action='store_true')
    p.add_argument('--mount-path')
    p.add_argument('--port', type=int)
    p.add_argument('--health-port', type=int)
    p.add_argument('--metrics-port', type=int)
    p.add_argument('--log-file')
    p.add_argument('--verbose', action='store_true')
    p.add_argument('--gst-debug')
    p.add_argument('--gst-debug-file')


def _collect_cli_overrides(args) -> dict:
    ov: dict[str, dict] = {}
    def put(section, key, value):
        if value is None:
            return
        ov.setdefault(section, {})[key] = value
    put('camera','device', args.device)
    put('camera','width', args.width)
    put('camera','height', args.height)
    put('camera','framerate', args.framerate)
    if args.no_preflight:
        put('camera','preflight', False)
    put('encoding','codec', args.codec)
    put('encoding','bitrate_kbps', args.bitrate_kbps)
    put('rtsp','mount_path', args.mount_path)
    put('rtsp','port', args.port)
    put('health','health_port', args.health_port)
    put('health','metrics_port', args.metrics_port)
    put('logging','python_log_file', args.log_file)
    if args.verbose:
        put('logging','verbose', True)
    if args.gst_debug:
        # support direct categories or numeric
        if args.gst_debug.isdigit():
            put('logging','gst_debug_level', int(args.gst_debug))
        else:
            put('logging','gst_debug_categories', args.gst_debug)
    if args.gst_debug_file:
        put('logging','gst_debug_file', args.gst_debug_file)
    return ov


def cmd_run(args):
    cfg = build_config(args.config, _collect_cli_overrides(args))
    configure_logging(cfg)
    configure_gst_debug(cfg)
    import gi
    gi.require_version('Gst','1.0')
    from gi.repository import Gst  # type: ignore
    Gst.init(None)

    # Auto device
    cfg.camera.device = auto_select(cfg.camera.device)

    # Preflight
    if cfg.camera.preflight:
        use_mjpeg = (cfg.encoding.codec in {'jpeg','auto'})
        ok, reason = preflight(cfg.camera.device, use_mjpeg, cfg.camera.width, cfg.camera.height, cfg.camera.framerate)
        if not ok and use_mjpeg:
            logging.warning('MJPEG preflight failed (%s); retry raw fallback', reason)
            ok2, reason2 = preflight(cfg.camera.device, False, cfg.camera.width, cfg.camera.height, cfg.camera.framerate)
            if not ok2:
                logging.error('Preflight failed (raw fallback %s); aborting', reason2)
                return 2
            else:
                logging.info('Raw fallback preflight ok (%s)', reason2)
        elif not ok:
            logging.error('Preflight failed (%s); aborting', reason)
            return 2

    pipeline = build_pipeline(cfg)
    if args.print_pipeline:
        print(pipeline)
        return 0

    if args.dry_run:
        logging.info('Dry run complete')
        return 0

    srv = RtspServer(cfg.rtsp.port, cfg.rtsp.mount_path, pipeline, cfg.health.health_port, cfg.health.metrics_port)

    import signal
    def _sig(_s, _f):
        logging.info('Signal received; shutting down')
        srv.stop()
    for s in (signal.SIGINT, signal.SIGTERM):
        signal.signal(s, _sig)

    srv.start()
    return 0


def cmd_list_devices(_args):
    for path, name in list_devices():
        print(f"{path}\t{name}")
    return 0

def cmd_print_pipeline(args):
    args.print_pipeline = True
    args.dry_run = True
    return cmd_run(args)


def cmd_preflight(args):
    cfg = build_config(args.config, _collect_cli_overrides(args))
    configure_logging(cfg)
    cfg.camera.device = auto_select(cfg.camera.device)
    use_mjpeg = (cfg.encoding.codec in {'jpeg','auto'})
    ok, reason = preflight(cfg.camera.device, use_mjpeg, cfg.camera.width, cfg.camera.height, cfg.camera.framerate)
    print(json.dumps({'ok': ok, 'reason': reason, 'device': cfg.camera.device}))
    if ok:
        return 0
    if use_mjpeg:
        ok2, reason2 = preflight(cfg.camera.device, False, cfg.camera.width, cfg.camera.height, cfg.camera.framerate)
        print(json.dumps({'ok_raw': ok2, 'reason_raw': reason2}))
        return 0 if ok2 else 2
    return 2


def cmd_dump_config(args):
    cfg = build_config(args.config, _collect_cli_overrides(args))
    print(cfg.json_compact())
    return 0

_SYSTEMD_TEMPLATE = """[Unit]
Description=Camera RTSP Service
After=network.target

[Service]
Type=simple
User={user}
Group={user}
WorkingDirectory={prefix}
Environment=PYTHONUNBUFFERED=1
ExecStart={python} -m camera_rtsp_service.cli run -c {config}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
"""

def cmd_generate_systemd(args):
    # Determine python path
    python = sys.executable
    prefix = args.prefix
    os.makedirs(prefix, exist_ok=True)
    config_path = args.config or f"{prefix}/config.ini"
    unit_text = _SYSTEMD_TEMPLATE.format(user=args.user, prefix=prefix, python=python, config=config_path)
    unit_file = args.unit_file or f"/etc/systemd/system/{args.unit_name}.service"
    with open(unit_file, 'w') as f:
        f.write(unit_text)
    print(f"Wrote unit {unit_file}")
    print("Enable with: systemctl daemon-reload && systemctl enable --now " + args.unit_name + '.service')
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog='cam-rtsp', description='Camera RTSP Service')
    p.add_argument('--version', action='store_true', help='Show version and exit')
    sub = p.add_subparsers(dest='cmd')

    # run
    run_p = sub.add_parser('run', help='Run streaming service')
    _add_common_args(run_p)
    run_p.add_argument('--print-pipeline', action='store_true')
    run_p.add_argument('--dry-run', action='store_true')
    run_p.set_defaults(func=cmd_run)

    ld_p = sub.add_parser('list-devices', help='List camera devices')
    ld_p.set_defaults(func=cmd_list_devices)

    pp_p = sub.add_parser('print-pipeline', help='Print pipeline and exit')
    _add_common_args(pp_p)
    pp_p.set_defaults(func=cmd_print_pipeline)

    pf_p = sub.add_parser('preflight', help='Run capture preflight test')
    _add_common_args(pf_p)
    pf_p.set_defaults(func=cmd_preflight)

    dc_p = sub.add_parser('dump-config', help='Show effective merged configuration as JSON')
    _add_common_args(dc_p)
    dc_p.set_defaults(func=cmd_dump_config)

    gs_p = sub.add_parser('generate-systemd', help='Generate systemd unit file')
    gs_p.add_argument('--user', required=True)
    gs_p.add_argument('--prefix', required=True, help='Install directory / work dir')
    gs_p.add_argument('--config', help='Config file path (default <prefix>/config.ini)')
    gs_p.add_argument('--unit-name', default='camera-rtsp')
    gs_p.add_argument('--unit-file', help='Explicit unit file output path')
    gs_p.set_defaults(func=cmd_generate_systemd)

    return p


def main(argv: list[str] | None = None):
    if argv is None:
        argv = sys.argv[1:]
    p = build_parser()
    args = p.parse_args(argv)
    if args.version:
        print(__version__)
        return 0
    if not args.cmd:
        # default to run
        args = p.parse_args(['run'] + argv)
    return args.func(args)

if __name__ == '__main__':  # pragma: no cover
    raise SystemExit(main())

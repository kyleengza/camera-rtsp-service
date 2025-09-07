"""Camera RTSP Service

Provides an RTSP endpoint for a V4L2 camera with optional H.264 hardware/software encoding
or MJPEG passthrough. Includes auto bitrate, preflight validation, camera auto-detect,
and basic diagnostics (device listing, preflight fallback).
"""
import sys
import logging
import os
import gi
import threading
import time
import socket
import subprocess
import signal
import argparse
import glob

VERSION = '0.1.0b2'

gi.require_version('Gst', '1.0')
from gi.repository import Gst  # type: ignore
from config_loader import load_config
from rtsp_server import RtspServer

# Simple bitrate heuristic
_DEF_BITRATE_MAP = {
    (640, 480): 1000,
    (800, 600): 1300,
    (1280, 720): 2200,
    (1920, 1080): 4500,
    (2560, 1440): 8000,
}

_HARDWARE_ENCODERS = [
    'v4l2h264enc',  # Raspberry Pi / generic V4L2 mem2mem
    'vaapih264enc', # Intel VAAPI
    'nvh264enc',    # NVIDIA NVENC (some distros gst-plugins-bad)
    'omxh264enc',   # Legacy RPi / Jetson older
    'qsvh264enc',   # Intel QuickSync (GStreamer 1.22+)
]

def _have_element(name: str) -> bool:
    factory = Gst.ElementFactory.find(name)
    return factory is not None

def _auto_bitrate(width: int | None, height: int | None, fps: int | None) -> int:
    if width and height and (width, height) in _DEF_BITRATE_MAP:
        base = _DEF_BITRATE_MAP[(width, height)]
    elif width and height and fps:
        base = int(width * height * fps * 0.00007)
    else:
        return 2000
    if fps and fps > 30:
        base = int(base * (fps / 30.0) * 0.9)
    return max(300, min(base, 25000))

_stats_stop = False

def _periodic_stats(pipeline_desc: str):
    while not _stats_stop:
        logging.debug('Pipeline active: %s', pipeline_desc)
        time.sleep(15)

def _preflight(device: str, use_mjpeg: bool, width: int, height: int, framerate: int) -> bool:
    caps_parts = []
    if width > 0 and height > 0:
        caps_parts.append(f"width={width},height={height}")
    if framerate > 0:
        caps_parts.append(f"framerate={framerate}/1")
    base_caps = ("image/jpeg" if use_mjpeg else "video/x-raw") + ("," + ",".join(caps_parts) if caps_parts else "")
    test_pipeline_desc = f"v4l2src device={device} ! {base_caps} ! fakesink name=sink sync=false"
    logging.info("Preflight pipeline: %s", test_pipeline_desc)
    pipeline = Gst.parse_launch(test_pipeline_desc)
    bus = pipeline.get_bus()
    pipeline.set_state(Gst.State.PLAYING)
    ok = False
    start = time.time()
    while True:
        msg = bus.timed_pop_filtered(2_000_000_000, Gst.MessageType.ANY)
        if msg:
            t = msg.type
            if t == Gst.MessageType.ERROR:
                err, dbg = msg.parse_error()
                logging.error("Preflight error: %s (%s)", err.message, dbg)
                break
            if t == Gst.MessageType.EOS:
                ok = True
                break
            if t == Gst.MessageType.STATE_CHANGED and msg.src == pipeline:
                new_state = msg.parse_state_changed()[1]
                if new_state == Gst.State.PLAYING:
                    ok = True
                    break
        if time.time() - start > 5:
            ok = True  # assume success if no errors in 5s
            break
    pipeline.set_state(Gst.State.NULL)
    logging.info("Preflight result: %s", "OK" if ok else "FAIL")
    return ok

def _select_hardware_encoder(priority_cfg: str) -> tuple[str | None, dict]:
    """Return (encoder_name, extra_props_dict). priority_cfg can be:
    - 'off' -> (None,{})
    - 'auto' -> first available from _HARDWARE_ENCODERS
    - comma list -> first available from that ordered list.
    Some encoders require extra tuning properties (kept minimal)."""
    priority_cfg = (priority_cfg or 'auto').strip().lower()
    if priority_cfg == 'off':
        return None, {}
    candidates = []
    if priority_cfg == 'auto':
        candidates = _HARDWARE_ENCODERS
    else:
        candidates = [c.strip() for c in priority_cfg.split(',') if c.strip()]
    for enc in candidates:
        if _have_element(enc):
            props: dict = {}
            # Minimal latency / bitrate knobs (bitrate set later via string formatting)
            if enc == 'v4l2h264enc':
                # bitrate is in bits via extra-controls or property (varies by kernel); leave generic
                props['insert-sps-pps'] = 'true'
            elif enc == 'vaapih264enc':
                props['rate-control'] = 'cbr'
            elif enc == 'nvh264enc':
                props['preset'] = 'low-latency-hq'
            elif enc == 'omxh264enc':
                pass
            elif enc == 'qsvh264enc':
                props['rate-control'] = 'cbr'
            return enc, props
    return None, {}

def build_pipeline(cfg) -> str:
    cam = cfg["camera"]
    enc = cfg["encoding"]
    device = cam.get("device", "/dev/video0")
    width = cam.getint("width", 0)
    height = cam.getint("height", 0)
    framerate = cam.getint("framerate", 0)
    prefer_raw = cam.getboolean('prefer_raw', fallback=False)
    codec = enc.get("codec", "auto").lower()

    # Build optional source caps (only set what user specifies >0)
    caps_parts = []
    if width > 0 and height > 0:
        caps_parts.append(f"width={width},height={height}")
    if framerate > 0:
        caps_parts.append(f"framerate={framerate}/1")
    raw_caps = "video/x-raw" + ("," + ",".join(caps_parts) if caps_parts else "")
    mjpg_caps = "image/jpeg" + ("," + ",".join(caps_parts) if caps_parts else "")

    have_x264 = _have_element('x264enc')

    hw_priority = enc.get('hardware_priority', 'auto')
    hw_encoder, hw_props = _select_hardware_encoder(hw_priority) if codec in ('auto','h264') else (None, {})
    using_hw = hw_encoder is not None

    # Decide final path
    use_h264 = False
    use_mjpeg_passthrough = False

    if codec == 'h264':
        use_h264 = True
    elif codec == 'jpeg':
        use_mjpeg_passthrough = True
    else:  # auto
        if using_hw:
            use_h264 = True
        elif have_x264:
            use_h264 = True
        else:
            use_mjpeg_passthrough = True
            logging.warning("No H.264 encoder found; using MJPEG passthrough")

    if use_mjpeg_passthrough:
        pipeline = f"v4l2src device={device} ! {mjpg_caps} ! queue leaky=downstream max-size-buffers=1 ! rtpjpegpay name=pay0 pt=26"
        logging.info("Using MJPEG passthrough pipeline: %s", pipeline)
        return pipeline

    # H.264 path
    source_caps = raw_caps if prefer_raw else mjpg_caps
    decode_chain = "" if prefer_raw else "jpegdec ! videoconvert ! "
    source_chain = (
        f"v4l2src device={device} ! {source_caps} ! {decode_chain}queue leaky=downstream max-size-buffers=1 ! "
    )

    bitrate = enc.getint("bitrate_kbps", 0)
    auto_bitrate_flag = enc.getboolean("auto_bitrate", fallback=False)
    factor = enc.getfloat('auto_bitrate_factor', fallback=0.00007)
    if (bitrate == 0 and auto_bitrate_flag) or (bitrate == 0 and width and height and framerate):
        if width and height and framerate:
            bitrate = int(width * height * framerate * factor)
        else:
            bitrate = 2000
        logging.info("Auto bitrate: %d kbps (factor=%s)", bitrate, factor)
    if bitrate == 0:
        bitrate = 2000

    gop = enc.getint("gop_size", 60)
    tune = enc.get("tune", "zerolatency")
    speed = enc.get("speed_preset", "ultrafast")
    profile = enc.get("profile", "baseline")
    if profile not in {"baseline", "main", "high"}:
        profile = "baseline"

    if using_hw and hw_encoder:
        # Build hardware encoder properties
        prop_str_parts = []
        for k, v in hw_props.items():
            prop_str_parts.append(f"{k}={v}")
        # Generic bitrate property names differ; we try common ones
        # Many hw encoders use 'bitrate' (kbps) or 'target-bitrate' (bps)
        if _have_element(hw_encoder):
            # Provide both where harmless; unknown props ignored silently
            prop_str_parts.append(f"bitrate={bitrate}")
            prop_str_parts.append(f"target-bitrate={bitrate*1000}")
        prop_str = " ".join(prop_str_parts)
        enc_block = f"{hw_encoder} {prop_str} ! h264parse config-interval=1 disable-passthrough=true ! rtph264pay name=pay0 pt=96 config-interval=1"
        pipeline = source_chain + enc_block
        logging.info("Using hardware encoder %s pipeline: %s", hw_encoder, pipeline)
        return pipeline

    # Software x264
    pipeline = (
        source_chain +
        f"x264enc bitrate={bitrate} tune={tune} speed-preset={speed} key-int-max={gop} "
        "bframes=0 byte-stream=false intra-refresh=true rc-lookahead=0 aud=false threads=2 pass=qual "
        f"! video/x-h264,profile={profile},stream-format=avc,alignment=au "
        "! h264parse config-interval=1 disable-passthrough=true "
        "! rtph264pay name=pay0 pt=96 config-interval=1"
    )
    logging.info("Using software H.264 pipeline: %s", pipeline)
    return pipeline

def _configure_logging(cfg):
    level = cfg.get('logging', 'level', fallback='INFO').upper()
    if cfg.getboolean('logging', 'verbose', fallback=False):
        level = 'DEBUG'
    log_kwargs = {
        'level': level,
        'format': '%(asctime)s %(levelname)s %(message)s',
        'force': True  # ensure reconfiguration even if something logged earlier
    }
    log_file = cfg.get('logging', 'python_log_file', fallback='').strip()
    if log_file:
        dir_part = os.path.dirname(log_file)
        if dir_part and not os.path.exists(dir_part):
            try:
                os.makedirs(dir_part, exist_ok=True)
            except Exception as e:
                print(f"Could not create log directory '{dir_part}': {e}")
        log_kwargs['filename'] = log_file
    logging.basicConfig(**log_kwargs)
    logging.info('Logging initialized (level=%s,file=%s)', level, log_file or 'stderr')

def _normalize_gst_debug_categories(cats: str, default_level: int) -> str:
    parts = []
    for seg in cats.split(','):
        seg = seg.strip()
        if not seg:
            continue
        if ':' in seg:
            parts.append(seg)
        else:
            parts.append(f"{seg}:{default_level}")
    return ','.join(parts)

def _configure_gst_debug(cfg):
    log_section = 'logging'
    level = cfg.getint(log_section, 'gst_debug_level', fallback=0)
    cats = cfg.get(log_section, 'gst_debug_categories', fallback='').strip()
    out_file = cfg.get(log_section, 'gst_debug_file', fallback='').strip()
    if cats:
        cats = _normalize_gst_debug_categories(cats, level if level > 0 else 4)
        os.environ['GST_DEBUG'] = cats
    elif level > 0:
        os.environ['GST_DEBUG'] = str(level)
    if out_file:
        os.environ['GST_DEBUG_FILE'] = out_file

def _find_pids_using_port(port: int) -> list[int]:
    pids: list[int] = []
    try:
        # ss output parsing (Linux)
        cmd = ["ss", "-ltnp"]
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            if f":{port} " in line or line.endswith(f":{port}"):
                # look for pid=NNN
                parts = line.split()
                for part in parts:
                    if part.startswith("users:") and "pid=" in part:
                        # users:(("proc",pid=123,fd=...))
                        for token in part.split(','):
                            if token.startswith('pid='):
                                try:
                                    pids.append(int(token.split('=')[1]))
                                except ValueError:
                                    pass
        return list(dict.fromkeys(pids))
    except Exception as e:
        logging.debug("Port scan failed: %s", e)
    return pids

def _kill_pids(pids: list[int]):
    for pid in pids:
        try:
            os.kill(pid, 15)
            logging.warning("Sent SIGTERM to process %d using RTSP port", pid)
        except ProcessLookupError:
            pass
        except Exception as e:
            logging.error("Failed to SIGTERM %d: %s", pid, e)
    # brief wait then force kill if still alive
    time.sleep(1)
    for pid in pids:
        try:
            os.kill(pid, 0)
            os.kill(pid, 9)
            logging.warning("Sent SIGKILL to process %d (still alive)", pid)
        except Exception:
            pass

def _detect_camera_device(config_value: str) -> str:
    """Return a camera device path. If config_value is not 'auto', return it.
    Otherwise attempt detection via Gst.DeviceMonitor, fallback to /dev/video* scan."""
    if config_value.lower() != 'auto':
        return config_value
    try:
        monitor = Gst.DeviceMonitor.new()
        monitor.add_filter("Video/Source")  # type: ignore[arg-type]
        monitor.start()
        devices = monitor.get_devices() or []  # type: ignore[assignment]
        candidates: list[str] = []
        for d in devices:
            props = d.get_properties()
            if props:
                path = props.get_string('device.path') or props.get_string('device.node')
                if path and path.startswith('/dev/video'):
                    candidates.append(path)
        monitor.stop()
        # Deduplicate while preserving order
        seen = set()
        ordered = []
        for c in candidates:
            if c not in seen:
                seen.add(c)
                ordered.append(c)
        candidates = ordered
        if candidates:
            logging.info("Auto-selected camera (DeviceMonitor): %s", candidates[0])
            return candidates[0]
    except Exception as e:
        logging.debug("DeviceMonitor detection failed: %s", e)
    # Fallback: glob /dev/video*
    vids = sorted(glob.glob('/dev/video[0-9]*'))
    for dev in vids:
        # quick permission / existence check
        if os.access(dev, os.R_OK):
            logging.info("Auto-selected camera (filesystem): %s", dev)
            return dev
    logging.error("No video devices found (auto detection)")
    return '/dev/video0'

def _list_devices() -> list[tuple[str,str]]:
    """Return list of (device_path, display_name)."""
    results: list[tuple[str,str]] = []
    try:
        monitor = Gst.DeviceMonitor.new()
        monitor.add_filter("Video/Source")  # type: ignore[arg-type]
        monitor.start()
        devices = monitor.get_devices() or []  # type: ignore[assignment]
        for d in devices:
            props = d.get_properties()
            label = d.get_display_name() or "(no-name)"
            path = None
            if props:
                path = props.get_string('device.path') or props.get_string('device.node')
            if path and path.startswith('/dev/video'):
                results.append((path, label))
        monitor.stop()
    except Exception as e:
        logging.debug("Device listing failed: %s", e)
    if not results:
        for dev in sorted(glob.glob('/dev/video[0-9]*')):
            results.append((dev, ''))
    return results

def main():
    parser = argparse.ArgumentParser(description='Camera RTSP Service')
    parser.add_argument('--config', '-c', default='config.ini', help='Path to config file')
    parser.add_argument('--print-pipeline', action='store_true', help='Print resolved pipeline and exit')
    parser.add_argument('--dry-run', action='store_true', help='Build pipeline & preflight only (no server)')
    parser.add_argument('--version', action='store_true', help='Print version and exit')
    parser.add_argument('--list-devices', action='store_true', help='List detected camera devices and exit')
    args = parser.parse_args()

    if args.version:
        print(f'camera-rtsp-service {VERSION}')
        return

    if args.list_devices:
        Gst.init(None)
        for path, name in _list_devices():
            print(f"{path}\t{name}")
        return

    cfg = load_config(args.config)
    _configure_logging(cfg)
    _configure_gst_debug(cfg)
    if os.getenv('GST_DEBUG_FILE'):
        logging.info('GST_DEBUG_FILE=%s', os.getenv('GST_DEBUG_FILE'))
    Gst.init(None)

    cam = cfg['camera']
    enc = cfg['encoding']
    device_cfg = cam.get('device', '/dev/video0')
    device = _detect_camera_device(device_cfg)
    # Overwrite in config object for logging consistency
    cam['device'] = device
    width = cam.getint('width', 0)
    height = cam.getint('height', 0)
    framerate = cam.getint('framerate', 0)
    codec = enc.get('codec', 'auto').lower()
    preflight = cam.getboolean('preflight', fallback=True)

    if preflight:
        use_mjpeg = (codec == 'jpeg') or (codec == 'auto')
        if not _preflight(device, use_mjpeg, width, height, framerate):
            # Fallback: if MJPEG attempt failed and we were trying MJPEG, retry raw before abort.
            if use_mjpeg:
                logging.warning('MJPEG preflight failed; retrying raw capture fallback...')
                if not _preflight(device, False, width, height, framerate):
                    logging.error('Preflight (fallback raw) failed. Aborting.')
                    return
                else:
                    logging.info('Fallback raw preflight succeeded; proceeding.')
            else:
                logging.error('Preflight failed. Aborting.')
                return

    rtsp_cfg = cfg['rtsp']
    port = rtsp_cfg.getint('port', 8554)
    mount = rtsp_cfg.get('mount_path', '/stream')
    if rtsp_cfg.getboolean('kill_existing', fallback=False):
        pids = _find_pids_using_port(port)
        if pids:
            logging.warning('Port %d in use by %s; attempting to terminate', port, pids)
            _kill_pids(pids)
        else:
            logging.debug('Port %d free', port)
    pipeline = build_pipeline(cfg)
    if args.print_pipeline:
        print(pipeline)
        return
    if args.dry_run:
        logging.info('Dry run requested. Exiting before server start.')
        return

    logging.info('Using pipeline: %s', pipeline)
    t = threading.Thread(target=_periodic_stats, args=(pipeline,), daemon=True)
    t.start()
    server = RtspServer(port, mount, pipeline)

    def _handle_signal(signum, _frame):
        logging.info('Signal %s received: shutting down', signum)
        server.stop()
        global _stats_stop
        _stats_stop = True

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, _handle_signal)

    try:
        server.start()
    finally:
        global _stats_stop
        _stats_stop = True
        server.stop()
        for h in logging.getLogger().handlers:
            try:
                h.flush()
            except Exception:
                pass

if __name__ == '__main__':
    main()

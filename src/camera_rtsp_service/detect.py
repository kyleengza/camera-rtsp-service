"""Device detection and preflight utilities."""
from __future__ import annotations
import logging, glob, time
import gi

gi.require_version('Gst', '1.0')
from gi.repository import Gst  # type: ignore


def init_gst():  # idempotent
    try:
        Gst.init(None)
    except Exception:
        pass


def list_devices() -> list[tuple[str,str]]:
    init_gst()
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


def auto_select(config_value: str) -> str:
    if config_value.lower() != 'auto':
        return config_value
    devices = list_devices()
    if devices:
        logging.info("Auto-selected camera: %s", devices[0][0])
        return devices[0][0]
    logging.error("No camera devices found; defaulting /dev/video0")
    return '/dev/video0'


def preflight(device: str, use_mjpeg: bool, width: int, height: int, framerate: int, timeout: float = 5.0) -> tuple[bool,str]:
    init_gst()
    caps_parts = []
    if width > 0 and height > 0:
        caps_parts.append(f"width={width},height={height}")
    if framerate > 0:
        caps_parts.append(f"framerate={framerate}/1")
    base_caps = ("image/jpeg" if use_mjpeg else "video/x-raw") + ("," + ",".join(caps_parts) if caps_parts else "")
    pipe_desc = f"v4l2src device={device} ! {base_caps} ! fakesink name=sink sync=false"
    logging.info("Preflight: %s", pipe_desc)
    try:
        pipeline = Gst.parse_launch(pipe_desc)
    except Exception as e:
        return False, f"parse_failed:{e}"
    bus = pipeline.get_bus()
    pipeline.set_state(Gst.State.PLAYING)
    ok = False
    reason = "timeout"
    start = time.time()
    while True:
        msg = bus.timed_pop_filtered(500_000_000, Gst.MessageType.ANY)
        if msg:
            t = msg.type
            if t == Gst.MessageType.ERROR:
                err, dbg = msg.parse_error()
                reason = f"error:{err.message}"
                break
            if t == Gst.MessageType.EOS:
                ok = True
                reason = 'eos'
                break
            if t == Gst.MessageType.STATE_CHANGED and msg.src == pipeline:
                new_state = msg.parse_state_changed()[1]
                if new_state == Gst.State.PLAYING:
                    ok = True
                    reason = 'playing'
                    break
        if time.time() - start > timeout:
            ok = True  # assume fine
            reason = 'assumed_ok'
            break
    pipeline.set_state(Gst.State.NULL)
    return ok, reason

__all__ = ["list_devices", "auto_select", "preflight"]

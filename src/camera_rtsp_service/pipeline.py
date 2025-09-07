"""Pipeline construction and encoder selection."""
from __future__ import annotations
import logging
import gi

gi.require_version('Gst', '1.0')
from gi.repository import Gst  # type: ignore

_HARDWARE_ENCODERS = [
    'v4l2h264enc', 'vaapih264enc', 'nvh264enc', 'omxh264enc', 'qsvh264enc'
]

_DEF_BITRATE_MAP = {
    (640, 480): 1000,
    (800, 600): 1300,
    (1280, 720): 2200,
    (1920, 1080): 4500,
    (2560, 1440): 8000,
}


def _have_element(name: str) -> bool:
    return Gst.ElementFactory.find(name) is not None


def auto_bitrate(width: int | None, height: int | None, fps: int | None, factor: float) -> int:
    if width and height and (width, height) in _DEF_BITRATE_MAP:
        base = _DEF_BITRATE_MAP[(width, height)]
    elif width and height and fps:
        base = int(width * height * fps * factor)
    else:
        return 2000
    if fps and fps > 30:
        base = int(base * (fps / 30.0) * 0.9)
    return max(300, min(base, 25000))


def select_hw_encoder(priority: str):
    priority = (priority or 'auto').strip().lower()
    if priority == 'off':
        return None, {}
    candidates = _HARDWARE_ENCODERS if priority == 'auto' else [c.strip() for c in priority.split(',') if c.strip()]
    for enc in candidates:
        if _have_element(enc):
            props: dict[str,str] = {}
            if enc == 'v4l2h264enc':
                props['insert-sps-pps'] = 'true'
            elif enc == 'vaapih264enc':
                props['rate-control'] = 'cbr'
            elif enc == 'nvh264enc':
                props['preset'] = 'low-latency-hq'
            elif enc == 'qsvh264enc':
                props['rate-control'] = 'cbr'
            return enc, props
    return None, {}


def _encoder_has_prop(name: str, prop: str) -> bool:
    fac = Gst.ElementFactory.find(name)
    if not fac:
        return False
    try:
        elem = fac.create(None)
    except Exception:
        return False
    if not elem:
        return False
    for pspec in elem.list_properties():  # type: ignore[attr-defined]
        if pspec.name == prop:
            return True
    return False


def build_pipeline(cfg) -> str:
    cam = cfg.camera
    enc = cfg.encoding
    device = cam.device
    width = cam.width
    height = cam.height
    framerate = cam.framerate
    prefer_raw = cam.prefer_raw
    codec = enc.codec.lower()

    caps_parts = []
    if width > 0 and height > 0:
        caps_parts.append(f"width={width},height={height}")
    if framerate > 0:
        caps_parts.append(f"framerate={framerate}/1")
    raw_caps = "video/x-raw" + ("," + ",".join(caps_parts) if caps_parts else "")
    mjpg_caps = "image/jpeg" + ("," + ",".join(caps_parts) if caps_parts else "")

    have_x264 = _have_element('x264enc')
    hw_encoder, hw_props = select_hw_encoder(enc.hardware_priority) if codec in ('auto','h264') else (None, {})

    use_h264 = False
    use_mjpeg_passthrough = False
    if codec == 'h264':
        use_h264 = True
    elif codec == 'jpeg':
        use_mjpeg_passthrough = True
    else:
        if hw_encoder:
            use_h264 = True
        elif have_x264:
            use_h264 = True
        else:
            use_mjpeg_passthrough = True
            logging.warning("No H.264 encoder found; using MJPEG passthrough")

    if use_mjpeg_passthrough:
        pipeline = f"v4l2src device={device} ! {mjpg_caps} ! queue leaky=downstream max-size-buffers=1 ! rtpjpegpay name=pay0 pt=26"
        logging.info("Using MJPEG pipeline: %s", pipeline)
        return pipeline

    source_caps = raw_caps if prefer_raw else mjpg_caps
    decode_chain = "" if prefer_raw else "jpegdec ! videoconvert ! "
    source_chain = f"v4l2src device={device} ! {source_caps} ! {decode_chain}queue leaky=downstream max-size-buffers=1 ! "

    bitrate = enc.bitrate_kbps
    if (bitrate == 0 and enc.auto_bitrate) or (bitrate == 0 and width and height and framerate):
        bitrate = auto_bitrate(width, height, framerate, enc.auto_bitrate_factor)
        logging.info("Auto bitrate: %d kbps", bitrate)
    if bitrate == 0:
        bitrate = 2000

    gop = enc.gop_size
    tune = enc.tune
    speed = enc.speed_preset
    profile = enc.profile if enc.profile in {"baseline","main","high"} else "baseline"

    if hw_encoder:
        prop_str_parts = []
        for k, v in hw_props.items():
            prop_str_parts.append(f"{k}={v}")
        # Prefer 'bitrate' if available; else 'target-bitrate' (usually expects bps)
        if _encoder_has_prop(hw_encoder, 'bitrate'):
            prop_str_parts.append(f"bitrate={bitrate}")
        elif _encoder_has_prop(hw_encoder, 'target-bitrate'):
            prop_str_parts.append(f"target-bitrate={bitrate*1000}")
        else:
            logging.warning("Encoder %s has no bitrate property; using defaults", hw_encoder)
        prop_str = " ".join(prop_str_parts)
        enc_block = f"{hw_encoder} {prop_str} ! h264parse config-interval=1 disable-passthrough=true ! rtph264pay name=pay0 pt=96 config-interval=1"
        pipeline = source_chain + enc_block
        logging.info("Using hardware encoder %s pipeline: %s", hw_encoder, pipeline)
        return pipeline

    pipeline = (source_chain + f"x264enc bitrate={bitrate} tune={tune} speed-preset={speed} key-int-max={gop} "
                "bframes=0 byte-stream=false intra-refresh=true rc-lookahead=0 aud=false threads=2 pass=qual "
                f"! video/x-h264,profile={profile},stream-format=avc,alignment=au "
                "! h264parse config-interval=1 disable-passthrough=true ! rtph264pay name=pay0 pt=96 config-interval=1")
    logging.info("Using software H.264 pipeline: %s", pipeline)
    return pipeline

__all__ = ["build_pipeline", "select_hw_encoder", "auto_bitrate"]

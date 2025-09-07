"""Central logging and GStreamer debug configuration."""
from __future__ import annotations
import logging, os, pathlib
from .config import AppConfig

_DEF_FORMAT = '%(asctime)s %(levelname)s %(message)s'


def configure_logging(cfg: AppConfig):
    lvl = cfg.logging.level.upper()
    if cfg.logging.verbose:
        lvl = 'DEBUG'
    log_kwargs = dict(level=getattr(logging, lvl, logging.INFO), format=_DEF_FORMAT, force=True)
    log_file = cfg.logging.python_log_file.strip()
    if log_file:
        path = pathlib.Path(log_file)
        path.parent.mkdir(parents=True, exist_ok=True)
        log_kwargs['filename'] = str(path)
    logging.basicConfig(**log_kwargs)
    logging.info("Logging initialized level=%s file=%s", lvl, log_file or 'stderr')


def configure_gst_debug(cfg: AppConfig):
    cats = cfg.logging.gst_debug_categories.strip()
    lvl = cfg.logging.gst_debug_level
    if cats:
        # add level if not included
        parts = []
        for seg in cats.split(','):
            seg = seg.strip()
            if not seg:
                continue
            if ':' not in seg:
                seg = f"{seg}:{lvl if lvl>0 else 4}"
            parts.append(seg)
        os.environ['GST_DEBUG'] = ','.join(parts)
    elif lvl > 0:
        os.environ['GST_DEBUG'] = str(lvl)
    if cfg.logging.gst_debug_file:
        os.environ['GST_DEBUG_FILE'] = cfg.logging.gst_debug_file

__all__ = ["configure_logging", "configure_gst_debug"]

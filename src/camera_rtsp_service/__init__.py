"""Camera RTSP Service package.

Provides a modular RTSP streaming daemon around GStreamer.
"""
from importlib.metadata import PackageNotFoundError, version

try:
    __version__ = version("camera-rtsp-service")  # dynamic when installed
except PackageNotFoundError:  # pragma: no cover
    __version__ = "0.3.0"

__all__ = ["__version__"]

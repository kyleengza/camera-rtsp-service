# ruff: noqa
# Legacy helper; configuration logic moved into `camera_rtsp_service.config`.

import configparser
from pathlib import Path
from typing import Union

PathLike = Union[str, Path]

def load_config(path: PathLike) -> configparser.ConfigParser:
    cfg = configparser.ConfigParser()
    if not cfg.read(path):
        raise FileNotFoundError(f"Config file not found: {path}")
    return cfg

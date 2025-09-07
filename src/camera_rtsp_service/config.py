"""Configuration loading and validation layers."""
from __future__ import annotations

import configparser
import os
from typing import Any

from pydantic import BaseModel, Field

DEFAULTS = {
    'camera': {
        'device': 'auto',
        'width': 0,
        'height': 0,
        'framerate': 0,
        'prefer_raw': False,
        'preflight': True,
    },
    'encoding': {
        'codec': 'auto',
        'bitrate_kbps': 0,
        'auto_bitrate': True,
        'auto_bitrate_factor': 0.00007,
        'gop_size': 60,
        'tune': 'zerolatency',
        'speed_preset': 'ultrafast',
        'profile': 'baseline',
        'hardware_priority': 'auto',
    },
    'rtsp': {
        'port': 8554,
        'mount_path': '/stream',
        'kill_existing': False,
    },
    'logging': {
        'level': 'INFO',
        'verbose': False,
        'python_log_file': '',
        'gst_debug_level': 0,
        'gst_debug_categories': '',
        'gst_debug_file': '',
    },
    'health': {
        'health_port': 0,
        'metrics_port': 0,
    }
}

class CameraCfg(BaseModel):
    device: str = Field(default='auto')
    width: int = 0
    height: int = 0
    framerate: int = 0
    prefer_raw: bool = False
    preflight: bool = True

class EncodingCfg(BaseModel):
    codec: str = 'auto'
    bitrate_kbps: int = 0
    auto_bitrate: bool = True
    auto_bitrate_factor: float = 0.00007
    gop_size: int = 60
    tune: str = 'zerolatency'
    speed_preset: str = 'ultrafast'
    profile: str = 'baseline'
    hardware_priority: str = 'auto'

class RtspCfg(BaseModel):
    port: int = 8554
    mount_path: str = '/stream'
    kill_existing: bool = False

    def __init__(self, **data: Any):  # type: ignore[override]
        super().__init__(**data)
        v = self.mount_path
        if not v.startswith('/'):
            v = '/' + v
        self.mount_path = v.rstrip('/') or '/stream'

class LoggingCfg(BaseModel):
    level: str = 'INFO'
    verbose: bool = False
    python_log_file: str = ''
    gst_debug_level: int = 0
    gst_debug_categories: str = ''
    gst_debug_file: str = ''

class HealthCfg(BaseModel):
    health_port: int = 0
    metrics_port: int = 0

class AppConfig(BaseModel):
    camera: CameraCfg
    encoding: EncodingCfg
    rtsp: RtspCfg
    logging: LoggingCfg
    health: HealthCfg

    def json_compact(self) -> str:
        return self.model_dump_json(exclude_none=True)

ENV_PREFIX = 'CAMRTSP_'

SECTION_KEYS = {
    'camera': set(CameraCfg.model_fields.keys()),
    'encoding': set(EncodingCfg.model_fields.keys()),
    'rtsp': set(RtspCfg.model_fields.keys()),
    'logging': set(LoggingCfg.model_fields.keys()),
    'health': set(HealthCfg.model_fields.keys()),
}

def _load_ini(path: str | None) -> dict:
    data = {}
    if not path:
        return data
    cp = configparser.ConfigParser()
    if not cp.read(path):
        raise FileNotFoundError(f"Config file not found: {path}")
    for section in cp.sections():
        sec_lower = section.lower()
        data[sec_lower] = {}
        for k, v in cp[section].items():
            data[sec_lower][k.lower()] = v
    return data

def _apply_env(over: dict):
    for key, val in os.environ.items():
        if not key.startswith(ENV_PREFIX):
            continue
        rest = key[len(ENV_PREFIX):].lower()
        # format SECTION__KEY
        if '__' in rest:
            section, k = rest.split('__', 1)
            over.setdefault(section, {})[k] = val

_SIMPLE_CASTS = {
    'width': int, 'height': int, 'framerate': int,
    'bitrate_kbps': int, 'auto_bitrate': lambda v: v.lower() in {'1','true','yes','on'},
    'auto_bitrate_factor': float, 'gop_size': int,
    'verbose': lambda v: v.lower() in {'1','true','yes','on'},
    'gst_debug_level': int, 'kill_existing': lambda v: v.lower() in {'1','true','yes','on'},
    'prefer_raw': lambda v: v.lower() in {'1','true','yes','on'}, 'preflight': lambda v: v.lower() in {'1','true','yes','on'},
    'health_port': int, 'metrics_port': int,
}

def _coerce(_section: str, k: str, v: str):
    caster = _SIMPLE_CASTS.get(k)
    if caster:
        try:
            return caster(v)
        except Exception:
            return v
    return v

def build_config(ini_path: str | None = None, cli_overrides: dict[str, Any] | None = None) -> AppConfig:
    merged: dict[str, dict[str, Any]] = {s: dict(v) for s, v in DEFAULTS.items()}
    ini_data = _load_ini(ini_path)
    for sec, kv in ini_data.items():
        merged.setdefault(sec, {})
        merged[sec].update(kv)
    _apply_env(merged)
    if cli_overrides:
        for sec, kv in cli_overrides.items():
            merged.setdefault(sec, {})
            merged[sec].update(kv)
    # coerce types
    for sec, kv in merged.items():
        for k, v in list(kv.items()):
            if isinstance(v, str):
                kv[k] = _coerce(sec, k, v)
    return AppConfig(
        camera=CameraCfg(**merged['camera']),
        encoding=EncodingCfg(**merged['encoding']),
        rtsp=RtspCfg(**merged['rtsp']),
        logging=LoggingCfg(**merged['logging']),
        health=HealthCfg(**merged['health']),
    )

__all__ = ["AppConfig", "build_config"]

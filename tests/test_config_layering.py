from camera_rtsp_service.config import build_config
import os

def test_env_override(tmp_path, monkeypatch):
    ini = tmp_path / 'cfg.ini'
    ini.write_text('[camera]\nwidth=640\n')
    monkeypatch.setenv('CAMRTSP_CAMERA__WIDTH', '800')
    cfg = build_config(str(ini))
    assert cfg.camera.width == 800

def test_defaults():
    cfg = build_config(None)
    assert cfg.rtsp.port == 8554

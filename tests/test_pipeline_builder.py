from types import SimpleNamespace

from camera_rtsp_service.pipeline import build_pipeline


class CfgNS(SimpleNamespace):
    pass

class Cam(SimpleNamespace):
    pass

class Enc(SimpleNamespace):
    pass

def make_cfg():
    return CfgNS(camera=Cam(device='/dev/video0', width=0, height=0, framerate=0, prefer_raw=False, preflight=True),
                 encoding=Enc(codec='auto', bitrate_kbps=0, auto_bitrate=True, auto_bitrate_factor=0.00007, gop_size=60, tune='zerolatency', speed_preset='ultrafast', profile='baseline', hardware_priority='off'),
                 rtsp=None, logging=None, health=None)

def test_build_pipeline_basic():
    cfg = make_cfg()
    p = build_pipeline(cfg)
    assert 'v4l2src' in p

from camera_rtsp_service.detect import auto_select

def test_auto_select_default():
    d = auto_select('auto')
    assert d.startswith('/dev/video') or d == '/dev/video0'

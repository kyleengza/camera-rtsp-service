import logging
import gi

gi.require_version('Gst', '1.0')
gi.require_version('GstRtspServer', '1.0')
from gi.repository import Gst, GstRtspServer, GObject

class _PipelineFactory(GstRtspServer.RTSPMediaFactory):
    def __init__(self, pipeline_str: str):
        super().__init__()
        self.pipeline_str = pipeline_str
        self.set_shared(True)

    def do_create_element(self, _url):  # type: ignore[override]
        return Gst.parse_launch(self.pipeline_str)

class RtspServer:
    def __init__(self, port: int, mount_path: str, pipeline: str):
        self.port = port
        self.mount_path = mount_path
        self.pipeline = pipeline
        self.loop: GObject.MainLoop | None = None
        self.server: GstRtspServer.RTSPServer | None = None

    def start(self):
        self.loop = GObject.MainLoop()  # type: ignore[assignment]
        self.server = GstRtspServer.RTSPServer.new()  # type: ignore[assignment]
        self.server.set_service(str(self.port))  # type: ignore[union-attr]

        mounts = self.server.get_mount_points()  # type: ignore[union-attr]
        factory = _PipelineFactory(self.pipeline)
        mounts.add_factory(self.mount_path, factory)  # type: ignore[arg-type]

        attach_id = self.server.attach(None)  # type: ignore[union-attr]
        if not attach_id:
            logging.error("Failed to attach RTSP server on port %d (already in use?).", self.port)
            return
        logging.info("RTSP stream listening: rtsp://%s:%d%s", "localhost", self.port, self.mount_path)
        if self.loop:
            self.loop.run()  # type: ignore[union-attr]

    def stop(self):
        if self.loop and self.loop.is_running():
            self.loop.quit()

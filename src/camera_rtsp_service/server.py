"""RTSP Server wrapper plus optional health & metrics."""
from __future__ import annotations
import logging, threading, socket, time
from typing import Optional
import gi

gi.require_version('Gst', '1.0')
gi.require_version('GstRtspServer', '1.0')
from gi.repository import Gst, GstRtspServer, GObject  # type: ignore
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST, CollectorRegistry
from wsgiref.simple_server import make_server, WSGIRequestHandler

_connections = Counter('rtsp_connections_total', 'RTSP client connections')
_sessions = Counter('rtsp_sessions_total', 'RTSP sessions started')

class _PipelineFactory(GstRtspServer.RTSPMediaFactory):
    def __init__(self, pipeline_str: str):
        super().__init__()
        self.pipeline_str = pipeline_str
        self.set_shared(True)

    def do_create_element(self, _url):  # type: ignore[override]
        _connections.inc()
        return Gst.parse_launch(self.pipeline_str)

    def do_configure(self, media: GstRtspServer.RTSPMedia):  # type: ignore[override]
        _sessions.inc()
        return super().do_configure(media)

class HttpThread(threading.Thread):
    def __init__(self, host: str, port: int, app, name: str):
        super().__init__(daemon=True, name=name)
        self.host = host; self.port = port; self.app = app
        self.httpd = None

    def run(self):
        try:
            self.httpd = make_server(self.host, self.port, self.app, handler_class=_QuietHandler)
            self.httpd.serve_forever()
        except Exception as e:
            logging.error("HTTP thread failed (%s:%d): %s", self.host, self.port, e)

    def stop(self):  # pragma: no cover
        try:
            if self.httpd:
                self.httpd.shutdown()
        except Exception:
            pass

class _QuietHandler(WSGIRequestHandler):
    def log_message(self, format, *args):  # suppress
        pass

class RtspServer:
    def __init__(self, port: int, mount_path: str, pipeline: str, health_port: int = 0, metrics_port: int = 0):
        self.port = port
        self.mount_path = mount_path
        self.pipeline = pipeline
        self.loop: GObject.MainLoop | None = None
        self.server: GstRtspServer.RTSPServer | None = None
        self._health_thread: Optional[HttpThread] = None
        self._metrics_thread: Optional[HttpThread] = None
        self._registry = CollectorRegistry()
        # Re-register counters to custom registry
        global _connections, _sessions
        _connections = Counter('rtsp_connections_total', 'RTSP client connections', registry=self._registry)
        _sessions = Counter('rtsp_sessions_total', 'RTSP sessions started', registry=self._registry)
        self.health_port = health_port
        self.metrics_port = metrics_port

    def _health_app(self, environ, start_response):  # WSGI
        start_response('200 OK', [('Content-Type', 'text/plain')])
        return [b'OK']

    def _metrics_app(self, environ, start_response):  # WSGI
        try:
            output = generate_latest(self._registry)
            start_response('200 OK', [('Content-Type', CONTENT_TYPE_LATEST)])
            return [output]
        except Exception as e:  # pragma: no cover
            start_response('500 INTERNAL SERVER ERROR', [('Content-Type','text/plain')])
            return [str(e).encode()]

    def start(self):
        self.loop = GObject.MainLoop()  # type: ignore[assignment]
        self.server = GstRtspServer.RTSPServer.new()  # type: ignore[assignment]
        self.server.set_service(str(self.port))  # type: ignore[union-attr]
        mounts = self.server.get_mount_points()  # type: ignore[union-attr]
        factory = _PipelineFactory(self.pipeline)
        mounts.add_factory(self.mount_path, factory)  # type: ignore[arg-type]
        attach_id = self.server.attach(None)  # type: ignore[union-attr]
        if not attach_id:
            logging.error("Failed to attach RTSP server on port %d", self.port)
            return
        logging.info("RTSP listening: rtsp://%s:%d%s", "localhost", self.port, self.mount_path)
        if self.health_port:
            self._health_thread = HttpThread('0.0.0.0', self.health_port, self._health_app, 'health-thread')
            self._health_thread.start()
            logging.info("Health endpoint: http://localhost:%d/", self.health_port)
        if self.metrics_port:
            self._metrics_thread = HttpThread('0.0.0.0', self.metrics_port, self._metrics_app, 'metrics-thread')
            self._metrics_thread.start()
            logging.info("Metrics endpoint: http://localhost:%d/ (Prometheus)", self.metrics_port)
        if self.loop:
            self.loop.run()  # type: ignore[union-attr]

    def stop(self):
        if self.loop and self.loop.is_running():
            self.loop.quit()
        if self._health_thread:  # pragma: no cover
            self._health_thread.stop()
        if self._metrics_thread:  # pragma: no cover
            self._metrics_thread.stop()

__all__ = ["RtspServer"]

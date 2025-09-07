# Installation Summary

## Development
See README Quick Start.

## Production (Systemd)
```bash
sudo useradd -r -s /usr/sbin/nologin camera || true
sudo usermod -aG video camera
sudo mkdir -p /opt/camera-rtsp-service && sudo chown camera:camera /opt/camera-rtsp-service
cp config.example.ini /opt/camera-rtsp-service/config.ini
pip install camera-rtsp-service  # or pip install . from source
sudo cam-rtsp generate-systemd --user camera --prefix /opt/camera-rtsp-service --config /opt/camera-rtsp-service/config.ini
sudo systemctl daemon-reload
sudo systemctl enable --now camera-rtsp.service
```

## Uninstall
```bash
sudo systemctl disable --now camera-rtsp.service
sudo rm /etc/systemd/system/camera-rtsp.service
sudo systemctl daemon-reload
pip uninstall -y camera-rtsp-service
sudo userdel camera   # optional
sudo rm -rf /opt/camera-rtsp-service  # optional
```

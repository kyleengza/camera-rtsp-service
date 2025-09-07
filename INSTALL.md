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

## Headless Automation (Checkout)
```bash
sudo bash scripts/install.sh --user camera --prefix /opt/camera-rtsp-service --port 8554
```
Override device & bitrate:
```bash
sudo bash scripts/install.sh --device /dev/video2 --bitrate 4000
```

## Uninstall Script
```bash
sudo bash scripts/uninstall.sh --purge --remove-user
```

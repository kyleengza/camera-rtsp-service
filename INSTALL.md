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

## Uninstall Script (Recommended)
```bash
sudo bash scripts/uninstall.sh --purge --remove-user
```
Flags:
- `--purge` removes the entire install prefix (venv, config, logs like gst_debug.log)
- `--remove-user` deletes the service user (journald retains historical logs)

## Manual Thorough Uninstall (If scripts missing)
```bash
sudo systemctl disable --now camera-rtsp.service || true
sudo rm -f /etc/systemd/system/camera-rtsp.service
sudo systemctl daemon-reload
sudo rm -rf /opt/camera-rtsp-service           # adjust if custom prefix
sudo pip uninstall -y camera-rtsp-service 2>/dev/null || true
sudo userdel camera 2>/dev/null || true
```

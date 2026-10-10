#!/bin/bash
set -e

echo "Installing system dependencies..."
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip i2c-tools

echo "Enabling I2C..."
sudo raspi-config nonint do_i2c 0

echo "Creating venv..."
python3 -m venv .venv

echo "Installing Python packages..."
./.venv/bin/pip install -r requirements.txt

echo "Installing systemd service..."
sudo cp oled-stats.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable oled-stats
sudo systemctl start oled-stats

echo "Done! Service is running."

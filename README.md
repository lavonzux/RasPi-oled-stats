# RasPi-oled-stats

![License](https://img.shields.io/badge/license-MIT-blue.svg)

English | [中文版](README_zh-TW.md)

A lightweight system monitor for **128×64 SSD1306 OLED displays** on Raspberry Pi.

Shows hostname, IP address, CPU / RAM usage bars, disk usage, uptime, and network connectivity status — all refreshed in real time.

Designed for the [52Pi Mini Tower Kit](https://wiki.52pi.com) (UPS Plus EP-0136 + OLED S-0005), but should work with any I2C-connected SSD1306 display.


## Display Layout

```
┌────────────────────────────────┐
│ Host: raspberrypi    [E] [W]   │  ← hostname + ethernet/wifi icons
│ IP: 192.168.1.42               │
│ CPU [████████░░░░] 67%         │  ← progress bar
│ RAM [████░░░░░░░░] 31%         │  ← progress bar
│ Disk: 4.2G/29G  15%            │  ← alternates with uptime every 5s
└────────────────────────────────┘
```

- **Top-right icons** — two 12×12 px indicators show ethernet and Wi-Fi status (up / down).
- **Bottom row** — alternates between disk usage and system uptime every 5 seconds.
- **Bootup / Shutdown splashes** — a custom 128×64 bitmap is shown on start and on graceful exit.

## Hardware Requirements

| Component | Details |
|-----------|---------|
| Board | Raspberry Pi (any model with I2C support) |
| Display | 128×64 SSD1306 OLED, I2C interface |
| Connection | SCL / SDA pins (I2C bus) |

> Tested with the [52Pi S-0005](https://wiki.52pi.com) 0.96″ OLED module.

## Quick Start

```bash
git clone https://github.com/lavonzux/RasPi-oled-stats.git
cd RasPi-oled-stats
chmod +x setup.sh
./setup.sh
```

The setup script will:

1. Run pre-flight checks (OS, Python version, I2C status, required files)
2. Install system packages (`python3-venv`, `python3-dev`, `i2c-tools`, `swig`, Pillow build deps, etc.)
3. Enable I2C via `raspi-config` (if available)
4. Create a Python virtual environment (`.venv`)
5. Install Python dependencies and verify critical imports
6. Generate and install a systemd service with correct paths
7. Start the service

### Setup Options

```bash
./setup.sh           # Install or upgrade (confirms before installing packages)
./setup.sh -y        # Install, skip all confirmations
./setup.sh --check   # Dry-run: check prerequisites without making changes
./setup.sh --remove  # Uninstall service and venv (keeps source files)
```

## Manual Installation

If you prefer to set things up step by step:

```bash
# 1. System dependencies
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip python3-dev i2c-tools \
    swig liblgpio-dev libopenjp2-7 libfreetype6-dev libjpeg-dev

# 2. Enable I2C (Raspberry Pi)
sudo raspi-config nonint do_i2c 0

# 3. Create venv and install Python packages
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt

# 4. Verify I2C (should show device at 0x3C)
i2cdetect -y 1

# 5. Test run
.venv/bin/python oled-stats.py

# 6. Install systemd service
sudo cp oled-stats.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable oled-stats
sudo systemctl start oled-stats
```

> **Note:** The `oled-stats.service` file in the repo contains placeholder paths. When using `setup.sh`, the service file is generated automatically with the correct paths for your system. If installing manually, edit the file to match your setup before copying.

## Service Management

```bash
# Check status
sudo systemctl status oled-stats

# View logs
journalctl -u oled-stats -n 50

# Follow live logs
journalctl -u oled-stats -f

# Restart after code changes
sudo systemctl restart oled-stats

# Stop
sudo systemctl stop oled-stats
```

## Project Structure

```
RasPi-oled-stats/
├── oled-stats.py          # Main script
├── requirements.txt       # Python dependencies (4 packages)
├── setup.sh               # Installer with pre-flight checks
├── oled-stats.service     # systemd unit file (template)
├── icon/
│   ├── bootup.bmp         # Splash screen on start (128×64, 1-bit)
│   ├── shutdown.bmp       # Splash screen on exit (128×64, 1-bit)
│   ├── eth_up.bmp         # Ethernet connected (12×12, 1-bit)
│   ├── eth_down.bmp       # Ethernet disconnected
│   ├── wifi_up.bmp        # Wi-Fi connected
│   ├── wifi_down.bmp      # Wi-Fi disconnected
│   └── batt_*.bmp         # Battery level icons (0–100%, charging)
├── README.md
└── README_zh-TW.md
```

## How It Works

### Network Status Detection

1. **Ethernet** — reads `/sys/class/net/<iface>/operstate` for interfaces matching `eth*`, `enp*`, `enx*`, or `en0`.
2. **Wi-Fi** — checks for an associated SSID via `iwgetid -r`.
3. **Internet reachability** — pings `8.8.8.8` through the specific interface.
4. Results are **cached for 10 seconds** (`INET_CHECK_INTERVAL`) to avoid excessive pinging.

### Graceful Shutdown

The script handles `SIGTERM` and `SIGINT` signals. On exit it displays a shutdown splash bitmap, then returns exit code `0` so systemd's `Restart=on-failure` does not trigger a respawn. The service is configured with `TimeoutStopSec=5` and `KillSignal=SIGTERM` for clean teardown.

## Customisation

| What | Where |
|------|-------|
| Change I2C address | `I2C_ADDR` in `oled-stats.py` (default `0x3C`) |
| Change ping interval | `INET_CHECK_INTERVAL` variable |
| Change bottom-row toggle speed | `time.time() / 5` — change the `5` |
| Replace splash screens | Swap `icon/bootup.bmp` and `icon/shutdown.bmp` (128×64, 1-bit BMP) |
| Replace status icons | Swap files in `icon/` (12×12, 1-bit BMP) |
| Adjust bar thickness | `bar_height` parameter in `draw_bar()` |

## Dependencies

Runtime Python packages (installed automatically by `setup.sh`):

- [psutil](https://pypi.org/project/psutil/) — system metrics
- [Pillow](https://pypi.org/project/pillow/) — image rendering
- [adafruit-blinka](https://pypi.org/project/Adafruit-Blinka/) — CircuitPython compatibility layer
- [adafruit-circuitpython-ssd1306](https://pypi.org/project/adafruit-circuitpython-ssd1306/) — OLED driver

## Credit

This project is inspired by  by [52Pi / GeeekPi](https://wiki.52pi.com) example in [geeekpi/luma.examples](https://github.com/geeekpi/luma.examples). 

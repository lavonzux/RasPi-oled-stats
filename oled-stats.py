# This example is for use on (Linux) computers that are using CPython with
# Adafruit Blinka to support CircuitPython libraries. CircuitPython does
# not support PIL/pillow (python imaging library)!

import subprocess
import time
import os
import sys
import signal

import psutil
import busio
from board import SCL, SDA
from PIL import Image, ImageDraw, ImageFont

import adafruit_ssd1306

# Icons
img_bootup         = Image.open("./icon/bootup.bmp")
img_shutdown       = Image.open("./icon/shutdown.bmp")
icon_eth_up    = Image.open("./icon/eth_up.bmp")
icon_eth_down  = Image.open("./icon/eth_down.bmp")
icon_wifi_up   = Image.open("./icon/wifi_up.bmp")
icon_wifi_down = Image.open("./icon/wifi_down.bmp")

# Create the I2C interface.
i2c = busio.I2C(SCL, SDA)

# Create the SSD1306 OLED class.
# The first two parameters are the pixel width and pixel height.  Change these
# to the right size for your display!
disp = adafruit_ssd1306.SSD1306_I2C(128, 64, i2c)

# Clear display.
disp.fill(0)
disp.show()

# Create blank image for drawing.
# Make sure to create image with mode '1' for 1-bit color.
width = disp.width
height = disp.height
image = Image.new("1", (width, height))

# Get drawing object to draw on image.
draw = ImageDraw.Draw(image)

# Draw a black filled box to clear the image.
draw.rectangle((0, 0, width, height), outline=0, fill=0)

# Load default font.
font = ImageFont.load_default()

# Bootup splash image
image.paste(img_bootup, (0,0))
disp.image(image)
disp.show()
time.sleep(3)


# Helper functions
# --- Bar drawing helper ---
# Draws a labelled progress bar, e.g.:
#
#   CPU [########    ] 67%
#
# x, y        — top-left origin of the bar row
# label       — short string shown before the bar (e.g. "CPU")
# pct         — 0.0–100.0
# bar_height  — thickness of the bar in pixels (default 6)
def draw_bar(draw, x, y, label, pct, bar_height=6):
    label_w = 24          # pixels reserved for the label text
    pct_w   = 26          # pixels reserved for the "XX%" text on the right
    bar_x   = x + label_w
    bar_w   = width - label_w - pct_w - x  # remaining width for the bar

    # Label
    draw.text((x, y), label, font=font, fill=255)

    # Outline rectangle
    draw.rectangle((bar_x, y+3, bar_x + bar_w, y+3 + bar_height), outline=255, fill=0)

    # Filled portion
    fill_w = int(bar_w * max(0.0, min(pct, 100.0)) / 100.0)
    if fill_w > 0:
        draw.rectangle((bar_x, y+3, bar_x + fill_w, y+3 + bar_height), outline=255, fill=255)

    # Percentage text
    draw.text((bar_x + bar_w + 3, y), f"{pct:.0f}%", font=font, fill=255)

# Get system uptime using psutil
def get_uptime():
    # uptime_seconds is a float of total seconds since boot
    uptime_seconds = time.time() - psutil.boot_time()
    days    = int(uptime_seconds // 86400)
    hours   = int((uptime_seconds % 86400) // 3600)
    minutes = int((uptime_seconds % 3600) // 60)
    if days > 0:
        return f"Up: {days}d {hours}h {minutes}m"
    return f"Up: {hours}h {minutes}m"

# --- Connection status helpers with cached ping ---
INET_CHECK_INTERVAL = 10  # seconds between actual pings

_last_inet_check = {
    "eth":  (0, False),  # (last_check_timestamp, result)
    "wifi": (0, False),
}

def is_internet_up(iface=None):
    cmd = "ping -c 1 -W 1 8.8.8.8"
    if iface:
        cmd += f" -I {iface}"
    result = subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode == 0

def is_ethernet_up():
    ts, cached = _last_inet_check["eth"]
    if time.time() - ts > INET_CHECK_INTERVAL:
        for iface in os.listdir("/sys/class/net/"):
            if iface.startswith(("eth", "enp", "enx", "en0")):
                state = open(f"/sys/class/net/{iface}/operstate").read().strip()
                result = state == "up" and is_internet_up(iface)
                _last_inet_check["eth"] = (time.time(), result)
                return result
        _last_inet_check["eth"] = (time.time(), False)
        return False
    return cached

def is_wifi_up():
    ts, cached = _last_inet_check["wifi"]
    if time.time() - ts > INET_CHECK_INTERVAL:
        try:
            ssid = subprocess.check_output("iwgetid -r 2>/dev/null", shell=True).decode().strip()
            result = bool(ssid) and is_internet_up("wlan0")
        except:
            result = False
        _last_inet_check["wifi"] = (time.time(), result)
        return result
    return cached

shutdown_requested = False
def handle_shutdown(signum, frame):
    global shutdown_requested
    shutdown_requested = True

signal.signal(signal.SIGTERM, handle_shutdown)
signal.signal(signal.SIGINT, handle_shutdown)

try:
    while not shutdown_requested:
        # Clear canvas
        draw.rectangle((0, 0, width, height), outline=0, fill=0)

        # --- Hostname (top row) ---
        hostname = subprocess.check_output("hostname", shell=True).decode("utf-8").strip()
        draw.text((0, 0), "Host: " + hostname, font=font, fill=255)

        # --- Connection icons (top-right corner) ---
        # Ethernet at x=104, Wifi at x=116 — two 12px icons with 0px gap
        image.paste(icon_eth_up  if is_ethernet_up() else icon_eth_down,  (100, 4))
        image.paste(icon_wifi_up if is_wifi_up()     else icon_wifi_down, (116, 4))

        # --- IP address ---
        cmd = "hostname -I | cut -d' ' -f1"
        ip = subprocess.check_output(cmd, shell=True).decode("utf-8").strip()
        draw.text((0, 14), "IP: " + ip, font=font, fill=255)

        # --- CPU bar ---
        # interval=0.1 gives a non-blocking reading; adjust if you want more accuracy
        cpu_pct = psutil.cpu_percent(interval=0.1)
        draw_bar(draw, x=0, y=26, label="CPU", pct=cpu_pct)

        # --- RAM bar ---
        mem = psutil.virtual_memory()
        ram_pct = mem.percent
        draw_bar(draw, x=0, y=38, label="RAM", pct=ram_pct)

        # --- 5th line: alternate disk / uptime every 2 seconds ---
        if int(time.time() / 5) % 2 == 0:
            cmd = 'df -h | awk \'$NF=="/"{printf "Disk: %s/%s  %s", $3,$2,$5}\''
            bottom_text = subprocess.check_output(cmd, shell=True).decode("utf-8").strip()
        else:
            bottom_text = get_uptime()
        draw.text((0, 52), bottom_text, font=font, fill=128)

        # Push to display
        disp.image(image)
        disp.show()
        time.sleep(1)
except KeyboardInterrupt:
    pass
finally:
    draw.rectangle((0, 0, width, height), outline=0, fill=0)
    image.paste(img_shutdown, (0, 0))
    disp.image(image)
    disp.show()

sys.exit(0)

# OLED Stats Display — modular, config-driven
# Drives a 128×64 SSD1306 OLED over I2C on Raspberry Pi.
# Layout is defined in config.yaml; each row can hold one or more
# widgets that rotate on a configurable cycle.

import os
import shutil
import signal
import socket
import subprocess
import sys
import time

import psutil
import yaml
import busio
from board import SCL, SDA
from PIL import Image, ImageDraw, ImageFont

import adafruit_ssd1306

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
APP_NAME = "oled-stats"


# ── Config (XDG Base Directory) ─────────────────────────────────────

DEFAULT_CONFIG = {
    "panel": {"rows": 5, "update_interval": 1},
    "layout": [
        {"items": [{"type": "hostname"}]},
        {"items": [
            {"type": "net_status", "interface": "eth", "duration": 3},
            {"type": "net_status", "interface": "wifi", "duration": 3},
        ]},
        {"items": [{"type": "cpu_bar"}]},
        {"items": [{"type": "ram_bar"}]},
        {"items": [
            {"type": "disk", "duration": 5},
            {"type": "uptime", "duration": 5},
        ]},
    ],
}


def _xdg_config_path():
    base = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
    return os.path.join(base, APP_NAME, "config.yaml")


def load_config():
    """Load config with XDG → local → hardcoded fallback chain.

    If a local config.yaml is found but the XDG copy doesn't exist yet,
    it is automatically promoted (copied) to the XDG location.
    """
    xdg_path   = _xdg_config_path()
    local_path = os.path.join(BASE_DIR, "config.yaml")

    for path in (xdg_path, local_path):
        if os.path.exists(path):
            with open(path) as f:
                cfg = yaml.safe_load(f)
            # Auto-promote: local found but XDG missing → copy to XDG
            if path == local_path and not os.path.exists(xdg_path):
                os.makedirs(os.path.dirname(xdg_path), exist_ok=True)
                shutil.copy2(local_path, xdg_path)
            return cfg

    return DEFAULT_CONFIG


# ── Network helpers ─────────────────────────────────────────────────

INET_CHECK_INTERVAL = 10          # seconds between real pings

_net_cache = {
    "eth":  {"ts": 0, "link_up": False, "inet_up": False, "ip": "", "has_gw": False},
    "wifi": {"ts": 0, "link_up": False, "inet_up": False, "ip": "", "has_gw": False},
}


def _ping(iface=None):
    cmd = ["ping", "-c", "1", "-W", "1", "8.8.8.8"]
    if iface:
        cmd += ["-I", iface]
    return subprocess.run(
        cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    ).returncode == 0


def _iface_ip(name):
    """IPv4 address for a given interface, via psutil."""
    for addr in psutil.net_if_addrs().get(name, []):
        if addr.family == socket.AF_INET:
            return addr.address
    return ""


def _find_iface(prefixes):
    """Return the first operstate=up interface matching *prefixes*."""
    for name in os.listdir("/sys/class/net/"):
        if name.startswith(prefixes):
            try:
                state = open(f"/sys/class/net/{name}/operstate").read().strip()
                if state == "up":
                    return name
            except OSError:
                pass
    return None


def _has_default_route(iface):
    """Check whether *iface* carries a default route (dest 00000000)."""
    try:
        with open("/proc/net/route") as f:
            for line in f:
                fields = line.strip().split("\t")
                if len(fields) >= 2 and fields[0] == iface and fields[1] == "00000000":
                    return True
    except OSError:
        pass
    return False


def get_net_info(kind):
    """Return cached dict for 'eth' or 'wifi'.

    Keys: link_up, inet_up, ip, has_gw.
    """
    c = _net_cache[kind]
    if time.time() - c["ts"] <= INET_CHECK_INTERVAL:
        return c

    prefixes = ("eth", "enp", "enx", "en0") if kind == "eth" else ("wlan",)
    iface = _find_iface(prefixes)

    link_up = False
    inet_up = False
    ip = ""
    has_gw = False

    if iface:
        ip = _iface_ip(iface)
        link_up = bool(ip)
        has_gw = _has_default_route(iface)
        if has_gw and link_up:
            inet_up = _ping(iface)

    c.update(ts=time.time(), link_up=link_up, inet_up=inet_up, ip=ip, has_gw=has_gw)
    return c


# ── Drawing primitives ──────────────────────────────────────────────

def draw_bar(draw, x, y, label, pct, total_w, font, bar_h=6):
    """Labelled progress bar:  CPU [########    ] 67%"""
    label_w = 24
    pct_w   = 26
    bar_x   = x + label_w
    bar_w   = total_w - label_w - pct_w - x

    draw.text((x, y), label, font=font, fill=255)
    draw.rectangle(
        (bar_x, y + 3, bar_x + bar_w, y + 3 + bar_h),
        outline=255, fill=0,
    )
    fill_w = int(bar_w * max(0, min(pct, 100)) / 100)
    if fill_w > 0:
        draw.rectangle(
            (bar_x, y + 3, bar_x + fill_w, y + 3 + bar_h),
            outline=255, fill=255,
        )
    draw.text((bar_x + bar_w + 3, y), f"{pct:.0f}%", font=font, fill=255)


def format_uptime():
    secs = time.time() - psutil.boot_time()
    d = int(secs // 86400)
    h = int((secs % 86400) // 3600)
    m = int((secs % 3600) // 60)
    return f"Up: {d}d {h}h {m}m" if d else f"Up: {h}h {m}m"


# ── Widget renderers ────────────────────────────────────────────────
# Signature: (draw, image, x, y, width, font, cfg, icons) -> None

def w_hostname(draw, image, x, y, width, font, cfg, icons):
    draw.text((x, y), "Host: " + socket.gethostname(), font=font, fill=255)


def w_net_status(draw, image, x, y, width, font, cfg, icons):
    kind = cfg.get("interface", "eth")
    info = get_net_info(kind)

    col_w = 12  # fixed column width for each indicator (matches icon size)
    cx = x

    # ── Default-route indicator: * or blank
    if info["has_gw"]:
        draw.text((cx, y), "*", font=font, fill=255)
    cx += col_w

    # ── Interface-type icon (12×12 bmp)
    icon = icons.get(kind)
    if icon:
        image.paste(icon, (cx, y))
    cx += col_w

    # ── Internet-access icon (only for default-route interfaces)
    if info["has_gw"]:
        inet_key = "inet_up" if info["inet_up"] else "inet_down"
        inet_icon = icons.get(inet_key)
        if inet_icon:
            image.paste(inet_icon, (cx, y))
    cx += col_w

    # ── IP address (right-aligned to display edge)
    ip_text = info["ip"] or "N/A"
    bbox = font.getbbox(ip_text)
    ip_w = bbox[2] - bbox[0]
    draw.text((x + width - ip_w, y), ip_text, font=font, fill=255)


def w_cpu_bar(draw, image, x, y, width, font, cfg, icons):
    draw_bar(draw, x, y, "CPU", psutil.cpu_percent(interval=0.1), width, font)


def w_ram_bar(draw, image, x, y, width, font, cfg, icons):
    draw_bar(draw, x, y, "RAM", psutil.virtual_memory().percent, width, font)


def w_disk(draw, image, x, y, width, font, cfg, icons):
    du = psutil.disk_usage("/")
    used  = du.used  / (1024 ** 3)
    total = du.total / (1024 ** 3)
    draw.text(
        (x, y),
        f"Disk: {used:.1f}G/{total:.0f}G  {du.percent:.0f}%",
        font=font, fill=255,
    )


def w_uptime(draw, image, x, y, width, font, cfg, icons):
    draw.text((x, y), format_uptime(), font=font, fill=255)


WIDGETS = {
    "hostname":   w_hostname,
    "net_status": w_net_status,
    "cpu_bar":    w_cpu_bar,
    "ram_bar":    w_ram_bar,
    "disk":       w_disk,
    "uptime":     w_uptime,
}


# ── Main ────────────────────────────────────────────────────────────

def main():
    config   = load_config()
    panel    = config["panel"]
    layout   = config["layout"]
    rows     = panel.get("rows", 5)
    interval = panel.get("update_interval", 1)

    # Display
    i2c  = busio.I2C(SCL, SDA)
    disp = adafruit_ssd1306.SSD1306_I2C(128, 64, i2c)
    disp.fill(0)
    disp.show()

    W, H   = disp.width, disp.height
    image  = Image.new("1", (W, H))
    draw   = ImageDraw.Draw(image)
    font   = ImageFont.load_default()

    # Pre-compute y positions: rows with explicit `height` get it;
    # the rest split whatever vertical space remains equally.
    active  = layout[:rows]
    fixed   = sum(r["height"] for r in active if "height" in r)
    n_auto  = sum(1 for r in active if "height" not in r)
    auto_h  = (H - fixed) // n_auto if n_auto else 0
    y_table = []
    y = 0
    for r in active:
        y_table.append(y)
        y += r.get("height", auto_h)

    # Load icons
    icon_dir = os.path.join(BASE_DIR, "icon")
    icons = {}
    for name, fname in (
        ("eth",       "eth_up.bmp"),
        ("wifi",      "wifi_up.bmp"),
        ("inet_up",   "inet_up.bmp"),
        ("inet_down", "inet_down.bmp"),
        ("bootup",    "bootup.bmp"),
        ("shutdown",  "shutdown.bmp"),
    ):
        p = os.path.join(icon_dir, fname)
        if os.path.exists(p):
            icons[name] = Image.open(p)

    # Bootup splash
    if "bootup" in icons:
        image.paste(icons["bootup"], (0, 0))
        disp.image(image)
        disp.show()
        time.sleep(3)

    # Graceful shutdown
    shutdown = False
    def _sig(sig, frame):
        nonlocal shutdown
        shutdown = True
    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT,  _sig)

    cycle = 0
    try:
        while not shutdown:
            draw.rectangle((0, 0, W, H), outline=0, fill=0)

            for idx, row in enumerate(active):
                y     = y_table[idx]
                items = row.get("items", [])
                if not items:
                    continue

                # Single item → always visible; multiple → rotate by duration
                if len(items) == 1:
                    item = items[0]
                else:
                    total = sum(it.get("duration", 1) for it in items)
                    pos   = cycle % total
                    acc   = 0
                    item  = items[0]
                    for it in items:
                        d = it.get("duration", 1)
                        if pos < acc + d:
                            item = it
                            break
                        acc += d

                renderer = WIDGETS.get(item.get("type"))
                if renderer:
                    renderer(draw, image, 0, y, W, font, item, icons)

            disp.image(image)
            disp.show()
            cycle += 1
            time.sleep(interval)

    except KeyboardInterrupt:
        pass
    finally:
        draw.rectangle((0, 0, W, H), outline=0, fill=0)
        if "shutdown" in icons:
            image.paste(icons["shutdown"], (0, 0))
        disp.image(image)
        disp.show()

    sys.exit(0)


if __name__ == "__main__":
    main()

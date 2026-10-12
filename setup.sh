#!/bin/bash
# =============================================================================
# OLED Stats Display — Setup Script
#
# Designed for the 52Pi Mini Tower Kit, which includes:
#   - UPS Plus (EP-0136) power management module
#   - 0.96" SSD1306 OLED display (S-0005)
#   - 3D-printed enclosure
#
# This script may work with other SSD1306 OLED setups on Raspberry Pi,
# but is only tested with the 52Pi kit above.
# For hardware documentation, visit: https://wiki.52pi.com
#
# Installs and configures the SSD1306 OLED stats display service on
# Debian-based systems (Raspberry Pi OS, Proxmox, plain Debian, Ubuntu, etc.)
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh           # Install / upgrade (confirms before installing packages)
#   ./setup.sh -y        # Install / upgrade, skip all confirmations
#   ./setup.sh --check   # Dry-run: only check prerequisites, change nothing
#   ./setup.sh --remove  # Uninstall service and venv (keeps source files)
# =============================================================================
set -euo pipefail

# ─── Constants ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"
SERVICE_NAME="oled-stats"
SERVICE_FILE="${SERVICE_NAME}.service"
SERVICE_DEST="/etc/systemd/system/${SERVICE_FILE}"
PYTHON_SCRIPT="oled-stats.py"
REQUIRED_FILES=("${PYTHON_SCRIPT}" "${SERVICE_FILE}" "requirements.txt" "config.yaml")
ICON_DIR="${SCRIPT_DIR}/icon"
REQUIRED_ICONS=("eth_up.bmp" "wifi_up.bmp" "inet_up.bmp" "inet_down.bmp"
  "bootup.bmp" "shutdown.bmp")

# Minimum Python version (major.minor)
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=9

# Expected I2C address for the SSD1306 OLED (7-bit, hex)
OLED_I2C_ADDR="0x3c"
I2C_BUS=1

# ─── Colors & formatting ────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

info() { echo -e "${GREEN}[✓]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err() { echo -e "${RED}[✗]${RESET} $*" >&2; }
step() { echo -e "\n${CYAN}${BOLD}── $* ──${RESET}"; }
hint() { echo -e "    ${YELLOW}↳${RESET} $*"; }

die() {
  err "$1"
  [[ -n "${2:-}" ]] && hint "$2"
  exit 1
}

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -y         Skip all confirmation prompts (auto-yes)
  --check    Dry-run: check all prerequisites without making changes
  --remove   Uninstall the service and remove the venv (source files are kept)
  -h, --help Show this help message

Examples:
  ./setup.sh           # Install or upgrade
  ./setup.sh -y        # Install, skip confirmations
  ./setup.sh --check   # Verify the system is ready
  ./setup.sh --remove  # Clean uninstall
EOF
}

# ─── Parse arguments ─────────────────────────────────────────────────────────
MODE="install"
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
  -y | --yes) AUTO_YES=true ;;
  --check) MODE="check" ;;
  --remove) MODE="remove" ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "Unknown option: $1" "Run '$(basename "$0") --help' for usage." ;;
  esac
  shift
done

# Prompt the user for confirmation. Returns 0 (yes) or exits/returns 1 (no).
# Automatically answers yes when -y is passed.
confirm() {
  local prompt="${1:-Continue?}"
  if [[ "${AUTO_YES}" == true ]]; then
    return 0
  fi
  read -rp "  ${prompt} [y/N] " answer
  case "${answer}" in
  [Yy]*) return 0 ;;
  *) return 1 ;;
  esac
}

# ─── Uninstall ───────────────────────────────────────────────────────────────
do_remove() {
  step "Removing OLED Stats Display"

  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    info "Stopping service..."
    sudo systemctl stop "${SERVICE_NAME}"
  fi

  if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    info "Disabling service..."
    sudo systemctl disable "${SERVICE_NAME}"
  fi

  if [[ -f "${SERVICE_DEST}" ]]; then
    info "Removing service file..."
    sudo rm -f "${SERVICE_DEST}"
    sudo systemctl daemon-reload
  fi

  if [[ -d "${VENV_DIR}" ]]; then
    info "Removing virtual environment (${VENV_DIR})..."
    rm -rf "${VENV_DIR}"
  fi

  # XDG config cleanup
  local xdg_cfg="${XDG_CONFIG_HOME:-${HOME}/.config}/${SERVICE_NAME}"
  if [[ -d "${xdg_cfg}" ]]; then
    warn "XDG config directory found at ${xdg_cfg}"
    if confirm "Remove config directory? (Your config.yaml will be deleted)"; then
      rm -rf "${xdg_cfg}"
      info "Config directory removed."
    else
      info "Config directory kept at ${xdg_cfg}"
    fi
  fi

  info "Uninstall complete. Source files in ${SCRIPT_DIR} were kept."
  echo ""
  hint "To fully remove, delete the project directory:"
  hint "  rm -rf ${SCRIPT_DIR}"
}

if [[ "${MODE}" == "remove" ]]; then
  do_remove
  exit 0
fi

# =============================================================================
# Pre-flight checks
# =============================================================================
ERRORS=0
WARNINGS=0

step "Checking prerequisites"

# ── Must not run as root ─────────────────────────────────────────────────────
if [[ "${EUID}" -eq 0 ]]; then
  die "Do not run this script as root." \
    "Run as a normal user. The script uses sudo where needed."
fi

# ── sudo available? ──────────────────────────────────────────────────────────
if ! command -v sudo &>/dev/null; then
  die "sudo is not installed." \
    "Install it first:  su -c 'apt-get install -y sudo'"
fi

# ── Debian-based? ────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
  *debian* | *ubuntu* | *raspbian*)
    info "OS: ${PRETTY_NAME:-${ID}} — Debian-based ✓"
    ;;
  *)
    err "Unsupported OS: ${PRETTY_NAME:-${ID}}"
    hint "This script is designed for Debian-based distributions."
    hint "It may still work — proceed at your own risk."
    WARNINGS=$((WARNINGS + 1))
    ;;
  esac
else
  err "Cannot detect OS (/etc/os-release not found)."
  WARNINGS=$((WARNINGS + 1))
fi

# ── Architecture ─────────────────────────────────────────────────────────────
ARCH="$(uname -m)"
case "${ARCH}" in
armv7l | aarch64)
  info "Architecture: ${ARCH} ✓"
  ;;
x86_64 | i686)
  warn "Architecture: ${ARCH} — not a typical Raspberry Pi."
  hint "I2C hardware and Adafruit Blinka may not work on this platform."
  WARNINGS=$((WARNINGS + 1))
  ;;
*)
  warn "Architecture: ${ARCH} — untested."
  WARNINGS=$((WARNINGS + 1))
  ;;
esac

# ── Python version ───────────────────────────────────────────────────────────
if command -v python3 &>/dev/null; then
  PY_VERSION="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")')"
  PY_MAJOR="$(echo "${PY_VERSION}" | cut -d. -f1)"
  PY_MINOR="$(echo "${PY_VERSION}" | cut -d. -f2)"

  if [[ "${PY_MAJOR}" -gt "${MIN_PYTHON_MAJOR}" ]] ||
    [[ "${PY_MAJOR}" -eq "${MIN_PYTHON_MAJOR}" && "${PY_MINOR}" -ge "${MIN_PYTHON_MINOR}" ]]; then
    info "Python: ${PY_VERSION} ✓"
  else
    err "Python ${PY_VERSION} is too old. Minimum required: ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}"
    hint "sudo apt-get install -y python3"
    ERRORS=$((ERRORS + 1))
  fi
else
  err "python3 not found."
  hint "sudo apt-get install -y python3"
  ERRORS=$((ERRORS + 1))
fi

# ── python3-venv available? ──────────────────────────────────────────────────
if ! python3 -c "import venv" &>/dev/null 2>&1; then
  err "python3-venv module is missing."
  hint "sudo apt-get install -y python3-venv"
  ERRORS=$((ERRORS + 1))
else
  info "python3-venv: available ✓"
fi

# ── I2C status ───────────────────────────────────────────────────────────────
I2C_NEEDS_ENABLE=false
if [[ -e /dev/i2c-1 ]] || [[ -e /dev/i2c-0 ]]; then
  info "I2C device: found ✓"

  # Check if current user can access it
  if [[ -r /dev/i2c-1 ]] || [[ -r /dev/i2c-0 ]]; then
    info "I2C permission: accessible ✓"
  else
    warn "I2C device exists but current user cannot access it."
    hint "Add yourself to the i2c group:  sudo usermod -aG i2c $(whoami)"
    hint "Then log out and back in."
    WARNINGS=$((WARNINGS + 1))
  fi
else
  I2C_NEEDS_ENABLE=true

  # Try to figure out WHY I2C is missing — is it a config issue or hardware?
  # Raspberry Pi stores boot parameters in config.txt; location varies by OS version.
  BOOT_CONFIG=""
  for candidate in /boot/firmware/config.txt /boot/config.txt; do
    [[ -f "${candidate}" ]] && BOOT_CONFIG="${candidate}" && break
  done

  if [[ -n "${BOOT_CONFIG}" ]]; then
    # We're on a Raspberry Pi (or at least have a Pi-style boot config).
    # Check whether I2C is explicitly enabled in the boot config.
    if grep -qE '^\s*dtparam=.*i2c_arm=on' "${BOOT_CONFIG}" 2>/dev/null; then
      # Config says I2C is on, but /dev/i2c-* doesn't exist — unusual.
      # Could be: module not loaded yet, needs reboot, or hardware issue.
      warn "I2C is enabled in ${BOOT_CONFIG} but /dev/i2c-* not found."
      if ! lsmod 2>/dev/null | grep -q i2c_dev; then
        hint "The i2c-dev kernel module is not loaded."
        hint "Try:  sudo modprobe i2c-dev"
        hint "If that works, a reboot should make it persistent."
      else
        hint "The i2c-dev module is loaded but no device appeared."
        hint "Try rebooting. If the problem persists, check hardware connections."
      fi
    else
      # I2C not enabled — this is the most common first-install scenario.
      warn "I2C is not enabled in ${BOOT_CONFIG}."
      if command -v raspi-config &>/dev/null; then
        hint "Enable it via raspi-config:"
        hint "  sudo raspi-config → Interface Options → I2C → Enable"
        hint "Then reboot:  sudo reboot"
      else
        hint "Enable it by adding this line to ${BOOT_CONFIG}:"
        hint "  dtparam=i2c_arm=on"
        hint "Then reboot:  sudo reboot"
      fi
    fi
  else
    # No Pi boot config found — likely Proxmox or other non-Pi Debian.
    warn "No I2C device found (/dev/i2c-*)."
    if ! lsmod 2>/dev/null | grep -q i2c_dev; then
      hint "The i2c-dev kernel module is not loaded."
      hint "Try:  sudo modprobe i2c-dev"
      hint "To make it persistent:  echo 'i2c-dev' | sudo tee /etc/modules-load.d/i2c.conf"
    else
      hint "The i2c-dev module is loaded but no device appeared."
      hint "Check that I2C is enabled in your platform's firmware/BIOS settings"
      hint "and that the hardware is properly connected."
    fi
  fi
  WARNINGS=$((WARNINGS + 1))
fi

# ── OLED on I2C bus? ─────────────────────────────────────────────────────────
if command -v i2cdetect &>/dev/null && [[ -e /dev/i2c-${I2C_BUS} ]]; then
  if sudo i2cdetect -y "${I2C_BUS}" 2>/dev/null | grep -qw "${OLED_I2C_ADDR#0x}"; then
    info "SSD1306 OLED detected at ${OLED_I2C_ADDR} on bus ${I2C_BUS} ✓"
  else
    warn "No device found at ${OLED_I2C_ADDR} on I2C bus ${I2C_BUS}."
    hint "Check that the OLED display is properly connected."
    hint "Run 'i2cdetect -y ${I2C_BUS}' to see all devices on the bus."
    hint "If the OLED is at a different address (e.g. 0x3d), update"
    hint "OLED_I2C_ADDR in this script and I2C_ADDR in ${PYTHON_SCRIPT}."
    WARNINGS=$((WARNINGS + 1))
  fi
elif [[ "${I2C_NEEDS_ENABLE}" == false ]]; then
  warn "i2cdetect not available — skipping OLED detection."
  hint "It will be installed with i2c-tools in the next step."
  WARNINGS=$((WARNINGS + 1))
fi

# ── Project files ────────────────────────────────────────────────────────────
for f in "${REQUIRED_FILES[@]}"; do
  if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
    info "File: ${f} ✓"
  else
    err "Missing file: ${f}"
    hint "Make sure you're running this script from the project directory."
    ERRORS=$((ERRORS + 1))
  fi
done

# ── Icons (warn only — non-fatal) ───────────────────────────────────────────
MISSING_ICONS=()
for icon in "${REQUIRED_ICONS[@]}"; do
  if [[ ! -f "${ICON_DIR}/${icon}" ]]; then
    MISSING_ICONS+=("${icon}")
  fi
done
if [[ ${#MISSING_ICONS[@]} -gt 0 ]]; then
  warn "Missing icon(s) in ${ICON_DIR}/: ${MISSING_ICONS[*]}"
  hint "The script will crash at runtime if these are not present."
  WARNINGS=$((WARNINGS + 1))
else
  info "Icons: all present ✓"
fi

# ── Summary of pre-flight ────────────────────────────────────────────────────
echo ""
if [[ ${ERRORS} -gt 0 ]]; then
  die "Pre-flight failed with ${ERRORS} error(s). Fix them and retry." \
    "Scroll up for details and suggested fixes."
fi

if [[ ${WARNINGS} -gt 0 ]]; then
  warn "${WARNINGS} warning(s) found. Installation may still succeed."
fi

if [[ "${MODE}" == "check" ]]; then
  info "Pre-flight check complete — no changes were made."
  exit 0
fi

# =============================================================================
# Install / Upgrade
# =============================================================================

# ── System packages ──────────────────────────────────────────────────────────
step "Installing system packages"

PKGS_TO_INSTALL=()
# swig + liblgpio-dev are needed to build the lgpio Python wheel (pulled in by adafruit-blinka)
for pkg in python3-venv python3-pip python3-dev i2c-tools swig liblgpio-dev; do
  if dpkg -s "${pkg}" &>/dev/null; then
    info "${pkg}: already installed"
  else
    PKGS_TO_INSTALL+=("${pkg}")
  fi
done

# libopenjp2-7 and libfreetype are needed by Pillow on ARM
for pkg in libopenjp2-7 libfreetype-dev libjpeg-dev; do
  if dpkg -s "${pkg}" &>/dev/null; then
    info "${pkg}: already installed"
  else
    PKGS_TO_INSTALL+=("${pkg}")
  fi
done

if [[ ${#PKGS_TO_INSTALL[@]} -gt 0 ]]; then
  info "The following packages will be installed via apt:"
  for pkg in "${PKGS_TO_INSTALL[@]}"; do
    echo "    • ${pkg}"
  done
  if confirm "Install these ${#PKGS_TO_INSTALL[@]} package(s)?"; then
    sudo apt-get update -qq
    sudo apt-get install -y "${PKGS_TO_INSTALL[@]}"
  else
    die "Aborted by user." \
      "These packages are required. Re-run when ready."
  fi
else
  info "All system packages already installed."
fi

# ── Enable I2C ───────────────────────────────────────────────────────────────
step "Configuring I2C"

if [[ "${I2C_NEEDS_ENABLE}" == true ]]; then
  if command -v raspi-config &>/dev/null; then
    info "Enabling I2C via raspi-config..."
    sudo raspi-config nonint do_i2c 0
    info "I2C enabled. A reboot may be needed for it to take effect."
  else
    # On plain Debian / Proxmox — no raspi-config
    warn "raspi-config not available (plain Debian / Proxmox?)."
    echo ""
    echo "  To enable I2C manually:"
    echo ""
    echo "  1. Add to /boot/config.txt (or /boot/firmware/config.txt):"
    echo "       dtparam=i2c_arm=on"
    echo ""
    echo "  2. Load the kernel module:"
    echo "       echo 'i2c-dev' | sudo tee /etc/modules-load.d/i2c.conf"
    echo "       sudo modprobe i2c-dev"
    echo ""
    echo "  3. Add your user to the i2c group:"
    echo "       sudo usermod -aG i2c $(whoami)"
    echo ""
    echo "  4. Reboot."
    echo ""

    if confirm "Continue installation anyway?"; then
      info "Continuing..."
    else
      die "Aborted." "Enable I2C first, then re-run this script."
    fi
  fi
else
  info "I2C already enabled."
fi

# ── Python venv ──────────────────────────────────────────────────────────────
step "Setting up Python virtual environment"

VENV_EXISTED=false
if [[ -d "${VENV_DIR}" ]]; then
  VENV_EXISTED=true
  # Verify existing venv is functional
  if "${VENV_DIR}/bin/python" -c "import sys" &>/dev/null; then
    info "Existing venv is functional — reusing."
  else
    warn "Existing venv is broken — recreating."
    rm -rf "${VENV_DIR}"
    VENV_EXISTED=false
  fi
fi

if [[ "${VENV_EXISTED}" == false ]]; then
  info "Creating virtual environment at ${VENV_DIR}..."
  if ! python3 -m venv "${VENV_DIR}"; then
    rm -rf "${VENV_DIR}"
    die "Failed to create virtual environment." \
      "Check that python3-venv is installed:  sudo apt-get install -y python3-venv"
  fi
fi

info "Upgrading pip..."
"${VENV_DIR}/bin/pip" install --upgrade pip --quiet

info "Installing Python dependencies..."
if "${VENV_DIR}/bin/pip" install -r "${SCRIPT_DIR}/requirements.txt"; then
  info "Python dependencies installed."
else
  err "pip install failed — cleaning up venv to avoid leaving broken state."
  rm -rf "${VENV_DIR}"
  hint "Common fixes:"
  hint "  - Check your internet connection"
  hint "  - If lgpio fails to build:  sudo apt-get install -y swig liblgpio-dev"
  hint "  - If Pillow fails to build:"
  hint "    sudo apt-get install -y libopenjp2-7 libfreetype-dev libjpeg-dev"
  hint "  - Re-run this script after fixing the issue."
  exit 1
fi

# ── Verify critical imports ──────────────────────────────────────────────────
step "Verifying Python imports"

IMPORT_ERRORS=0
for mod in psutil PIL adafruit_ssd1306 busio board; do
  if "${VENV_DIR}/bin/python" -c "import ${mod}" &>/dev/null; then
    info "import ${mod}: OK"
  else
    err "import ${mod}: FAILED"
    IMPORT_ERRORS=$((IMPORT_ERRORS + 1))
  fi
done

if [[ ${IMPORT_ERRORS} -gt 0 ]]; then
  err "Cleaning up venv — imports failed, environment is unusable."
  rm -rf "${VENV_DIR}"
  die "${IMPORT_ERRORS} import(s) failed." \
    "This usually means a C library is missing. Check the errors above."
fi

# ── XDG config ──────────────────────────────────────────────────────────────
step "Setting up configuration (XDG Base Directory)"

XDG_CFG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
CONFIG_DIR="${XDG_CFG_HOME}/${SERVICE_NAME}"

mkdir -p "${CONFIG_DIR}"

if [[ -f "${CONFIG_DIR}/config.yaml" ]]; then
  info "Config already exists at ${CONFIG_DIR}/config.yaml — not overwritten."
else
  if [[ -f "${SCRIPT_DIR}/config.yaml" ]]; then
    cp "${SCRIPT_DIR}/config.yaml" "${CONFIG_DIR}/config.yaml"
    info "Config installed to ${CONFIG_DIR}/config.yaml"
  else
    warn "No config.yaml found in project directory — using built-in defaults."
    hint "You can create one later at ${CONFIG_DIR}/config.yaml"
  fi
fi

# ── Install systemd service ──────────────────────────────────────────────────
step "Installing systemd service"

CURRENT_USER="$(whoami)"
VENV_PYTHON="${VENV_DIR}/bin/python"
SCRIPT_PATH="${SCRIPT_DIR}/${PYTHON_SCRIPT}"

# Generate service file from template values so paths are always correct,
# regardless of where the project is cloned or who runs it.
SERVICE_CONTENT="[Unit]
Description=OLED Stats Display
After=network.target

[Service]
ExecStart=${VENV_PYTHON} ${SCRIPT_PATH}
WorkingDirectory=${SCRIPT_DIR}
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=5
User=${CURRENT_USER}
TimeoutStopSec=5
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target"

# Check if service is already installed and identical
NEEDS_UPDATE=true
if [[ -f "${SERVICE_DEST}" ]]; then
  EXISTING="$(sudo cat "${SERVICE_DEST}")"
  if [[ "${EXISTING}" == "${SERVICE_CONTENT}" ]]; then
    info "Service file is up to date — no changes needed."
    NEEDS_UPDATE=false
  else
    warn "Service file has changed — updating."
  fi
fi

if [[ "${NEEDS_UPDATE}" == true ]]; then
  echo "${SERVICE_CONTENT}" | sudo tee "${SERVICE_DEST}" >/dev/null
  sudo systemctl daemon-reload
  info "Service file installed at ${SERVICE_DEST}"
fi

sudo systemctl enable "${SERVICE_NAME}" 2>/dev/null
info "Service enabled (starts on boot)."

# ── Start / Restart service ──────────────────────────────────────────────────
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  info "Restarting service..."
  sudo systemctl restart "${SERVICE_NAME}"
else
  info "Starting service..."
  sudo systemctl start "${SERVICE_NAME}"
fi

# Give it a moment to start (or fail)
sleep 2

if systemctl is-active --quiet "${SERVICE_NAME}"; then
  info "Service is running ✓"
else
  err "Service failed to start."
  hint "Check logs:  journalctl -u ${SERVICE_NAME} -n 20 --no-pager"
  exit 1
fi

# =============================================================================
# Done!
# =============================================================================
step "Installation complete 🎉"

echo ""
echo "  Config file:"
echo "    ${CONFIG_DIR}/config.yaml"
echo ""
echo "  Useful commands:"
echo "    systemctl status ${SERVICE_NAME}        — check service status"
echo "    journalctl -u ${SERVICE_NAME} -f        — follow live logs"
echo "    sudo systemctl restart ${SERVICE_NAME}  — restart after code changes"
echo "    ./$(basename "$0") --remove             — uninstall"
echo ""

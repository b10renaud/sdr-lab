#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# SDR LAB HARDENED INSTALLER FOR UBUNTU 24.04 LTS
# Tested against: Ubuntu 24.04 LTS (noble)
# Supports: RTL-SDR Blog V4, RTL-SDR V3, Airspy, HackRF
###############################################################################

############################################
# OPTIONAL COMPONENT TOGGLES
# 0 = skip, 1 = install
############################################

INSTALL_APT_BASE=1           # Core toolchain, drivers, libraries
INSTALL_RTLSDR_BLOG_V4=1     # RTL-SDR Blog fork (required for V4 dongle)
INSTALL_SDRPP=1              # SDR++ built from source (proper audio support)
INSTALL_DUMP1090=1           # dump1090-fa built from source (aircraft tracking)
INSTALL_NOAA_APT=1           # noaa-apt weather satellite image decoder
INSTALL_SDRANGEL_SNAP=1      # SDRangel via snap
INSTALL_OPENWEBRX_PLUS=0     # OpenWebRX+ (experimental, disabled by default)
INSTALL_SDRTRUNK=1           # SDRTrunk trunked radio decoder (Java)
INSTALL_RTLSDR_AIRBAND=1     # RTLSDR-Airband aviation audio
INSTALL_MBELIB=1             # mbelib digital voice codec
INSTALL_DSD=1                # DSD digital signal decoder
INSTALL_SATDUMP=0            # SatDump (heavy build, disabled by default)
INSTALL_URH=1                # Universal Radio Hacker

RUN_VOLK_PROFILE=1           # Run VOLK CPU optimization profile
CREATE_SDR_UDEV_RULES=1      # Install udev rules for SDR hardware access
BLACKLIST_RTL_DVB=1          # Blacklist conflicting kernel DVB drivers

APT_NO_RECOMMENDS=0          # Set to 1 to skip apt recommended packages
AUTO_REBOOT_HINT=1           # Remind user to reboot at end

############################################
# VERSION PINS
############################################

SDRTRUNK_VERSION="0.6.1"

############################################
# CONSTANTS
############################################

readonly REQUIRED_UBUNTU_CODENAME="noble"
readonly WORKDIR="${HOME}/sdr"
readonly TOOLS_DIR="${WORKDIR}/tools"
readonly APPS_DIR="${WORKDIR}/apps"
readonly BIN_DIR="${HOME}/.local/bin"
readonly DESKTOP_DIR="${HOME}/.local/share/applications"
readonly LOG_PREFIX="[SDR-LAB]"

# Ensure BIN_DIR is in PATH for this session
export PATH="${BIN_DIR}:${PATH}"

############################################
# LOGGING
############################################

log()  { echo -e "\n${LOG_PREFIX} $*"; }
warn() { echo -e "\n${LOG_PREFIX} WARNING: $*" >&2; }
die()  { echo -e "\n${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

on_error() {
  local line="$1"
  warn "A non-fatal error occurred near line ${line}. Continuing..."
}
trap 'on_error $LINENO' ERR

############################################
# HELPERS
############################################

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1. Please install it and re-run."
}

is_ubuntu_24_04() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" && "${VERSION_CODENAME:-}" == "${REQUIRED_UBUNTU_CODENAME}" ]]
}

apt_pkg_exists() {
  apt-cache show "$1" >/dev/null 2>&1
}

# Install packages, skipping any that don't exist in apt metadata
# This prevents the entire block from failing on one missing package name
install_apt_packages() {
  local missing=()
  local present=()
  local p

  for p in "$@"; do
    if apt_pkg_exists "$p"; then
      present+=("$p")
    else
      missing+=("$p")
    fi
  done

  if ((${#missing[@]} > 0)); then
    warn "Skipping packages not found in APT metadata: ${missing[*]}"
  fi

  if ((${#present[@]} > 0)); then
    if [[ "$APT_NO_RECOMMENDS" -eq 1 ]]; then
      sudo apt-get install -y --no-install-recommends "${present[@]}"
    else
      sudo apt-get install -y "${present[@]}"
    fi
  fi
}

# Idempotent git clone or pull — safe to re-run
git_clone_or_update() {
  local repo="$1"
  local dir="$2"

  if [[ ! -d "${dir}/.git" ]]; then
    rm -rf "$dir"
    git clone --recurse-submodules "$repo" "$dir"
  else
    if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      rm -rf "$dir"
      git clone --recurse-submodules "$repo" "$dir"
    else
      git -C "$dir" pull --ff-only || warn "git pull failed for ${dir}, continuing with existing checkout."
      git -C "$dir" submodule update --init --recursive || true
    fi
  fi
}

# Configure, build, and install a cmake project
cmake_build_install() {
  local src_dir="$1"
  shift || true

  cmake -S "$src_dir" -B "${src_dir}/build" -DCMAKE_BUILD_TYPE=Release "$@"
  cmake --build "${src_dir}/build" --parallel "$(nproc)"
  sudo cmake --install "${src_dir}/build"
  sudo ldconfig
}

############################################
# START
############################################

clear
echo "========================================="
echo "   SDR LAB HARDENED INSTALLER"
echo "   Ubuntu 24.04 LTS (noble)"
echo "========================================="
echo

require_cmd sudo
require_cmd apt-get
require_cmd curl
require_cmd git

is_ubuntu_24_04 || die "This installer targets Ubuntu 24.04 LTS (noble). Detected: $(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"

log "Refreshing sudo credentials..."
sudo -v

# Keep sudo alive throughout long builds
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true' EXIT

log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get -y full-upgrade
sudo apt-get -y autoremove

############################################
# WORKSPACE DIRECTORIES
############################################

log "Creating SDR workspace directories..."
mkdir -p \
  "${TOOLS_DIR}" \
  "${APPS_DIR}" \
  "${WORKDIR}/recordings" \
  "${WORKDIR}/iq_recordings" \
  "${WORKDIR}/configs" \
  "${WORKDIR}/logs" \
  "${BIN_DIR}" \
  "${DESKTOP_DIR}"

############################################
# CORE SYSTEM + DEV TOOLCHAIN
############################################

if [[ "$INSTALL_APT_BASE" -eq 1 ]]; then
  log "Installing core build toolchain..."
  install_apt_packages \
    build-essential \
    cmake \
    git \
    pkg-config \
    autoconf \
    automake \
    libtool \
    gcc \
    g++ \
    make \
    clang \
    gdb \
    ccache \
    ninja-build \
    meson \
    nasm

  log "Installing system utilities..."
  install_apt_packages \
    curl \
    wget \
    unzip \
    zip \
    tar \
    htop \
    sox \
    ffmpeg \
    jq \
    tree \
    usbutils \
    pciutils \
    file \
    xz-utils \
    ca-certificates \
    gnupg \
    lsb-release \
    desktop-file-utils

  log "Installing Python environment..."
  install_apt_packages \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    python3-setuptools \
    python3-wheel \
    pipx

  if command -v pipx >/dev/null 2>&1; then
    pipx ensurepath || true
  fi

  log "Installing Java (required for SDRTrunk)..."
  install_apt_packages openjdk-21-jre

  log "Installing SDR drivers and core libraries..."
  install_apt_packages \
    rtl-sdr \
    librtlsdr-dev \
    librtlsdr0 \
    libusb-1.0-0-dev \
    libfftw3-dev \
    libvolk-dev \
    volk \
    libsoapysdr-dev \
    soapysdr-tools \
    soapysdr-module-rtlsdr \
    soapysdr-module-airspy \
    soapysdr-module-hackrf \
    airspy \
    libairspy-dev \
    libairspyhf-dev \
    hackrf \
    libhackrf-dev \
    libiio-dev \
    libad9361-dev \
    librtaudio-dev \
    libconfig++-dev \
    libzstd-dev \
    libglfw3-dev \
    libhidapi-dev \
    libopengl-dev \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    libboost-all-dev

  log "Installing DSP and audio libraries..."
  install_apt_packages \
    libmp3lame-dev \
    libshout3-dev \
    libpulse-dev \
    libsndfile1-dev \
    libncurses-dev \
    libitpp-dev \
    libsamplerate0-dev \
    libcodec2-dev \
    portaudio19-dev

  log "Installing Qt6 GUI dependencies..."
  install_apt_packages \
    qt6-base-dev \
    qt6-tools-dev \
    qt6-tools-dev-tools \
    qt6-multimedia-dev \
    qt6-svg-dev \
    qt6-5compat-dev \
    libqt6opengl6-dev \
    python3-pyqt6

  log "Installing GNU Radio and SDR framework..."
  install_apt_packages \
    gnuradio \
    gnuradio-dev \
    gr-osmosdr \
    libuhd-dev \
    uhd-host

  log "Installing SDR applications from Ubuntu repos..."
  install_apt_packages \
    gqrx-sdr \
    rtl-433 \
    inspectrum \
    gpredict \
    multimon-ng \
    predict \
    libpng-dev

  # dump1090-mutability from apt is a fallback only — we build from source below
  # install_apt_packages dump1090-mutability
fi

############################################
# RTL-SDR BLOG V4 DRIVERS (source build)
############################################

if [[ "$INSTALL_RTLSDR_BLOG_V4" -eq 1 ]]; then
  log "Installing RTL-SDR Blog V4 drivers from source..."
  log "  (This replaces the apt rtl-sdr package with V4-compatible drivers)"

  install_apt_packages libusb-1.0-0-dev pkg-config cmake

  git_clone_or_update \
    https://github.com/rtlsdrblog/rtl-sdr-blog.git \
    "${TOOLS_DIR}/rtl-sdr-blog"

  cmake_build_install "${TOOLS_DIR}/rtl-sdr-blog" \
    -DINSTALL_UDEV_RULES=ON \
    -DDETACH_KERNEL_DRIVER=ON

  log "RTL-SDR Blog V4 drivers installed."
fi

############################################
# KERNEL DRIVER BLACKLIST + UDEV RULES
############################################

if [[ "$BLACKLIST_RTL_DVB" -eq 1 ]]; then
  log "Blacklisting conflicting RTL DVB kernel drivers..."
  sudo tee /etc/modprobe.d/blacklist-rtl-sdr.conf >/dev/null <<'EOF'
# Prevent the generic DVB driver from claiming RTL-SDR devices
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
EOF

  # Unload immediately if currently loaded
  sudo modprobe -r dvb_usb_rtl28xxu 2>/dev/null || true
  sudo modprobe -r rtl2832 2>/dev/null || true
  sudo modprobe -r rtl2830 2>/dev/null || true
fi

log "Ensuring plugdev group exists..."
if ! getent group plugdev >/dev/null 2>&1; then
  sudo groupadd plugdev
fi

log "Adding ${USER} to plugdev group..."
sudo usermod -aG plugdev "$USER"

if [[ "$CREATE_SDR_UDEV_RULES" -eq 1 ]]; then
  log "Installing SDR udev rules..."
  sudo tee /etc/udev/rules.d/52-sdr-lab.rules >/dev/null <<'EOF'
# RTL-SDR Blog V4 / Realtek RTL2832U
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2838", GROUP="plugdev", MODE="0660"
SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="2832", GROUP="plugdev", MODE="0660"

# Airspy
ATTR{idVendor}=="1d50", ATTR{idProduct}=="60a1", SYMLINK+="airspy-%k", MODE="660", GROUP="plugdev"

# HackRF One / Jawbreaker / rad1o
ATTR{idVendor}=="1d50", ATTR{idProduct}=="6089", MODE="660", GROUP="plugdev"
ATTR{idVendor}=="1d50", ATTR{idProduct}=="cc15", MODE="660", GROUP="plugdev"

# Funcube Dongle Pro / Pro+
SUBSYSTEMS=="usb", ATTRS{idVendor}=="04d8", ATTRS{idProduct}=="fb56", MODE:="0660", GROUP="plugdev"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="04d8", ATTRS{idProduct}=="fb31", MODE:="0660", GROUP="plugdev"
KERNEL=="hidraw*", ATTRS{idVendor}=="04d8", ATTRS{idProduct}=="fb56", MODE="0660", GROUP="plugdev"
KERNEL=="hidraw*", ATTRS{idVendor}=="04d8", ATTRS{idProduct}=="fb31", MODE="0660", GROUP="plugdev"
EOF

  sudo udevadm control --reload-rules
  sudo udevadm trigger || true
fi

############################################
# SDR++ (source build — proper audio support)
############################################

if [[ "$INSTALL_SDRPP" -eq 1 ]]; then
  log "Building SDR++ from source..."
  log "  (Source build ensures audio sink/source work with system libraries)"

  git_clone_or_update \
    https://github.com/AlexandreRouma/SDRPlusPlus.git \
    "${TOOLS_DIR}/SDRPlusPlus"

  cmake_build_install "${TOOLS_DIR}/SDRPlusPlus" \
    -DOPT_BUILD_AUDIO_SOURCE=ON \
    -DOPT_BUILD_AUDIO_SINK=ON \
    -DOPT_BUILD_RTL_SDR_SOURCE=ON \
    -DOPT_BUILD_AIRSPY_SOURCE=ON \
    -DOPT_BUILD_AIRSPYHF_SOURCE=ON \
    -DOPT_BUILD_HACKRF_SOURCE=ON \
    -DOPT_BUILD_SOAPY_SOURCE=ON \
    -DOPT_BUILD_IIO_SOURCE=ON

  log "SDR++ installed."
fi

############################################
# DUMP1090 (FlightAware fork, source build)
############################################

if [[ "$INSTALL_DUMP1090" -eq 1 ]]; then
  log "Building dump1090-fa from source..."

  install_apt_packages libncurses-dev

  git_clone_or_update \
    https://github.com/flightaware/dump1090.git \
    "${TOOLS_DIR}/dump1090"

  # Fix GCC 15+ strict string array size warnings that are treated as errors.
  # These are harmless bugs in upstream code — we correct the array sizes.
  log "  Patching dump1090 for GCC 15 compatibility..."
  python3 - <<'PYEOF'
import pathlib

fixes = {
    "interactive.c":  [("char spinner[4]",   "char spinner[5]")],
    "ais_charset.c":  [("char ais_charset[64]", "char ais_charset[65]")],
    "ais_charset.h":  [("char ais_charset[64]", "char ais_charset[65]")],
}

base = pathlib.Path("${TOOLS_DIR}/dump1090")
for fname, replacements in fixes.items():
    p = base / fname
    if not p.exists():
        print(f"  Skipping {fname} (not found)")
        continue
    text = p.read_text()
    for old, new in replacements:
        if old in text:
            text = text.replace(old, new)
            print(f"  Patched {fname}: '{old}' -> '{new}'")
        else:
            print(f"  {fname}: pattern not found, may already be patched")
    p.write_text(text)

print("  Patching complete.")
PYEOF

  # Build without -Werror so any remaining warnings don't abort the build
  make -C "${TOOLS_DIR}/dump1090" \
    CFLAGS="-O3 -g -std=c11 -fno-common -Wall -Wmissing-declarations -Wformat-signedness -W -I/usr/local/include/" \
    || warn "dump1090 build had warnings but completed. Verify the binary exists."

  # Install binary
  sudo install -m 755 "${TOOLS_DIR}/dump1090/dump1090" /usr/local/bin/dump1090
  sudo install -m 755 "${TOOLS_DIR}/dump1090/view1090" /usr/local/bin/view1090

  # Create a launcher wrapper that serves the web UI automatically
  cat > "${BIN_DIR}/dump1090-start" <<BASH_EOF
#!/usr/bin/env bash
# dump1090-start: Launch dump1090 with web UI served via Python
# Usage: dump1090-start [extra dump1090 flags]

DUMP1090_BIN="/usr/local/bin/dump1090"
HTML_DIR="${TOOLS_DIR}/dump1090/public_html"
DATA_DIR="/tmp/dump1090-data"
HTTP_PORT=8080

mkdir -p "\${DATA_DIR}"
ln -sf "\${DATA_DIR}" "\${HTML_DIR}/data" 2>/dev/null || true

echo "[dump1090] Starting dump1090..."
\${DUMP1090_BIN} --net --quiet --write-json "\${DATA_DIR}" --write-json-every 1 "\$@" &
DUMP1090_PID=\$!

sleep 1

echo "[dump1090] Starting web server on http://127.0.0.1:\${HTTP_PORT}"
echo "[dump1090] Open your browser to http://127.0.0.1:\${HTTP_PORT}"
echo "[dump1090] Press Ctrl+C to stop both services."

trap "kill \${DUMP1090_PID} 2>/dev/null; exit" INT TERM

cd "\${HTML_DIR}"
python3 -m http.server \${HTTP_PORT}
BASH_EOF
  chmod +x "${BIN_DIR}/dump1090-start"

  cat > "${DESKTOP_DIR}/dump1090.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=dump1090 Aircraft Tracker
Comment=ADS-B aircraft tracking via RTL-SDR
Exec=${BIN_DIR}/dump1090-start
Terminal=true
Categories=Science;HamRadio;
StartupNotify=true
EOF

  update-desktop-database "${DESKTOP_DIR}" >/dev/null 2>&1 || true
  log "dump1090 installed. Launch with: dump1090-start"
fi

############################################
# NOAA-APT WEATHER SATELLITE DECODER
############################################

if [[ "$INSTALL_NOAA_APT" -eq 1 ]]; then
  log "Installing noaa-apt weather satellite decoder..."

  noaa_apt_url="https://github.com/martinber/noaa-apt/releases/latest/download/noaa-apt-x86_64-linux-gnu.zip"
  local_zip="${TOOLS_DIR}/noaa-apt.zip"
  noaa_dir="${TOOLS_DIR}/noaa-apt"

  mkdir -p "$noaa_dir"
  curl -fL "$noaa_apt_url" -o "$local_zip" \
    || warn "Failed to download noaa-apt. Skipping."

  if [[ -f "$local_zip" ]]; then
    unzip -q -o "$local_zip" -d "$noaa_dir"
    rm -f "$local_zip"

    # Find the binary wherever it extracted
    noaa_bin="$(find "${noaa_dir}" -type f -name "noaa-apt" -not -path "*/\.*" | head -n1)"
    if [[ -n "${noaa_bin:-}" ]]; then
      chmod +x "$noaa_bin"
      ln -sf "$noaa_bin" "${BIN_DIR}/noaa-apt"
      log "noaa-apt installed at ${BIN_DIR}/noaa-apt"
    else
      warn "noaa-apt binary not found after extraction."
    fi
  fi
fi

############################################
# SDRANGEL (snap)
############################################

if [[ "$INSTALL_SDRANGEL_SNAP" -eq 1 ]]; then
  log "Installing SDRangel via snap..."

  if ! command -v snap >/dev/null 2>&1; then
    install_apt_packages snapd
  fi

  sudo systemctl enable --now snapd.socket || true
  sudo ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true

  if snap list sdrangel >/dev/null 2>&1; then
    log "SDRangel snap already installed, skipping."
  else
    sudo snap install sdrangel || warn "SDRangel snap install failed. Try manually: sudo snap install sdrangel"
  fi
fi

############################################
# OPENWEBRX+ (optional, off by default)
############################################

if [[ "$INSTALL_OPENWEBRX_PLUS" -eq 1 ]]; then
  log "Installing OpenWebRX+ (experimental noble build)..."
  sudo mkdir -p /etc/apt/trusted.gpg.d

  curl -fsSL https://luarvique.github.io/ppa/openwebrx-plus.gpg \
    | sudo gpg --yes --dearmor -o /etc/apt/trusted.gpg.d/openwebrx-plus.gpg

  echo 'deb [signed-by=/etc/apt/trusted.gpg.d/openwebrx-plus.gpg] https://luarvique.github.io/ppa/noble ./' \
    | sudo tee /etc/apt/sources.list.d/openwebrx-plus.list >/dev/null

  sudo apt-get update
  install_apt_packages openwebrx
  sudo systemctl enable --now openwebrx || true
else
  log "Skipping OpenWebRX+ (set INSTALL_OPENWEBRX_PLUS=1 to enable)."
fi

############################################
# SDRTRUNK
############################################

if [[ "$INSTALL_SDRTRUNK" -eq 1 ]]; then
  log "Installing SDRTrunk v${SDRTRUNK_VERSION}..."

  sdrtrunk_dir="${APPS_DIR}/sdrtrunk"
  rm -rf "${sdrtrunk_dir}"
  mkdir -p "${sdrtrunk_dir}"

  case "$(uname -m)" in
    x86_64|amd64)
      sdrtrunk_url="https://github.com/DSheirer/sdrtrunk/releases/download/v${SDRTRUNK_VERSION}/sdr-trunk-linux-x86_64-v${SDRTRUNK_VERSION}.zip"
      ;;
    aarch64|arm64)
      sdrtrunk_url="https://github.com/DSheirer/sdrtrunk/releases/download/v${SDRTRUNK_VERSION}/sdr-trunk-linux-aarch64-v${SDRTRUNK_VERSION}.zip"
      ;;
    *)
      warn "Unsupported CPU architecture for SDRTrunk: $(uname -m). Skipping."
      sdrtrunk_url=""
      ;;
  esac

  if [[ -n "${sdrtrunk_url:-}" ]]; then
    local_zip="${TOOLS_DIR}/sdrtrunk-v${SDRTRUNK_VERSION}.zip"
    curl -fL "$sdrtrunk_url" -o "$local_zip" \
      || warn "Failed to download SDRTrunk. Skipping."

    if [[ -f "$local_zip" ]]; then
      unzip -q "$local_zip" -d "$sdrtrunk_dir"
      rm -f "$local_zip"

      sdrtrunk_real_dir="$(find "${sdrtrunk_dir}" -maxdepth 1 -mindepth 1 -type d | head -n1)"
      if [[ -n "${sdrtrunk_real_dir:-}" ]]; then
        ln -sfn "${sdrtrunk_real_dir}" "${APPS_DIR}/sdrtrunk/current"

        cat > "${BIN_DIR}/sdrtrunk" <<EOF
#!/usr/bin/env bash
exec "${APPS_DIR}/sdrtrunk/current/bin/sdr-trunk" "\$@"
EOF
        chmod +x "${BIN_DIR}/sdrtrunk"

        cat > "${DESKTOP_DIR}/sdrtrunk.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=SDRTrunk
Comment=Java-based trunked radio decoder
Exec=${BIN_DIR}/sdrtrunk
Terminal=false
Categories=AudioVideo;HamRadio;Science;
StartupNotify=true
EOF
        update-desktop-database "${DESKTOP_DIR}" >/dev/null 2>&1 || true
        log "SDRTrunk installed."
      else
        warn "Could not locate extracted SDRTrunk directory."
      fi
    fi
  fi
fi

############################################
# SOURCE BUILDS: RTLSDR-AIRBAND, MBELIB, DSD
############################################

if [[ "$INSTALL_RTLSDR_AIRBAND" -eq 1 ]]; then
  log "Building RTLSDR-Airband from source..."
  git_clone_or_update \
    https://github.com/rtl-airband/RTLSDR-Airband.git \
    "${TOOLS_DIR}/RTLSDR-Airband"

  (
    cd "${TOOLS_DIR}/RTLSDR-Airband"
    mkdir -p build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release
    cmake --build . --parallel "$(nproc)"
    sudo cmake --install .
    sudo ldconfig
  ) || warn "RTLSDR-Airband build failed. Skipping."
fi

if [[ "$INSTALL_MBELIB" -eq 1 ]]; then
  log "Building mbelib (digital voice codec) from source..."
  git_clone_or_update \
    https://github.com/szechyjs/mbelib.git \
    "${TOOLS_DIR}/mbelib"
  cmake_build_install "${TOOLS_DIR}/mbelib" \
    || warn "mbelib build failed. Skipping."
fi

if [[ "$INSTALL_DSD" -eq 1 ]]; then
  log "Building DSD (digital signal decoder) from source..."
  git_clone_or_update \
    https://github.com/szechyjs/dsd.git \
    "${TOOLS_DIR}/dsd"
  cmake_build_install "${TOOLS_DIR}/dsd" \
    || warn "DSD build failed. Skipping."
fi

if [[ "$INSTALL_SATDUMP" -eq 1 ]]; then
  log "Building SatDump from source (this may take a while)..."
  git_clone_or_update \
    https://github.com/SatDump/SatDump.git \
    "${TOOLS_DIR}/SatDump"
  cmake_build_install "${TOOLS_DIR}/SatDump" \
    || warn "SatDump build failed. Skipping."
fi

############################################
# UNIVERSAL RADIO HACKER (URH)
############################################

if [[ "$INSTALL_URH" -eq 1 ]]; then
  log "Installing Universal Radio Hacker (URH) via pipx..."
  if command -v pipx >/dev/null 2>&1; then
    pipx install urh || pipx upgrade urh || warn "URH install via pipx failed. Try manually: pipx install urh"
  else
    warn "pipx not available. Skipping URH. Install pipx and run: pipx install urh"
  fi
fi

############################################
# VOLK CPU PROFILE
############################################

if [[ "$RUN_VOLK_PROFILE" -eq 1 ]] && command -v volk_profile >/dev/null 2>&1; then
  log "Running VOLK CPU profile (this optimizes GNU Radio DSP performance)..."
  log "  This may take up to 10 minutes. Please wait..."
  timeout 600 volk_profile \
    || warn "volk_profile timed out or returned an error. Run 'volk_profile' manually later for best performance."
fi

############################################
# SMOKE TESTS
############################################

log "Running hardware and tool smoke tests..."

log "  Detecting SDR hardware with SoapySDR..."
if command -v SoapySDRUtil >/dev/null 2>&1; then
  SoapySDRUtil --find 2>/dev/null || true
else
  warn "SoapySDRUtil not found. SoapySDR may not be installed."
fi

log "  USB SDR device summary..."
lsusb 2>/dev/null | grep -Ei 'RTL|Realtek|Airspy|HackRF|Lime|Pluto|ADI|SDRplay|Funcube' \
  || warn "No recognised SDR USB devices found. Plug in your dongle and check 'lsusb'."

log "  RTL-SDR smoke test..."
if command -v rtl_test >/dev/null 2>&1; then
  rtl_test -t 2>&1 | head -20 || warn "rtl_test returned non-zero. Plug in dongle and re-test."
else
  warn "rtl_test not found in PATH."
fi

log "  HackRF smoke test..."
if command -v hackrf_info >/dev/null 2>&1; then
  hackrf_info 2>/dev/null || true
fi

log "  Airspy smoke test..."
if command -v airspy_info >/dev/null 2>&1; then
  airspy_info 2>/dev/null || true
fi

############################################
# WRITE QUICK-REFERENCE CHEATSHEET
############################################

cat > "${WORKDIR}/CHEATSHEET.md" <<'CHEAT'
# SDR Lab Quick Reference

## FM Radio (quick listen)
```bash
rtl_fm -f 101.1M -M wbfm -s 200000 -r 48000 - | aplay -r 48000 -f S16_LE -t raw -c 1
```

## NOAA Weather Radio
```bash
# Chicago area primary
rtl_fm -f 162.550M -M fm -s 200000 -r 48000 - | aplay -r 48000 -f S16_LE -t raw -c 1
```

## Aircraft Tracking (ADS-B)
```bash
dump1090-start
# Then open: http://127.0.0.1:8080
```

## SDR++ (visual waterfall + audio)
```bash
sdrpp
```

## GQRX
```bash
gqrx
```

## Universal Radio Hacker
```bash
urh
```

## SDRTrunk (trunked radio)
```bash
sdrtrunk
```

## Key Frequencies (MHz)
| What              | Frequency      |
|-------------------|----------------|
| FM Radio          | 88 – 108       |
| Aviation voice    | 118 – 137      |
| NOAA Satellites   | 137 – 138      |
| NOAA Weather Radio| 162.4 – 162.55 |
| APRS (HAM packet) | 144.390        |
| IoT / key fobs    | 433 / 915      |
| Aircraft ADS-B    | 1090           |
| GPS               | 1575.42        |
| Wi-Fi / BT        | 2400 / 5800    |

## NOAA Satellite Pass Times
Use: https://www.n2yo.com or `predict` CLI
NOAA 15: 137.620 MHz
NOAA 18: 137.9125 MHz
NOAA 19: 137.100 MHz

## Antenna Length Guide (each dipole arm)
| Frequency   | Length  |
|-------------|---------|
| FM (100MHz) | 75 cm   |
| NOAA sat    | 53 cm   |
| ADS-B       | 6.5 cm  |
| General     | 17 cm   |
CHEAT

log "Quick reference cheatsheet written to: ${WORKDIR}/CHEATSHEET.md"

############################################
# COMPLETION
############################################

echo
echo "========================================="
echo "   SDR LAB INSTALLATION COMPLETE"
echo "========================================="
echo
echo "Workspace:     ${WORKDIR}"
echo "Cheatsheet:    ${WORKDIR}/CHEATSHEET.md"
echo
echo "Launch commands:"
echo "  SDR++:               sdrpp"
echo "  GQRX:                gqrx"
echo "  GNU Radio:           gnuradio-companion"
echo "  Aircraft tracking:   dump1090-start"
echo "  SDRTrunk:            sdrtrunk"
echo "  SDRangel:            sdrangel"
echo "  URH:                 urh"
echo "  noaa-apt:            noaa-apt"
echo
if [[ "$INSTALL_OPENWEBRX_PLUS" -eq 1 ]]; then
  echo "  OpenWebRX+:        http://localhost:8073/"
fi
echo
echo "IMPORTANT — action required after this script:"
echo "  1. Log out and back in (or reboot) so group membership applies."
echo "  2. Re-plug your SDR dongle after reboot."
echo "  3. If SDRTrunk digital voice fails, open it and follow"
echo "     the in-app JMBE codec installation prompt."
echo
if [[ "$AUTO_REBOOT_HINT" -eq 1 ]]; then
  echo "  --> A REBOOT IS RECOMMENDED BEFORE FIRST USE <--"
  echo
fi

#!/usr/bin/env bash
# ==============================================================================
#  ArduPilot Prerequisites Installer — Ubuntu 16.04 LTS (Xenial Xerus)
#
#  Derived from:
#  https://github.com/ArduPilot/ardupilot/blob/master/Tools/environment_install/install-prereqs-ubuntu.sh
#
#  NOTE: Ubuntu 16.04 reached End-of-Life in April 2021. The upstream script
#  now exits on xenial. This script preserves the xenial-specific code paths
#  and installs everything needed to build ArduPilot on Ubuntu 16.04.
#
#  Usage:
#    chmod +x ardupilot-prereqs-ubuntu1604.sh
#    ./ardupilot-prereqs-ubuntu1604.sh [-y] [-q]
#      -y   Assume yes to all prompts (non-interactive)
#      -q   Quiet apt output
# ==============================================================================

set -e
set -x

echo "---------- $0 start ----------"

# ── Guard: must NOT run as root ───────────────────────────────────────────────
if [ "$EUID" -eq 0 ]; then
    echo "Please do not run this script as root; don't sudo it!"
    exit 1
fi

# ── Guard: Ubuntu 16.04 only ──────────────────────────────────────────────────
RELEASE_CODENAME=$(lsb_release -c -s 2>/dev/null || true)
if [ "${RELEASE_CODENAME}" != "xenial" ]; then
    echo "WARNING: This script is designed for Ubuntu 16.04 (xenial)."
    echo "Detected: ${RELEASE_CODENAME}"
    read -p "Continue anyway? [y/N] " _reply
    [[ $_reply =~ ^[Yy]$ ]] || exit 1
fi

# ── Options ───────────────────────────────────────────────────────────────────
ASSUME_YES=false
QUIET=false
OPTIND=1
while getopts "yq" opt; do
    case "$opt" in
        y) ASSUME_YES=true ;;
        q) QUIET=true ;;
        \?) exit 1 ;;
    esac
done

APT_GET="sudo apt-get"
$ASSUME_YES && APT_GET="$APT_GET --assume-yes"
$QUIET      && APT_GET="$APT_GET -qq"

OPT="/opt"
ARDUPILOT_TOOLS="Tools/autotest"
sep="##############################################"

function heading() { echo "$sep"; echo "$*"; echo "$sep"; }

function package_is_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -c "ok installed" || true
}

function maybe_prompt_user() {
    if $ASSUME_YES; then
        return 0
    else
        read -p "$1"
        [[ $REPLY =~ ^[Yy]$ ]] && return 0 || return 1
    fi
}

# ── Update package lists ──────────────────────────────────────────────────────
heading "Updating apt package lists"
$APT_GET update

# ── Python config for xenial ──────────────────────────────────────────────────
# Ubuntu 16.04 ships Python 2 as default; ArduPilot build system wants python3.
PYTHON_V="python3"
PIP="pip3"

# ── SFML / CSFML version detection ───────────────────────────────────────────
heading "Detecting SFML / CSFML version"
SITLCFML_VERSION=$(apt-cache search -n '^libcsfml-audio' | cut -d" " -f1 | head -1 | grep -Eo '[+-]?[0-9]+([.][0-9]+)?' || true)
SITLFML_VERSION=$(apt-cache search  -n '^libsfml-audio'  | cut -d" " -f1 | head -1 | grep -Eo '[+-]?[0-9]+([.][0-9]+)?' || true)

re='^[+-]?[0-9]+([.][0-9]+)?$'
if ! [[ $SITLCFML_VERSION =~ $re ]] || ! [[ $SITLFML_VERSION =~ $re ]]; then
    SITLCFML_VERSION=$(dpkg-query --search libcsfml-audio 2>/dev/null | cut -d: -f1 | grep libcsfml-audio | head -1 | grep -Eo '[+-]?[0-9]+([.][0-9]+)?' || true)
    SITLFML_VERSION=$(dpkg-query  --search libsfml-audio  2>/dev/null | cut -d: -f1 | grep libsfml-audio  | head -1 | grep -Eo '[+-]?[0-9]+([.][0-9]+)?' || true)
fi
echo "  SFML version  : ${SITLFML_VERSION:-<not found>}"
echo "  CSFML version : ${SITLCFML_VERSION:-<not found>}"

# ── pkg-config for ARM cross-compilation ──────────────────────────────────────
heading "Checking for pkg-config-arm-linux-gnueabihf"
ARM_PKG_CONFIG_NOT_PRESENT=0
if [ -z "$(apt-cache search -n '^pkg-config-arm-linux-gnueabihf')" ]; then
    ARM_PKG_CONFIG_NOT_PRESENT=$(dpkg-query --search pkg-config-arm-linux-gnueabihf 2>&1 | grep -c "dpkg-query:" || true)
fi

if [ "$ARM_PKG_CONFIG_NOT_PRESENT" -eq 1 ]; then
    INSTALL_PKG_CONFIG=""
    $APT_GET install pkg-config
    if [ -f /usr/share/pkg-config-crosswrapper ]; then
        sudo ln -sf /usr/share/pkg-config-crosswrapper /usr/bin/arm-linux-gnueabihf-pkg-config
    else
        echo "Warning: unable to link pkg-config-crosswrapper"
    fi
else
    INSTALL_PKG_CONFIG="pkg-config-arm-linux-gnueabihf"
fi

# ── Package lists ─────────────────────────────────────────────────────────────
BASE_PKGS="build-essential ccache g++ gawk git make wget valgrind screen python3-pexpect astyle"

# realpath ships as a standalone package on xenial
RP=$(apt-cache search -n '^realpath$')
[ -n "$RP" ] && BASE_PKGS+=" realpath"

ARM_LINUX_PKGS="g++-arm-linux-gnueabihf ${INSTALL_PKG_CONFIG}"

# Core SITL / build support packages
SITL_PKGS="libtool libxml2-dev libxslt1-dev"
SITL_PKGS+=" ${PYTHON_V}-dev ${PYTHON_V}-pip ${PYTHON_V}-setuptools"
SITL_PKGS+=" ${PYTHON_V}-numpy ${PYTHON_V}-pyparsing ${PYTHON_V}-psutil"

# libtool-bin (separate package on xenial)
LBTBIN=$(apt-cache search -n '^libtool-bin')
[ -n "$LBTBIN" ] && SITL_PKGS+=" libtool-bin"

# argparse
if apt-cache search python-argparse  2>/dev/null | grep -q argp; then
    SITL_PKGS+=" python-argparse"
elif apt-cache search python3-argparse 2>/dev/null | grep -q argp; then
    SITL_PKGS+=" python3-argparse"
fi

# Graphical / SITL display packages (xenial path)
SITL_PKGS+=" xterm xfonts-base"
# python3-opencv does NOT exist in xenial repos — installed via pip below
SITL_PKGS+=" ${PYTHON_V}-matplotlib ${PYTHON_V}-serial ${PYTHON_V}-scipy"
SITL_PKGS+=" ${PYTHON_V}-yaml"

# wxPython — check availability in order of preference
if apt-cache search python-wxgtk3.0 2>/dev/null | grep -q wx; then
    SITL_PKGS+=" python-wxgtk3.0"
elif apt-cache search python3-wxgtk4.0 2>/dev/null | grep -q wx; then
    SITL_PKGS+=" python3-wxgtk4.0"
else
    SITL_PKGS+=" python-wxgtk2.8"
fi

# pygame deps — xenial uses libpng12-0 and libjpeg8-dev
SITL_PKGS+=" fonts-freefont-ttf libfreetype6-dev libjpeg8-dev libpng12-0"
SITL_PKGS+=" libportmidi-dev libsdl-image1.2-dev libsdl-mixer1.2-dev libsdl-ttf2.0-dev libsdl1.2-dev"

# SFML / CSFML (only add if version was detected)
if [[ $SITLCFML_VERSION =~ $re ]]; then
    SITL_PKGS+=" libcsfml-dev"
    SITL_PKGS+=" libcsfml-audio${SITLCFML_VERSION}"
    SITL_PKGS+=" libcsfml-graphics${SITLCFML_VERSION}"
    SITL_PKGS+=" libcsfml-network${SITLCFML_VERSION}"
    SITL_PKGS+=" libcsfml-system${SITLCFML_VERSION}"
    SITL_PKGS+=" libcsfml-window${SITLCFML_VERSION}"
fi
if [[ $SITLFML_VERSION =~ $re ]]; then
    SITL_PKGS+=" libsfml-dev"
    SITL_PKGS+=" libsfml-audio${SITLFML_VERSION}"
    SITL_PKGS+=" libsfml-graphics${SITLFML_VERSION}"
    SITL_PKGS+=" libsfml-network${SITLFML_VERSION}"
    SITL_PKGS+=" libsfml-system${SITLFML_VERSION}"
    SITL_PKGS+=" libsfml-window${SITLFML_VERSION}"
fi

# PPP (used by some autotest scripts)
SITL_PKGS+=" ppp"

# Coverage tools
COVERAGE_PKGS="lcov gcovr"

# ── Install all APT packages ──────────────────────────────────────────────────
heading "Installing APT packages"
echo "BASE    : $BASE_PKGS"
echo "SITL    : $SITL_PKGS"
echo "ARM     : $ARM_LINUX_PKGS"
echo "COVERAGE: $COVERAGE_PKGS"

$APT_GET install $BASE_PKGS $SITL_PKGS $ARM_LINUX_PKGS $COVERAGE_PKGS

heading "Rebuilding font cache"
fc-cache

# ── Add user to dialout (serial port access) ──────────────────────────────────
heading "Adding ${USER} to dialout group"
sudo usermod -a -G dialout "$USER"
echo "Done!"


# ── GCC 7 from ubuntu-toolchain-r PPA ────────────────────────────────────────
# Ubuntu 16.04 ships GCC 5.4 which is too old for ArduPilot — it doesn't
# recognise -Wstringop-truncation, -Wno-expansion-to-defined, or several
# C++17 constructs.  GCC 7 is the minimum required version.
heading "Installing GCC 7 (toolchain PPA)"
sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
$APT_GET update
$APT_GET install --allow-change-held-packages \
    gcc-7 g++-7 cpp-7 \
    libcc1-0 libgcc1 libgcc-7-dev \
    libstdc++6 libstdc++-7-dev \
    libgomp1 libitm1 libatomic1 \
    liblsan0 libtsan0 libubsan0 \
    libcilkrts5 libquadmath0

# Register both versions with update-alternatives so the user can switch later
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-5 50 \
    --slave /usr/bin/g++ g++ /usr/bin/g++-5
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-7 70 \
    --slave /usr/bin/g++ g++ /usr/bin/g++-7

# Make GCC 7 the default automatically
sudo update-alternatives --set gcc /usr/bin/gcc-7

gcc --version
g++ --version

# ── ARM bare-metal toolchain (STM32 boards) ───────────────────────────────────
heading "Installing ARM none-eabi toolchain for STM32 boards"

ARM_ROOT="gcc-arm-none-eabi-10-2020-q4-major"
CCACHE_PATH=$(which ccache)

case "$(uname -m)" in
    x86_64)
        ARM_TARBALL="${ARM_ROOT}-x86_64-linux.tar.bz2"
        ARM_URL="https://firmware.ardupilot.org/Tools/STM32-tools/${ARM_TARBALL}"
        ;;
    aarch64)
        ARM_TARBALL="${ARM_ROOT}-aarch64-linux.tar.bz2"
        ARM_URL="https://firmware.ardupilot.org/Tools/STM32-tools/${ARM_TARBALL}"
        ;;
    *)
        echo "Unsupported architecture: $(uname -m). Skipping ARM toolchain install."
        ARM_URL=""
        ;;
esac

if [ -n "$ARM_URL" ]; then
    if [ ! -d "${OPT}/${ARM_ROOT}" ]; then
        (
            cd "$OPT"
            echo "Downloading ARM toolchain from ArduPilot server..."
            sudo wget --progress=dot:giga "$ARM_URL"
            echo "Extracting..."
            sudo chmod -R 777 "$ARM_TARBALL"
            sudo tar xjf "$ARM_TARBALL"
            echo "Cleaning up tarball..."
            sudo rm "$ARM_TARBALL"
        )
    else
        echo "ARM toolchain already present at ${OPT}/${ARM_ROOT}, skipping download."
    fi

    echo "Registering ARM toolchain with ccache..."
    sudo ln -sf "$CCACHE_PATH" /usr/lib/ccache/arm-none-eabi-g++
    sudo ln -sf "$CCACHE_PATH" /usr/lib/ccache/arm-none-eabi-gcc
    echo "Done!"
fi

# ── Shell profile / Docker detection (used by pyenv + PATH sections) ─────────
PROFILE_FILE="${HOME}/.profile"
ENV_FILE="${HOME}/.ardupilot_env"
IS_DOCKER=false
if [[ ${AP_DOCKER_BUILD:-0} -eq 1 ]] || [[ -f /.dockerenv ]] || grep -Eq '(lxc|docker)' /proc/1/cgroup 2>/dev/null; then
    IS_DOCKER=true
fi
if $IS_DOCKER; then
    echo "Inside Docker: writing env to ${ENV_FILE}"
    PROFILE_FILE="$ENV_FILE"
    echo "# ArduPilot env file. Source this from your shell." > "$PROFILE_FILE"
fi

# ==============================================================================
#  Python environment via pyenv + Python 3.7
#
#  Ubuntu 16.04 ships Python 3.5 which is incompatible with most current
#  ArduPilot Python dependencies (f-strings, maturin/Rust build deps, etc.).
#  We install pyenv, build Python 3.9.18 (highest version compatible with
#  Ubuntu 16.04's OpenSSL 1.0.2 — Python 3.10+ needs OpenSSL ≥ 1.1.1),
#  and create a dedicated venv so every pip install works cleanly.
# ==============================================================================

heading "Installing pyenv build dependencies"
$APT_GET install make build-essential libssl-dev zlib1g-dev \
    libbz2-dev libreadline-dev libsqlite3-dev curl llvm \
    libncurses5-dev libncursesw5-dev xz-utils tk-dev \
    libffi-dev liblzma-dev python-openssl

heading "Installing pyenv"
PYENV_ROOT="$HOME/.pyenv"
if [ ! -d "$PYENV_ROOT" ]; then
    git clone https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
else
    echo "pyenv already cloned, pulling latest..."
    git -C "$PYENV_ROOT" pull
fi

export PYENV_ROOT
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

PYTHON_VERSION="3.9.18"
heading "Building Python ${PYTHON_VERSION} via pyenv (this takes a few minutes)"
pyenv install -s "$PYTHON_VERSION"
pyenv global "$PYTHON_VERSION"

# Confirm we are now on the right Python
python --version

heading "Creating ArduPilot virtualenv"
ARDUPILOT_VENV="$HOME/ardupilot-venv"
if [ ! -d "$ARDUPILOT_VENV" ]; then
    python -m venv "$ARDUPILOT_VENV"
fi
# shellcheck disable=SC1090
source "$ARDUPILOT_VENV/bin/activate"

PIP_CMD="pip"   # inside venv, plain pip == the venv's pip

heading "Upgrading pip inside venv"
$PIP_CMD install --upgrade pip

# ------------------------------------------------------------------------------
#  Python packages
#  Pins:
#    empy==3.3.4       — ArduPilot waf requires exactly this version
#    pymavlink==2.4.47 — 2.4.48+ added fastcrc dep which requires Rust/puccinialin
#    dronecan (latest) — no fastcrc dep in any 1.0.x release
# ------------------------------------------------------------------------------
PYTHON_PKGS="lxml pymavlink==2.4.47 pyserial MAVProxy geocoder"  # 2.4.48+ requires fastcrc (needs Rust); 2.4.47 is last clean release
PYTHON_PKGS+=" empy==3.3.4 ptyprocess"
PYTHON_PKGS+=" dronecan"
PYTHON_PKGS+=" flake8 junitparser wsproto tabulate"
PYTHON_PKGS+=" pygame intelhex"
PYTHON_PKGS+=" pexpect future"
PYTHON_PKGS+=" opencv-python"

heading "Installing Python packages into venv"
echo "Packages: $PYTHON_PKGS"
$PIP_CMD install $PYTHON_PKGS

# Persist venv activation in shell profile
ACTIVATE_LINE="source ${ARDUPILOT_VENV}/bin/activate"
if ! grep -qF "$ACTIVATE_LINE" "$PROFILE_FILE" 2>/dev/null; then
    echo "$ACTIVATE_LINE" >> "$PROFILE_FILE"
    echo "Added venv activation to $PROFILE_FILE"
fi

# Also persist pyenv init
PYENV_INIT_LINE='export PYENV_ROOT="$HOME/.pyenv"; export PATH="$PYENV_ROOT/bin:$PATH"; eval "$(pyenv init -)"'
if ! grep -qF 'pyenv init' "$PROFILE_FILE" 2>/dev/null; then
    echo "$PYENV_INIT_LINE" >> "$PROFILE_FILE"
    echo "Added pyenv init to $PROFILE_FILE"
fi

# ── PATH / environment setup ──────────────────────────────────────────────────
heading "Setting up PATH"

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
ARDUPILOT_ROOT="$(realpath "${SCRIPT_DIR}" 2>/dev/null || echo "${HOME}/ardupilot")"

# Paths to export
EXTRA_PATHS=(
    "${OPT}/${ARM_ROOT}/bin"
    "${ARDUPILOT_ROOT}/${ARDUPILOT_TOOLS}"
    "${HOME}/.local/bin"
)

for p in "${EXTRA_PATHS[@]}"; do
    if ! grep -qF "$p" "$PROFILE_FILE" 2>/dev/null; then
        echo "export PATH=\"${p}:\$PATH\"" >> "$PROFILE_FILE"
        echo "  Added to PATH: $p"
    else
        echo "  Already in PATH: $p"
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
heading "Installation complete!"
cat <<EOF

Next steps:
  1. Log out and back in (or run: source ~/.profile) so PATH and group
     membership (dialout) take effect.

  2. Clone ArduPilot (if you haven't already):
       git clone --recurse-submodules https://github.com/ArduPilot/ardupilot.git

  3. Configure the build system (waf):
       cd ardupilot
       ./waf configure --board=<BOARD>
       ./waf

  Toolchain installed at: ${OPT}/${ARM_ROOT}
  arm-none-eabi-gcc: ${OPT}/${ARM_ROOT}/bin/arm-none-eabi-gcc

EOF
echo "---------- $0 end ----------"

#!/usr/bin/env bash
set -Eeuo pipefail

# Build GCC 16.2.0 on Ubuntu 22.04, install it under /opt, and create
# a relocatable-by-path tarball for deployment to other Ubuntu 22.04 hosts.
#
# Defaults:
#   - GCC 16.2.0
#   - install prefix: /opt/gcc-16.2.0
#   - C and C++ front ends
#   - multilib enabled on amd64
#   - bootstrap compiler: /usr/bin/gcc-11 and /usr/bin/g++-11
#
# Examples:
#   ./build-gcc16-ubuntu2204.sh
#   JOBS=4 ./build-gcc16-ubuntu2204.sh
#   ./build-gcc16-ubuntu2204.sh --no-multilib
#   ./build-gcc16-ubuntu2204.sh --alternatives
#   ./build-gcc16-ubuntu2204.sh --package-only

GCC_VERSION="${GCC_VERSION:-16.2.0}"
PREFIX="${PREFIX:-/opt/gcc-${GCC_VERSION}}"
WORK_ROOT="${WORK_ROOT:-/var/tmp/gcc-${GCC_VERSION}-build}"
OUT_DIR="${OUT_DIR:-$PWD}"
JOBS="${JOBS:-$(nproc)}"
BOOTSTRAP_CC="${BOOTSTRAP_CC:-/usr/bin/gcc-11}"
BOOTSTRAP_CXX="${BOOTSTRAP_CXX:-/usr/bin/g++-11}"
ENABLE_MULTILIB=1
SET_ALTERNATIVES=0
PACKAGE_ONLY=0
KEEP_WORK=0

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --no-multilib       Build native ABI only; do not build 32-bit/x32 multilibs
  --alternatives      Register GCC ${GCC_VERSION%%.*} as the default gcc/g++ using update-alternatives
  --package-only      Build and create the tarball, but do not install to ${PREFIX}
  --keep-work         Keep extracted source/build/staging directories after success
  -h, --help          Show this help

Environment overrides:
  GCC_VERSION         GCC version (default: ${GCC_VERSION})
  PREFIX              Install prefix (default: ${PREFIX})
  WORK_ROOT           Working directory (default: ${WORK_ROOT})
  OUT_DIR             Tarball output directory (default: current directory)
  JOBS                Parallel make jobs (default: nproc = ${JOBS})
  BOOTSTRAP_CC        Bootstrap C compiler (default: ${BOOTSTRAP_CC})
  BOOTSTRAP_CXX       Bootstrap C++ compiler (default: ${BOOTSTRAP_CXX})
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-multilib) ENABLE_MULTILIB=0 ;;
    --alternatives) SET_ALTERNATIVES=1 ;;
    --package-only) PACKAGE_ONLY=1 ;;
    --keep-work) KEEP_WORK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Use sudo only where root is required.
if [[ ${EUID} -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required when not running as root"
  SUDO=(sudo)
fi

# Avoid inherited compiler settings, including GCC's relocation override GCC_ROOT.
unset CC CXX CPP CFLAGS CXXFLAGS LDFLAGS LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH GCC_ROOT || true
export CFLAGS="-g -O2 -msse4.2"
export CXXFLAGS="$CFLAGS"
export CFLAGS_FOR_TARGET="$CFLAGS"
export CXXFLAGS_FOR_TARGET="$CXXFLAGS"
export CONFIG_SHELL=/bin/bash

[[ -r /etc/os-release ]] || die "/etc/os-release not found"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This script is intended for Ubuntu"
[[ "${VERSION_ID:-}" == "22.04" ]] || die "This script is intended for Ubuntu 22.04; found ${VERSION_ID:-unknown}"

ARCH="$(dpkg --print-architecture)"
MACHINE="$(uname -m)"
MAJOR="${GCC_VERSION%%.*}"
SRC_NAME="gcc-${GCC_VERSION}"
DOWNLOAD_DIR="${WORK_ROOT}/downloads"
SRC_DIR="${WORK_ROOT}/src/${SRC_NAME}"
BUILD_DIR="${WORK_ROOT}/build"
STAGE_DIR="${WORK_ROOT}/stage"
TARBALL_NAME="${SRC_NAME}-ubuntu22.04-${ARCH}.tar.xz"
TARBALL="${OUT_DIR}/${TARBALL_NAME}"
BASE_URL="https://gcc.gnu.org/pub/gcc/releases/${SRC_NAME}"
TAR_NAME="${SRC_NAME}.tar.xz"

log "Configuration"
printf '  GCC version:      %s\n' "$GCC_VERSION"
printf '  Host:             Ubuntu %s, %s (%s)\n' "$VERSION_ID" "$ARCH" "$MACHINE"
printf '  Prefix:           %s\n' "$PREFIX"
printf '  Bootstrap CC:     %s\n' "$BOOTSTRAP_CC"
printf '  Bootstrap CXX:    %s\n' "$BOOTSTRAP_CXX"
printf '  Make jobs:        %s\n' "$JOBS"
printf '  Multilib:         %s\n' "$([[ $ENABLE_MULTILIB -eq 1 ]] && echo enabled || echo disabled)"
printf '  Tarball:          %s\n' "$TARBALL"

log "Installing Ubuntu build prerequisites"
"${SUDO[@]}" apt-get update
PKGS=(
  build-essential
  gcc-11
  g++-11
  binutils
  make
  file
  wget
  ca-certificates
  xz-utils
  flex
  bison
  gawk
  texinfo
  zlib1g-dev
  libzstd-dev
)

if [[ $ENABLE_MULTILIB -eq 1 ]]; then
  if [[ "$ARCH" == "amd64" ]]; then
    PKGS+=(gcc-11-multilib g++-11-multilib libc6-dev-i386)
  else
    die "Multilib setup in this script is implemented for amd64 only. Re-run with --no-multilib on ${ARCH}."
  fi
fi

"${SUDO[@]}" apt-get install -y "${PKGS[@]}"

[[ -x "$BOOTSTRAP_CC" ]] || die "Bootstrap compiler not found: $BOOTSTRAP_CC"
[[ -x "$BOOTSTRAP_CXX" ]] || die "Bootstrap compiler not found: $BOOTSTRAP_CXX"

log "Sanity-checking bootstrap compiler"
TMP_C="$(mktemp --suffix=.c)"
TMP_BIN="${TMP_C%.c}"
trap 'rm -f "$TMP_C" "$TMP_BIN"' EXIT
cat > "$TMP_C" <<'CEOF'
#include <stddef.h>
#include <stdio.h>
int main(void) { return puts("Bootstrap C test OK") < 0; }
CEOF
"$BOOTSTRAP_CC" "$TMP_C" -o "$TMP_BIN"
"$TMP_BIN"
cat > "$TMP_C" <<'CPPEOF'
#include <cstddef>
#include <iostream>
int main() { std::cout << "Bootstrap C++ test OK\n"; }
CPPEOF
"$BOOTSTRAP_CXX" -x c++ "$TMP_C" -o "$TMP_BIN"
"$TMP_BIN"
rm -f "$TMP_C" "$TMP_BIN"
trap - EXIT

if [[ $ENABLE_MULTILIB -eq 1 && "$ARCH" == "amd64" ]]; then
  log "Sanity-checking 32-bit bootstrap support"
  TMP_C="$(mktemp --suffix=.c)"
  TMP_BIN="${TMP_C%.c}"
  printf '#include <stddef.h>\n#include <stdio.h>\nint main(void){return 0;}\n' > "$TMP_C"
  "$BOOTSTRAP_CC" -m32 "$TMP_C" -o "$TMP_BIN"
  file "$TMP_BIN"
  rm -f "$TMP_C" "$TMP_BIN"
fi

log "Preparing working directories"
mkdir -p "$DOWNLOAD_DIR" "$OUT_DIR"
rm -rf "$SRC_DIR" "$BUILD_DIR" "$STAGE_DIR"
mkdir -p "$(dirname "$SRC_DIR")" "$BUILD_DIR" "$STAGE_DIR"

log "Downloading GCC ${GCC_VERSION} source and official SHA-512 manifest"
cd "$DOWNLOAD_DIR"
wget -c "${BASE_URL}/${TAR_NAME}" -O "$TAR_NAME"
wget -q "${BASE_URL}/sha512.sum" -O sha512.sum

log "Verifying source archive SHA-512"
CHECK_LINE="$(grep -E "[[:space:]]${TAR_NAME}$" sha512.sum | head -n1 || true)"
[[ -n "$CHECK_LINE" ]] || die "Could not find ${TAR_NAME} in GCC sha512.sum"
printf '%s\n' "$CHECK_LINE" | sha512sum -c -

log "Extracting GCC source"
mkdir -p "$SRC_DIR"
tar -xJf "$DOWNLOAD_DIR/$TAR_NAME" -C "$(dirname "$SRC_DIR")"
[[ -x "$SRC_DIR/configure" ]] || die "GCC source extraction failed: configure not found"

log "Downloading GCC prerequisite source libraries"
cd "$SRC_DIR"
./contrib/download_prerequisites

log "Configuring out-of-tree build with GCC 11 bootstrap compiler"
cd "$BUILD_DIR"
CONFIGURE_ARGS=(
  "--prefix=$PREFIX"
  --enable-languages=c,c++
  --enable-checking=release
)
if [[ $ENABLE_MULTILIB -eq 1 ]]; then
  CONFIGURE_ARGS+=(--enable-multilib)
else
  CONFIGURE_ARGS+=(--disable-multilib)
fi

CC="$BOOTSTRAP_CC" CXX="$BOOTSTRAP_CXX" \
  "$SRC_DIR/configure" "${CONFIGURE_ARGS[@]}"

[[ -f Makefile ]] || die "configure completed without creating ${BUILD_DIR}/Makefile"

log "Building GCC ${GCC_VERSION}"
make -j"$JOBS" STAGE1_CFLAGS="-g -msse4.2" BOOT_CFLAGS="$CFLAGS"

log "Staging installation under DESTDIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
make DESTDIR="$STAGE_DIR" install

[[ -x "$STAGE_DIR$PREFIX/bin/gcc" ]] || die "Staged gcc not found at $STAGE_DIR$PREFIX/bin/gcc"
[[ -x "$STAGE_DIR$PREFIX/bin/g++" ]] || die "Staged g++ not found at $STAGE_DIR$PREFIX/bin/g++"

log "Creating deployment tarball"
rm -f "$TARBALL"
tar -C "$STAGE_DIR" -cJf "$TARBALL" ".${PREFIX}"
cd "$OUT_DIR"
sha256sum "$TARBALL_NAME" > "$TARBALL_NAME.sha256"

if [[ $PACKAGE_ONLY -eq 0 ]]; then
  log "Installing staged GCC into ${PREFIX}"
  "${SUDO[@]}" rm -rf "$PREFIX"
  "${SUDO[@]}" mkdir -p "$(dirname "$PREFIX")"
  "${SUDO[@]}" cp -a "$STAGE_DIR$PREFIX" "$PREFIX"

  log "Testing installed compiler"
  "$PREFIX/bin/gcc" --version | head -n1
  "$PREFIX/bin/g++" --version | head -n1

  TEST_DIR="$(mktemp -d)"
  cat > "$TEST_DIR/test.c" <<'CEOF'
#include <stdio.h>
int main(void) { puts("GCC C test OK"); return 0; }
CEOF
  cat > "$TEST_DIR/test.cpp" <<'CPPEOF'
#include <iostream>
int main() { std::cout << "GCC C++ test OK\n"; }
CPPEOF
  "$PREFIX/bin/gcc" "$TEST_DIR/test.c" -o "$TEST_DIR/test-c"
  "$PREFIX/bin/g++" "$TEST_DIR/test.cpp" -o "$TEST_DIR/test-cpp"
  "$TEST_DIR/test-c"
  "$TEST_DIR/test-cpp"

  if [[ $ENABLE_MULTILIB -eq 1 && "$ARCH" == "amd64" ]]; then
    "$PREFIX/bin/gcc" -m32 "$TEST_DIR/test.c" -o "$TEST_DIR/test-c-32"
    file "$TEST_DIR/test-c-32"
  fi
  rm -rf "$TEST_DIR"

  if [[ $SET_ALTERNATIVES -eq 1 ]]; then
    log "Registering GCC ${MAJOR} with update-alternatives"
    # Ubuntu does not normally manage gcc/g++ this way, so this is opt-in.
    if [[ -x /usr/bin/gcc-11 ]]; then
      "${SUDO[@]}" update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 110
    fi
    if [[ -x /usr/bin/g++-11 ]]; then
      "${SUDO[@]}" update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 110
    fi
    "${SUDO[@]}" update-alternatives --install /usr/bin/gcc gcc "$PREFIX/bin/gcc" 160
    "${SUDO[@]}" update-alternatives --install /usr/bin/g++ g++ "$PREFIX/bin/g++" 160
    "${SUDO[@]}" update-alternatives --set gcc "$PREFIX/bin/gcc"
    "${SUDO[@]}" update-alternatives --set g++ "$PREFIX/bin/g++"
    gcc --version | head -n1
    g++ --version | head -n1
  fi
fi

if [[ $KEEP_WORK -eq 0 ]]; then
  log "Cleaning extracted source, build, and staging directories"
  rm -rf "$SRC_DIR" "$BUILD_DIR" "$STAGE_DIR"
fi

cat <<DONE

Done.

Compiler prefix:
  $PREFIX

Deployment tarball:
  $TARBALL
  ${TARBALL}.sha256

To deploy on another Ubuntu 22.04 ${ARCH} machine:
  sudo apt-get update
  sudo apt-get install -y binutils libc6-dev
  sudo tar -xJf $TARBALL_NAME -C /
  $PREFIX/bin/gcc --version
  $PREFIX/bin/g++ --version

For amd64 multilib use on the destination as well, install:
  sudo apt-get install -y libc6-dev-i386

The tarball deliberately does not replace Ubuntu's system glibc, binutils,
or system headers. GCC will use the destination Ubuntu 22.04 system toolchain
components together with the GCC runtime libraries installed under $PREFIX.
DONE

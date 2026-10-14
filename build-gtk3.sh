#!/usr/bin/env bash
set -Eeuo pipefail

# Build GTK 3.24.52 and its dependencies from upstream source releases.
# https://docs.gtk.org/gtk3/building.html
#   linux: Ubuntu 22.04 with /opt/gcc-16.2.0
#   mingw: MSYS2 MINGW64 or UCRT64 (64-bit native Windows MinGW build)
# Builds development headers/libraries as well as GTK runtime libraries.
# Host platform libraries (e.g. glibc/X11 on Linux) remain system dependencies.
# Optional integration: --no-wayland. Printing uses the file backend.

usage() {
  cat <<'HELP'
Usage: build-gtk3.sh linux|mingw [options]

  --package-only  Create the archive without keeping the installed SDK
  --keep-work     Keep the source, build, and staging directories
  --no-wayland    Disable Wayland backend (Linux only)
  -h, --help      Show this help

Variables:
  GTK_VERSION     Default 3.24.52
  GCC_ROOT        Linux GCC install, default /opt/gcc-16.2.0
  PREFIX          Install location, default /opt/gtk-3.24.52[-mingw64]
  WORK_ROOT       Intermediate build directory
  OUT_DIR         Output directory, default current directory
  JOBS            Ninja jobs, default 4

Dependencies are built and installed into PREFIX before GTK, following GTK's
build guide. System packages provide build tools and OS/graphics interfaces.
HELP
}

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
TARGET=$1
shift
PACKAGE_ONLY=0
KEEP_WORK=0
WAYLAND=1
for opt in "$@"; do
  case "$opt" in
    --package-only) PACKAGE_ONLY=1 ;;
    --keep-work) KEEP_WORK=1 ;;
    --no-wayland) WAYLAND=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $opt" >&2; exit 2 ;;
  esac
done

GTK_VERSION=${GTK_VERSION:-3.24.52}
JOBS=${JOBS:-4}
OUT_DIR=${OUT_DIR:-$PWD}
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd -P)

fail() { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"; }

case "$TARGET" in
  linux)
    [[ -f /etc/os-release ]] || fail 'Linux target needs Ubuntu 22.04'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 22.04 ]] || fail 'Requires Ubuntu 22.04'
    ARCH=$(dpkg --print-architecture)
    PLATFORM="ubuntu22.04"
    GCC_ROOT=${GCC_ROOT:-/opt/gcc-16.2.0}
    # GCC_ROOT selects this script's compiler, but must not relocate GCC's internals.
    export -n GCC_ROOT
    PREFIX=${PREFIX:-/opt/gtk-${GTK_VERSION}}
    [[ -x "$GCC_ROOT/bin/gcc" && -x "$GCC_ROOT/bin/g++" ]] || fail "Missing GCC toolchain under $GCC_ROOT"
    CC="$GCC_ROOT/bin/gcc"
    CXX="$GCC_ROOT/bin/g++"
    export CC CXX
    export LD_LIBRARY_PATH="$GCC_ROOT/lib64:$GCC_ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    sudo apt-get update
    sudo apt-get install -y \
      git ca-certificates curl xz-utils make ninja-build pkg-config \
      python3 python3-dev python3-venv python3-pip cmake bison flex gperf nasm \
      autoconf automake libtool gettext sassc \
      dbus libdbus-1-dev libxtst-dev \
      libx11-dev libxext-dev libxrender-dev libxrandr-dev \
      libxi-dev libxinerama-dev libxfixes-dev libxcursor-dev libxdamage-dev \
      libxcomposite-dev libxcb1-dev libxcb-shm0-dev libxcb-render0-dev libxcb-xkb-dev \
      libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev
    ;;
  mingw)
    [[ -n ${MSYSTEM:-} ]] || fail 'Launch this from an MSYS2 MinGW/UCRT shell'
    case "$MSYSTEM" in
      MINGW64) PKG_PREFIX=mingw-w64-x86_64; ARCH=x86_64; PLATFORM=mingw64 ;;
      UCRT64) PKG_PREFIX=mingw-w64-ucrt-x86_64; ARCH=x86_64; PLATFORM=ucrt64 ;;
      *) fail "Unsupported MSYSTEM: $MSYSTEM" ;;
    esac
    PREFIX=${PREFIX:-/opt/gtk-${GTK_VERSION}-${PLATFORM}}
    require pacman
    require cygpath
    pacman -S --needed --noconfirm \
      git ca-certificates curl tar xz make autoconf automake libtool bison flex gperf \
      "${PKG_PREFIX}-gcc" "${PKG_PREFIX}-meson" "${PKG_PREFIX}-ninja" \
      "${PKG_PREFIX}-pkgconf" "${PKG_PREFIX}-cmake" \
      "${PKG_PREFIX}-libiconv" "${PKG_PREFIX}-gettext" \
      "${PKG_PREFIX}-python" "${PKG_PREFIX}-python-mako" "${PKG_PREFIX}-python-setuptools" \
      "${PKG_PREFIX}-nasm" \
      "${PKG_PREFIX}-sassc"
    export CC=gcc CXX=g++
    # Native Windows Meson expects a Windows-absolute prefix, not an MSYS2 path.
    ;;
  *) fail 'Target must be linux or mingw' ;;
esac

[[ "$PREFIX" == /* ]] || fail 'PREFIX must be an absolute POSIX-style path'
[[ "$PREFIX" != *' '* ]] || fail 'PREFIX may not contain whitespace'
[[ "$PREFIX" != / ]] || fail 'Refusing to install to /'

WORK_ROOT=${WORK_ROOT:-"${OUT_DIR}/.gtk-${GTK_VERSION}-${PLATFORM}-${ARCH}-build"}
mkdir -p "$WORK_ROOT"
WORK_ROOT=$(cd "$WORK_ROOT" && pwd -P)
SOURCES_DIR="$WORK_ROOT/sources"
DOWNLOAD_DIR="$WORK_ROOT/downloads"
BUILD_DIR="$WORK_ROOT/build"
STAGE_DIR="$WORK_ROOT/stage"
TARBALL_NAME="gtk-${GTK_VERSION}-${PLATFORM}-${ARCH}.tar.xz"
mkdir -p "$DOWNLOAD_DIR"
[[ ! -e "$PREFIX" ]] || fail "PREFIX already exists: $PREFIX (remove/rename it first)"
if [[ "$TARGET" == linux && ! -w $(dirname "$PREFIX") ]]; then
  sudo install -d -o "$(id -u)" -g "$(id -g)" "$PREFIX"
else
  mkdir -p "$PREFIX"
fi

# Install Meson >= 1.5 on Ubuntu: Jammy's system Meson is too old.
if [[ "$TARGET" == linux ]]; then
  python3 -m venv "$WORK_ROOT/.venv"
  "$WORK_ROOT/.venv/bin/python" -m pip install --disable-pip-version-check 'meson>=1.5,<2' mako setuptools
  export PATH="$WORK_ROOT/.venv/bin:$PATH"
else
  export PATH="$PREFIX/bin:$PATH"
fi
require meson
require ninja
require git
require curl
require sha256sum

# Build dependencies into the same prefix GTK will use, as documented upstream.
# https://docs.gtk.org/gtk3/building.html
INSTALL_PREFIX=$PREFIX
if [[ "$TARGET" == mingw ]]; then
  INSTALL_PREFIX=$(cygpath -m "$PREFIX")
fi
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CPPFLAGS="-I$INSTALL_PREFIX/include${CPPFLAGS:+ $CPPFLAGS}"
export LDFLAGS="-L$INSTALL_PREFIX/lib${LDFLAGS:+ $LDFLAGS}"
export XDG_DATA_DIRS="$PREFIX/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export GI_TYPELIB_PATH="$PREFIX/lib/girepository-1.0${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
if [[ "$TARGET" == linux ]]; then
  export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

rm -rf "$SOURCES_DIR" "$BUILD_DIR" "$STAGE_DIR"
mkdir -p "$SOURCES_DIR" "$BUILD_DIR" "$STAGE_DIR"

fetch_source() {
  local name=$1 url=$2 expected=$3
  # Different projects can use the same GitHub tag archive filename.
  local archive="$DOWNLOAD_DIR/$name-${url##*/}"
  echo "==> Downloading $name"
  if [[ ! -f "$archive" ]]; then
    curl --fail --location --retry 5 --retry-all-errors --output "$archive.part" "$url"
    mv "$archive.part" "$archive"
  fi
  if [[ -n "$expected" ]]; then
    printf '%s  %s\n' "$expected" "$archive" | sha256sum --check
  fi
  mkdir -p "$SOURCES_DIR/$name"
  tar -xf "$archive" -C "$SOURCES_DIR/$name" --strip-components=1
}

fetch_gnome() {
  local name=$1 version=$2
  local base="https://download.gnome.org/sources/$name/${version%.*}"
  local archive="$name-$version.tar.xz" sums="$DOWNLOAD_DIR/$name-$version.sha256sum"
  curl --fail --location --retry 5 --retry-all-errors --output "$sums" "$base/$name-$version.sha256sum"
  local expected
  expected=$(awk -v archive="$archive" 'length($1)==64 && index($0, archive) {print $1; exit}' "$sums")
  [[ -n "$expected" ]] || fail "Missing upstream SHA-256 for $archive"
  fetch_source "$name" "$base/$archive" "$expected"
}

build_cmake() {
  local name=$1
  shift
  echo "==> Building and installing $name"
  cmake -S "$SOURCES_DIR/$name" -B "$BUILD_DIR/$name" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$INSTALL_PREFIX" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=ON "$@"
  cmake --build "$BUILD_DIR/$name" --parallel "$JOBS"
  cmake --install "$BUILD_DIR/$name"
}

build_meson() {
  local name=$1
  shift
  echo "==> Building and installing $name"
  meson setup "$BUILD_DIR/$name" "$SOURCES_DIR/$name" \
    --prefix="$INSTALL_PREFIX" --libdir=lib --buildtype=release \
    --default-library=shared --wrap-mode=nofallback "$@"
  meson compile -C "$BUILD_DIR/$name" -j "$JOBS"
  meson install -C "$BUILD_DIR/$name" --no-rebuild
}

# External support libraries precede GLib and the graphics/font stack.
fetch_source zlib https://zlib.net/fossils/zlib-1.3.1.tar.gz \
  9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
build_cmake zlib -DZLIB_BUILD_EXAMPLES=OFF
fetch_source libffi https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz \
  b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e
mkdir -p "$BUILD_DIR/libffi"
(
  cd "$BUILD_DIR/libffi"
  "$SOURCES_DIR/libffi/configure" --prefix="$PREFIX" --libdir="$PREFIX/lib" \
    --host="$("$CC" -dumpmachine)" --disable-static --enable-shared
  make -j "$JOBS"
  make install
)
fetch_source pcre2 https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2 \
  d34f02e113cf7193a1ebf2770d3ac527088d485d4e047ed10e5d217c6ef5de96
build_cmake pcre2 -DPCRE2_BUILD_TESTS=OFF -DPCRE2_BUILD_PCRE2GREP=OFF \
  -DPCRE2_SUPPORT_UNICODE=ON -DPCRE2_SUPPORT_JIT=ON

# GLib documents this two-pass bootstrap for GObject Introspection.
# https://docs.gtk.org/glib/building.html#dependencies
fetch_gnome glib 2.84.0
build_meson glib -Dintrospection=disabled -Dsysprof=disabled -Dselinux=disabled -Dlibmount=disabled \
  -Ddocumentation=false -Dman-pages=disabled -Dtests=false

fetch_source libpng https://github.com/pnggroup/libpng/archive/v1.6.49.tar.gz \
  e425762fdfb9bb30a5d2da29c0067570e96b5d41d79c659cf0dad861e9df738e
build_cmake libpng -DPNG_SHARED=ON -DPNG_STATIC=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
fetch_source libjpeg-turbo https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.1/libjpeg-turbo-3.1.1.tar.gz \
  aadc97ea91f6ef078b0ae3a62bba69e008d9a7db19b34e4ac973b19b71b4217c
build_cmake libjpeg-turbo -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DWITH_JPEG8=ON
fetch_source libtiff https://download.osgeo.org/libtiff/tiff-4.7.0.tar.xz \
  273a0a73b1f0bed640afee4a5df0337357ced5b53d3d5d1c405b936501f71017
build_cmake libtiff -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF \
  -Dzlib=ON -Djpeg=ON -Dlibdeflate=OFF -Dlzma=OFF -Dzstd=OFF -Dwebp=OFF -Dlerc=OFF
fetch_source freetype https://download.savannah.gnu.org/releases/freetype/freetype-2.13.2.tar.xz \
  12991c4e55c506dd7f9b765933e62fd2be2e06d421505d7950a132e4f1bb484d
build_cmake freetype -DFT_REQUIRE_ZLIB=ON -DFT_REQUIRE_PNG=ON \
  -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON
fetch_source expat https://github.com/libexpat/libexpat/releases/download/R_2_8_5/expat-2.8.5.tar.xz \
  1e727b8933ec51a77a9a9d9afcf8e688bce45d907c13e36ab7393fe36e703182
build_cmake expat -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF \
  -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF -DEXPAT_BUILD_PKGCONFIG=ON
fetch_source fontconfig https://gitlab.freedesktop.org/fontconfig/fontconfig/-/archive/2.15.0/fontconfig-2.15.0.tar.gz \
  cdebb4b805d33e9bdefcc0ef9743db638d2acb21139bbe1a6a85878d4c3e8c9e
build_meson fontconfig -Ddoc=disabled -Dtests=disabled -Dcache-build=disabled
fetch_source pixman https://gitlab.freedesktop.org/pixman/pixman/-/archive/pixman-0.43.4/pixman-pixman-0.43.4.tar.gz \
  2af0acd451e22ae9d86d3c8aa45fcc19e4cc33e86bec311e5328cc2171ff1720
build_meson pixman -Dtests=disabled -Ddemos=disabled -Dgtk=disabled
fetch_source cairo https://gitlab.freedesktop.org/cairo/cairo/-/archive/1.18.2/cairo-1.18.2.tar.gz \
  7bbfb469b89b1f60584b4f39a1366789b7625a5796905870e108b6c0e8ca8216
build_meson cairo -Dglib=enabled -Dfontconfig=enabled -Dfreetype=enabled \
  -Dpng=enabled -Dzlib=enabled -Dtests=disabled -Dgtk_doc=false

fetch_gnome gobject-introspection 1.84.0
build_meson gobject-introspection -Dtests=false -Ddoctool=disabled -Dgtk_doc=false
meson configure "$BUILD_DIR/glib" -Dintrospection=enabled
meson compile -C "$BUILD_DIR/glib" -j "$JOBS"
meson install -C "$BUILD_DIR/glib" --no-rebuild

fetch_source fribidi https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz \
  1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c
build_meson fribidi -Ddocs=false -Dtests=false
fetch_source harfbuzz https://github.com/harfbuzz/harfbuzz/releases/download/8.4.0/harfbuzz-8.4.0.tar.xz \
  af4ea73e25ab748c8c063b78c2f88e48833db9b2ac369e29bd115702e789755e
HARFBUZZ_OPTS=(-Dglib=enabled -Dgobject=enabled -Dfreetype=enabled -Dcairo=enabled
  -Dicu=disabled -Dintrospection=enabled -Ddocs=disabled -Dtests=disabled -Dutilities=disabled)
if [[ "$TARGET" == mingw ]]; then
  HARFBUZZ_OPTS+=(-Ddirectwrite=enabled -Dgdi=enabled)
fi
build_meson harfbuzz "${HARFBUZZ_OPTS[@]}"
fetch_gnome gdk-pixbuf 2.43.3
build_meson gdk-pixbuf -Dintrospection=enabled -Ddocumentation=false -Dman=false \
  -Dtests=false -Dinstalled_tests=false -Dpng=enabled -Djpeg=enabled -Dtiff=enabled \
  -Dgif=enabled -Dglycin=disabled -Dbuiltin_loaders=all
fetch_gnome pango 1.56.4
build_meson pango -Dintrospection=enabled -Ddocumentation=false -Dman-pages=false \
  -Dbuild-testsuite=false -Dbuild-examples=false -Dsysprof=disabled -Dlibthai=disabled -Dxft=disabled
fetch_source libepoxy https://github.com/anholt/libepoxy/archive/1.5.10.tar.gz \
  a7ced37f4102b745ac86d6a70a9da399cc139ff168ba6b8002b4d8d43c900c15
EPOXY_OPTS=(-Ddocs=false -Dtests=false)
if [[ "$TARGET" == mingw ]]; then
  EPOXY_OPTS+=(-Dx11=false -Dglx=no)
fi
build_meson libepoxy "${EPOXY_OPTS[@]}"

if [[ "$TARGET" == linux ]]; then
  fetch_source xkbcommon https://xkbcommon.org/download/libxkbcommon-1.7.0.tar.xz \
  65782f0a10a4b455af9c6baab7040e2f537520caa2ec2092805cdfd36863b247
  build_meson xkbcommon -Denable-docs=false -Denable-tools=false -Denable-xkbregistry=false \
    -Dxkb-config-root=/usr/share/X11/xkb -Dx-locale-root=/usr/share/X11/locale
  if [[ $WAYLAND -eq 1 ]]; then
    fetch_source wayland https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.24.0/downloads/wayland-1.24.0.tar.xz \
  82892487a01ad67b334eca83b54317a7c86a03a89cfadacfef5211f11a5d0536
    build_meson wayland -Ddocumentation=false -Dtests=false -Ddtd_validation=false
    fetch_source wayland-protocols https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/1.44/downloads/wayland-protocols-1.44.tar.xz \
  3df1107ecf8bfd6ee878aeca5d3b7afd81248a48031e14caf6ae01f14eebb50e
    build_meson wayland-protocols -Dtests=false
  fi
fi

# GTK3 needs ATK; Linux also uses the AT-SPI accessibility bridge.
fetch_gnome libxml2 2.14.6
build_cmake libxml2 -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_PROGRAMS=OFF \
  -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_ZLIB=OFF
fetch_gnome at-spi2-core 2.56.8
AT_SPI_OPTS=(-Dintrospection=enabled -Ddocs=false -Dgtk2_atk_adaptor=false -Duse_systemd=false)
if [[ "$TARGET" == linux ]]; then
  AT_SPI_OPTS+=(-Dx11=enabled)
else
  AT_SPI_OPTS+=(-Datk_only=true -Dx11=disabled)
fi
build_meson at-spi2-core "${AT_SPI_OPTS[@]}"

# GTK consumes the installed SDK dependencies; no automatic source fallbacks.
fetch_gnome gtk "$GTK_VERSION"
MESON_OPTS=(-Dintrospection=true -Dgtk_doc=false -Dman=false
  -Dtests=false -Dinstalled_tests=false -Ddemos=false -Dexamples=false
  -Dcloudproviders=false -Dprofiler=false -Dtracker3=false -Dcolord=no -Dprint_backends=file)
if [[ "$TARGET" == linux ]]; then
  MESON_OPTS+=(-Dx11_backend=true -Dbroadway_backend=true)
  if [[ $WAYLAND -eq 1 ]]; then
    MESON_OPTS+=(-Dwayland_backend=true)
  else
    MESON_OPTS+=(-Dwayland_backend=false)
  fi
else
  MESON_OPTS+=(-Dx11_backend=false -Dwayland_backend=false -Dwin32_backend=true)
fi
build_meson gtk "${MESON_OPTS[@]}"

# Stage the complete common prefix for the downloadable SDK.
mkdir -p "$STAGE_DIR$PREFIX"
cp -a "$PREFIX/." "$STAGE_DIR$PREFIX/"

SDK_DIR="$STAGE_DIR$PREFIX"
[[ -d "$SDK_DIR" ]] || fail 'Staged install directory is missing'
SDK_DEPS=(gtk+-3.0 gdk-3.0 atk libxml-2.0 gobject-introspection-1.0 glib-2.0 gdk-pixbuf-2.0 pango cairo harfbuzz epoxy
  fribidi libpng libjpeg libtiff-4 pixman-1 libpcre2-8 libffi zlib)
if [[ "$TARGET" == linux ]]; then
  SDK_DEPS+=(fontconfig freetype2 expat xkbcommon xkbcommon-x11 atspi-2 atk-bridge-2.0)
  if [[ $WAYLAND -eq 1 ]]; then
    SDK_DEPS+=(wayland-client wayland-egl wayland-protocols)
  fi
fi
for dep in "${SDK_DEPS[@]}"; do
  find "$SDK_DIR" -name "${dep}.pc" -print -quit | grep -q . || fail "Missing source-built dependency in SDK: $dep"
done

# Copy the remaining MinGW DLL closure, including the GCC and gettext runtimes.
if [[ "$TARGET" == mingw ]]; then
  require objdump
  mkdir -p "$SDK_DIR/bin"
  mapfile -d '' -t PE_FILES < <(find "$SDK_DIR" -type f \( -iname '*.exe' -o -iname '*.dll' \) -print0)
  index=0
  while (( index < ${#PE_FILES[@]} )); do
    binary=${PE_FILES[index]}
    index=$((index+1))
    while IFS= read -r dll; do
      [[ -n "$dll" ]] || continue
      if find "$SDK_DIR/bin" -maxdepth 1 -iname "$dll" -print -quit | grep -q .; then
        continue
      fi
      candidate=$(find "$MINGW_PREFIX/bin" -maxdepth 1 -iname "$dll" -print -quit)
      [[ -n "$candidate" ]] || continue  # Windows system DLLs aren't redistributed.
      cp -a "$candidate" "$SDK_DIR/bin/"
      PE_FILES+=("$SDK_DIR/bin/${candidate##*/}")
    done < <(objdump -p "$binary" 2>/dev/null | awk '/DLL Name:/ {print $3}')
  done
  # Icons and application schemas are runtime assets, not shared libraries.
  for icon_theme in hicolor Adwaita; do
    if [[ -d "$MINGW_PREFIX/share/icons/$icon_theme" ]]; then
      mkdir -p "$SDK_DIR/share/icons"
      cp -a "$MINGW_PREFIX/share/icons/$icon_theme" "$SDK_DIR/share/icons/"
    fi
  done
  if [[ $PACKAGE_ONLY -eq 0 ]]; then
    cp -a "$SDK_DIR/bin/." "$PREFIX/bin/"
  fi
fi

# Activation for SDK consumers (especially necessary on Linux for the local .so's).
cat > "$SDK_DIR/activate.sh" <<'ACTIVATE'
#!/usr/bin/env bash
GTK3_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export PATH="$GTK3_HOME/bin:$PATH"
export PKG_CONFIG_PATH="$GTK3_HOME/lib/pkgconfig:$GTK3_HOME/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export GI_TYPELIB_PATH="$GTK3_HOME/lib/girepository-1.0${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
export XDG_DATA_DIRS="$GTK3_HOME/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
if [[ -z ${MSYSTEM:-} ]]; then
  export LD_LIBRARY_PATH="$GTK3_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
ACTIVATE
chmod +x "$SDK_DIR/activate.sh"
cp -a "$SDK_DIR/activate.sh" "$PREFIX/activate.sh"

# Verify development metadata and the compiled library without opening a GUI.
# shellcheck disable=SC1090
source "$PREFIX/activate.sh"
[[ "$(pkg-config --modversion gtk+-3.0)" == "$GTK_VERSION" ]] || fail 'Installed GTK pkg-config version differs'
[[ -s "$SDK_DIR/share/gir-1.0/Gdk-3.0.gir" ]] || fail 'Missing GDK introspection source'
[[ -s "$SDK_DIR/lib/girepository-1.0/Gdk-3.0.typelib" ]] || fail 'Missing GDK introspection typelib'
[[ -s "$SDK_DIR/share/gir-1.0/Gtk-3.0.gir" ]] || fail 'Missing GTK introspection source'
[[ -s "$SDK_DIR/lib/girepository-1.0/Gtk-3.0.typelib" ]] || fail 'Missing GTK introspection typelib'
cat > "$WORK_ROOT/gtk-smoke.c" <<'SMOKE'
#include <gtk/gtk.h>
int main(void) { return gtk_get_major_version() == 3 ? 0 : 1; }
SMOKE
SMOKE_EXE="$WORK_ROOT/gtk-smoke"
if [[ "$TARGET" == mingw ]]; then SMOKE_EXE+=".exe"; fi
# Intentional splitting of pkg-config's compiler/linker flags.
# shellcheck disable=SC2046
"$CC" "$WORK_ROOT/gtk-smoke.c" $(pkg-config --cflags --libs gtk+-3.0) -o "$SMOKE_EXE"
"$SMOKE_EXE"

# The archive and its .sha256 contain no absolute filenames.
cd "$OUT_DIR"
tar -C "$STAGE_DIR" -cJf "$TARBALL_NAME" "${PREFIX#/}"
sha256sum "$TARBALL_NAME" > "$TARBALL_NAME.sha256"
if [[ $PACKAGE_ONLY -eq 1 ]]; then
  if [[ "$TARGET" == linux && ! -w $(dirname "$PREFIX") ]]; then
    sudo rm -rf -- "$PREFIX"
  else
    rm -rf -- "$PREFIX"
  fi
fi
if [[ $KEEP_WORK -eq 0 ]]; then
  rm -rf "$SOURCES_DIR" "$BUILD_DIR" "$STAGE_DIR"
fi

echo "$OUT_DIR/$TARBALL_NAME"
echo "$OUT_DIR/$TARBALL_NAME.sha256"

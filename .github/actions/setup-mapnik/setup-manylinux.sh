#!/usr/bin/env bash
set -euo pipefail

BOOST_VER=1.83.0
BOOST_VER_UNDERSCORE=1_83_0
PROJ_VER=9.7.1
GDAL_VER=3.12.1
HARFBUZZ_VER=12.3.0
MAPNIK_VER=4.2.0

log() {
  echo ">> $*"
}

has_pkg_config() {
  pkg-config --exists "$1" 2>/dev/null
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

has_pkg_config_version() {
  local name="$1"
  local min_version="$2"
  local version
  version="$(pkg-config --modversion "$name" 2>/dev/null || true)"
  [ -n "$version" ] && version_ge "$version" "$min_version"
}

find_mapnik_pc() {
  log "libmapnik.pc locations (if any):"
  find /usr /opt /usr/local -name "libmapnik.pc" -print 2>/dev/null || true
}

install_with_apt() {
  mkdir -p /etc/apt/sources.list.d /etc/apt/preferences.d
  echo "deb http://deb.debian.org/debian sid main" >> /etc/apt/sources.list.d/sid.list
  echo 'Package: *
  Pin: release a=sid
  Pin-Priority: 100' > /etc/apt/preferences.d/sid
  apt-get update
  # Install base build dependencies including OpenSSL and Boost
  apt-get install -y \
    build-essential \
    pkg-config \
    libbz2-dev \
    libssl-dev \
    libboost-dev \
    libboost-filesystem-dev \
    libboost-program-options-dev \
    libboost-regex-dev \
    libboost-system-dev
  # Install Mapnik from sid (this will pull in most other dependencies)
  apt-get install -y -t sid libmapnik-dev
}

detect_dnf() {
  if command -v dnf >/dev/null 2>&1; then
    echo "dnf"
    return
  fi
  if command -v yum >/dev/null 2>&1; then
    echo "yum"
    return
  fi
  return 1
}

prepare_dnf() {
  local dnf_bin="$1"
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y dnf-plugins-core
    # Enable repo variants across EL8/EL9.
    dnf config-manager --set-enabled powertools || true
    dnf config-manager --set-enabled crb || true
  else
    yum install -y yum-utils || true
  fi
  "$dnf_bin" install -y epel-release || true
}

install_base_deps_dnf() {
  local dnf_bin="$1"
  "$dnf_bin" install -y \
    bzip2-devel \
    gcc gcc-c++ make \
    pkgconfig \
    openssl-devel
}

install_build_deps_dnf() {
  local dnf_bin="$1"
  "$dnf_bin" install -y \
    boost-devel \
    freetype-devel \
    libpng-devel \
    libjpeg-turbo-devel \
    libtiff-devel \
    libicu-devel \
    zlib-devel \
    libxml2-devel \
    proj-devel \
    geos-devel \
    gdal-devel \
    harfbuzz-devel \
    cairo-devel \
    libcurl-devel \
    sqlite-devel \
    json-c-devel \
    libgeotiff-devel \
    git \
    curl \
    wget \
    tar \
    cmake \
    xz
  # Optional deps for more Mapnik features; ignore if not available on EL8.
  "$dnf_bin" install -y zstd-devel || true
  "$dnf_bin" install -y libwebp-devel || true
  "$dnf_bin" install -y libavif-devel || true
  "$dnf_bin" install -y postgresql-devel || true
  "$dnf_bin" install -y expat-devel || true
  "$dnf_bin" install -y libqb3-devel || true
  "$dnf_bin" install -y glibc-gconv-extra || true
}

python_for_build() {
  ls -d /opt/python/cp312-cp312/bin/python /opt/python/cp3*/bin/python | head -1
}

build_boost() {
  log "Building Boost ${BOOST_VER}"
  local workdir="/tmp/boost-src"
  rm -rf "$workdir"
  mkdir -p "$workdir"
  cd "$workdir"
  local tarball="boost_${BOOST_VER_UNDERSCORE}.tar.bz2"
  curl -L -o "$tarball" "https://archives.boost.io/release/${BOOST_VER}/source/boost_${BOOST_VER_UNDERSCORE}.tar.bz2"
  tar -xjf "$tarball"
  cd "boost_${BOOST_VER_UNDERSCORE}"
  ./bootstrap.sh --prefix=/usr/local --with-libraries=regex,program_options,system,filesystem,thread,url,context
  if ! ./b2 -d0 --abbreviate-paths -j"$(nproc)" link=shared runtime-link=shared install > /tmp/boost-build.log 2>&1; then
    echo "Boost build failed. Last 200 lines:"
    tail -200 /tmp/boost-build.log
    exit 1
  fi
  ldconfig
  export LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib64:${LD_LIBRARY_PATH:-}"
}

build_proj() {
  log "Building PROJ ${PROJ_VER}"
  rm -rf /tmp/proj-src
  git -c advice.detachedHead=false clone --depth 1 --branch "${PROJ_VER}" https://github.com/OSGeo/PROJ.git /tmp/proj-src
  mkdir -p /tmp/proj-src/build
  cd /tmp/proj-src/build
  if ! {
    cmake /tmp/proj-src \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_C_FLAGS="-fPIC" \
      -DCMAKE_CXX_FLAGS="-Wno-psabi -fPIC" \
      -DBUILD_SHARED_LIBS=ON \
      -DBUILD_TESTING=OFF \
      -DENABLE_TIFF=OFF \
      --log-level=WARNING
    make -s -j"$(nproc)"
    make -s install
  } > /tmp/proj-build.log 2>&1; then
    echo "PROJ build failed. Last 200 lines:"
    tail -200 /tmp/proj-build.log
    exit 1
  fi
  ldconfig
}

build_harfbuzz() {
  log "Building HarfBuzz ${HARFBUZZ_VER}"
  local workdir="/tmp/harfbuzz-src"
  rm -rf "$workdir"
  mkdir -p "$workdir"
  cd "$workdir"
  local tarball="harfbuzz-${HARFBUZZ_VER}.tar.xz"
  curl -L -o "$tarball" "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VER}/harfbuzz-${HARFBUZZ_VER}.tar.xz"
  tar -xJf "$tarball"
  cd "harfbuzz-${HARFBUZZ_VER}"
  mkdir -p build
  cd build
  if ! {
    cmake .. \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_C_FLAGS="-fPIC" \
      -DCMAKE_CXX_FLAGS="-fPIC" \
      -DBUILD_SHARED_LIBS=ON \
      -DHB_HAVE_FREETYPE=ON \
      -DHB_BUILD_TESTS=OFF \
      -DHB_BUILD_UTILS=OFF \
      -DHB_BUILD_SUBSET=OFF \
      --log-level=WARNING
    make -s -j"$(nproc)"
    make -s install
  } > /tmp/harfbuzz-build.log 2>&1; then
    echo "HarfBuzz build failed. Last 200 lines:"
    tail -200 /tmp/harfbuzz-build.log
    exit 1
  fi
  ldconfig
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:${PKG_CONFIG_PATH:-}"
}

build_gdal() {
  log "Building GDAL ${GDAL_VER}"
  rm -rf /tmp/gdal-src
  git -c advice.detachedHead=false clone --depth 1 --branch "v${GDAL_VER}" https://github.com/OSGeo/gdal.git /tmp/gdal-src
  cd /tmp/gdal-src
  git -c advice.detachedHead=false submodule update --init --recursive
  mkdir -p /tmp/gdal-src/build
  cd /tmp/gdal-src/build
  local use_geos=OFF
  local geos_dir=""
  local use_zstd=OFF
  local use_geotiff=OFF
  local use_jsonc=OFF
  if command -v geos-config >/dev/null 2>&1 && has_pkg_config geos; then
    use_geos=ON
    geos_dir="$(geos-config --prefix)"
  fi
  if has_pkg_config libzstd || has_pkg_config zstd; then
    use_zstd=ON
  fi
  if has_pkg_config geotiff; then
    use_geotiff=ON
  fi
  if has_pkg_config json-c; then
    use_jsonc=ON
  fi
  if ! {
    cmake /tmp/gdal-src \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_C_FLAGS="-fPIC" \
      -DCMAKE_CXX_FLAGS="-Wno-psabi -fPIC" \
      -DBUILD_SHARED_LIBS=ON \
      -DBUILD_TESTING=OFF \
      -DBUILD_PYTHON_BINDINGS=OFF \
      -DGDAL_BUILD_PYTHON_BINDINGS=OFF \
      -DGDAL_ENABLE_PYTHON=OFF \
      -DGDAL_USE_INTERNAL_LIBS=ON \
      -DGDAL_USE_GEOS="${use_geos}" \
      -DGEOS_DIR="${geos_dir}" \
      -DGDAL_USE_PROJ=ON \
      -DGDAL_USE_ZSTD="${use_zstd}" \
      -DGDAL_USE_GEOTIFF="${use_geotiff}" \
      -DGDAL_USE_JSONC="${use_jsonc}" \
      --log-level=WARNING
    make -s -j"$(nproc)"
    make -s install
  } > /tmp/gdal-build.log 2>&1; then
    echo "GDAL build failed. Last 200 lines:"
    tail -200 /tmp/gdal-build.log
    exit 1
  fi
  ldconfig
}

build_mapnik() {
  local pybin="$1"
  log "Building Mapnik ${MAPNIK_VER}"
  rm -rf /tmp/mapnik-src
  git clone --depth 1 --branch "v${MAPNIK_VER}" https://github.com/mapnik/mapnik.git /tmp/mapnik-src
  cd /tmp/mapnik-src
  git -c advice.detachedHead=false submodule update --init --recursive
  mkdir -p /tmp/mapnik-src/build
  cd /tmp/mapnik-src/build
  local use_harfbuzz=OFF
  if has_pkg_config_version harfbuzz 8.3.0; then
    use_harfbuzz=ON
  fi
  if ! {
    cmake /tmp/mapnik-src \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DBUILD_DEMO_VIEWER=OFF \
      -DBUILD_TESTING=OFF \
      -DCMAKE_CXX_FLAGS="-Wno-psabi" \
      -DWITH_JPEG=ON \
      -DWITH_PNG=ON \
      -DWITH_TIFF=ON \
      -DWITH_WEBP=ON \
      -DWITH_AVIF=ON \
      -DWITH_PROJ=ON \
      -DWITH_GDAL=ON \
      -DWITH_CAIRO=ON \
      -DWITH_HARFBUZZ="${use_harfbuzz}" \
      -DWITH_FREETYPE=ON \
      -DWITH_SQLITE=ON \
      -DWITH_POSTGRESQL=ON \
      --log-level=WARNING
    make -s -j"$(nproc)"
    make -s install
  } > /tmp/mapnik-build.log 2>&1; then
    echo "Mapnik build failed. Last 200 lines:"
    tail -200 /tmp/mapnik-build.log
    exit 1
  fi
  ldconfig
  cd /
}

build_mapnik_from_source() {
  local dnf_bin="$1"
  log "mapnik-devel not available in enabled repos; building Mapnik from source."
  "$dnf_bin" repolist || true
  "$dnf_bin" list available "mapnik*" || true
  install_build_deps_dnf "$dnf_bin"

  local pybin
  pybin="$(python_for_build)"
  "$pybin" -m pip install --upgrade pip
  "$pybin" -m pip install scons

  build_boost
  build_proj
  if ! has_pkg_config_version harfbuzz 8.3.0; then
    build_harfbuzz
  fi
  build_gdal
  build_mapnik "$pybin"
}

if command -v apt-get >/dev/null 2>&1; then
  log "Using apt-get for Mapnik dependencies."
  install_with_apt
elif dnf_bin="$(detect_dnf)"; then
  log "Using ${dnf_bin} for Mapnik dependencies."
  prepare_dnf "$dnf_bin"
  install_base_deps_dnf "$dnf_bin"
  if ! "$dnf_bin" install -y mapnik-devel; then
    build_mapnik_from_source "$dnf_bin"
  fi
else
  echo "No supported package manager found (apt-get or dnf/yum)." >&2
  exit 1
fi

find_mapnik_pc

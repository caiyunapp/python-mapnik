# Build Configuration Guide

This document explains how the build system handles different platforms and how to customize the build if needed.

## Automatic Platform Detection

The `setup.py` automatically detects your platform and configures the build accordingly:

### macOS (Homebrew)

On macOS, the build system automatically:
1. Sets `PKG_CONFIG_PATH` to include ICU and Mapnik pkg-config files
2. Adds Boost include and library paths from Homebrew
3. Fixes HarfBuzz include path issues (Mapnik expects `<harfbuzz/hb.h>`)

**Requirements:**
- macOS 11.0 (Big Sur) or later
- Homebrew package manager (for building from source)

```bash
brew install mapnik boost icu4c
```

**Important Notes:**
- Built wheels target macOS 11.0+ due to modern Homebrew library requirements
- Pre-built wheels **bundle all dependencies** (including Mapnik) for standalone use
- Wheel size is ~200-300MB due to bundled libraries, but no system dependencies required
- For building from source, Homebrew Mapnik installation is required

### Linux (System Packages)

On Linux, the build system uses standard system paths. Dependencies should be installed via your package manager:

**Debian/Ubuntu:**
```bash
apt-get update
apt-get install -y \
    build-essential \
    pkg-config \
    libmapnik-dev \
    libboost-dev \
    libboost-filesystem-dev \
    libboost-program-options-dev \
    libboost-regex-dev \
    libboost-system-dev \
    libbz2-dev \
    libssl-dev
```

Note: `libmapnik-dev` will automatically install most dependencies including ICU, Cairo, HarfBuzz, GDAL, Proj, FreeType, etc.

**RHEL/CentOS/Fedora:**
```bash
yum install -y \
    gcc-c++ \
    make \
    pkg-config \
    mapnik-devel \
    boost-devel \
    boost-filesystem \
    boost-program-options \
    boost-regex \
    boost-system \
    bzip2-devel \
    openssl-devel
```

## Manual Configuration

If you need to override the automatic detection, you can set environment variables:

### Environment Variables

- `PKG_CONFIG_PATH`: Path to pkg-config files
- `CXXFLAGS`: Additional C++ compiler flags
- `LDFLAGS`: Additional linker flags
- `MAPNIK_CONFIG`: Path to mapnik-config binary (if not in PATH)

### Example: Custom Mapnik Installation

```bash
export PKG_CONFIG_PATH="/custom/path/lib/pkgconfig:$PKG_CONFIG_PATH"
export CXXFLAGS="-I/custom/boost/include"
export LDFLAGS="-L/custom/boost/lib"
uv sync
```

## Using pyproject.toml

The build configuration is defined in `pyproject.toml`:

```toml
[build-system]
requires = ["setuptools >= 80.9.0", "pybind11 >= 3.0.1"]
build-backend = "setuptools.build_meta"
```

## Troubleshooting

### macOS: "Package 'icu-uc' not found"

This means ICU is not in the pkg-config path. The build script should handle this automatically, but if it fails:

```bash
export PKG_CONFIG_PATH="$(brew --prefix icu4c)/lib/pkgconfig:$PKG_CONFIG_PATH"
uv sync
```

### macOS: "boost/fusion/include/at.hpp file not found"

This means Boost headers are not found. The build script should handle this automatically, but if it fails:

```bash
export CXXFLAGS="-I$(brew --prefix boost)/include"
uv sync
```

### Linux: "libmapnik not found"

Install the Mapnik development package:

```bash
# Debian/Ubuntu
apt-get install libmapnik-dev

# RHEL/Fedora
yum install mapnik-devel
```

## Docker Build

For a reproducible build environment, use Docker:

```bash
docker build -t python-mapnik:local .
```

The Dockerfile is configured for Debian-based Linux with Mapnik 4.2 from Debian sid.

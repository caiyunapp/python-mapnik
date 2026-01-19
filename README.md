**New**  Python bindings for Mapnik **[WIP]**

https://github.com/pybind/pybind11

## Installation

### Prerequisites

Before building from source, you need to install Mapnik and its dependencies:

#### Linux (Debian/Ubuntu)

```bash
# Install Mapnik and development dependencies
apt-get update
apt-get install -y \
    build-essential \
    pkg-config \
    libmapnik-dev \
    libboost-dev
```

#### macOS (Homebrew)

**For building from source:**
```bash
# Install Mapnik and dependencies
brew install mapnik boost icu4c
```

The build script will automatically detect Homebrew paths on macOS.

**For using pre-built wheels:**
Pre-built wheels bundle all dependencies (including Mapnik) and work standalone without requiring Homebrew installation.

### Building from Source

#### Using uv (recommended)

```bash
uv sync
```

#### Using pip

```bash
pip install . -v
```

**Note**: On macOS, the build system automatically configures Homebrew paths for Mapnik, Boost, and ICU. On Linux, standard system paths are used.

## Testing

Once you have installed you can test the package by running:

```
pytest test/python_tests/
```

## UV Sync via Docker

```
docker run --rm -it \
  -e http_proxy -e https_proxy -e no_proxy \
  -v "$(pwd):/workspace" \
  -w /workspace \
  python-mapnik:local \
  uv sync --verbose
```

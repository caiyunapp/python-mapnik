**New**  Python bindings for Mapnik **[WIP]**

https://github.com/pybind/pybind11

## Installation

### Building from Source

Make sure 'mapnik-config' is present and accessible via $PATH env variable 

```
pip install . -v 
```

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

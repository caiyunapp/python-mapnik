#! /usr/bin/env python3

import os
import shlex
import subprocess
import sys

from pybind11.setup_helpers import Pybind11Extension, build_ext
from setuptools import find_packages, setup


class MapnikBuildConfig:
    """
    Centralizes build configuration for the Mapnik pybind11 extension.

    Keep this file import-safe for setuptools/pip: do all external discovery
    (pkg-config) inside this class, not at module import time.
    """

    def __init__(self, pkg_name: str = "libmapnik"):
        self.pkg_name = pkg_name
        self.linkflags: list[str] = []
        self.extra_comp_args: list[str] = []
        self.mapnik_lib_path: str = ""
        self.input_plugin_path: str = ""
        self.font_path: str = ""

    @staticmethod
    def _check_output(args: list[str]) -> str:
        output = subprocess.check_output(args).decode()
        return output.rstrip("\n")

    def _pkg_config_var(self, var_name: str) -> str:
        return self._check_output(
            ["pkg-config", "--variable=" + var_name, self.pkg_name]
        )

    @staticmethod
    def _split_flags(s: str) -> list[str]:
        # pkg-config/mapnik-config return shell-like strings; shlex handles quoted paths safely.
        return [arg for arg in shlex.split(s) if arg]

    def _ensure_cpp_std(self) -> None:
        """
        Some environments don't inject a C++ standard in pkg-config/mapnik-config flags.
        This project uses C++17 features (e.g., `template <auto Key>`), so ensure C++17.
        """
        # Always force C++17 as the last -std flag so it wins over older standards.
        # (GCC/Clang take the last -std=... argument.)
        if not any(arg.startswith("/std:") for arg in self.extra_comp_args):
            self.extra_comp_args.append("-std=c++17")

    def _discover_with_pkg_config(self) -> None:
        # Linker flags / library location.
        prefix = self._pkg_config_var("prefix")
        lib_path = os.path.join(prefix, "lib")
        self.linkflags.extend(
            self._split_flags(
                self._check_output(["pkg-config", "--libs", self.pkg_name])
            )
        )

        # Runtime data locations.
        self.input_plugin_path = self._pkg_config_var("plugins_dir")
        self.font_path = self._pkg_config_var("fonts_dir")

        lib_dir_name = os.environ.get("LIB_DIR_NAME")
        if lib_dir_name:
            self.mapnik_lib_path = lib_path + lib_dir_name
        else:
            self.mapnik_lib_path = lib_path + "/mapnik"

        # Compiler flags.
        extra_comp_args = self._split_flags(
            self._check_output(["pkg-config", "--cflags", self.pkg_name])
        )
        self.extra_comp_args = [
            arg for arg in extra_comp_args if arg != "-fvisibility=hidden"
        ]

        # Platform-specific path adjustments
        if sys.platform == "darwin":
            # macOS Homebrew: Add Boost and fix HarfBuzz include paths
            self._add_macos_homebrew_paths()
        elif sys.platform.startswith("linux"):
            # Linux: Add system paths if needed
            self._add_linux_system_paths()

    def _mapnik_config(self) -> str:
        # Allow pinning a specific mapnik-config (useful in CI / non-standard prefixes).
        return os.environ.get("MAPNIK_CONFIG", "mapnik-config")

    def _mapnik_config_try_flag(self, flag_candidates: list[str]) -> str:
        """
        Try mapnik-config with one of the provided flags and return the first
        successful (non-empty) output. Returns "" if none work.
        """
        cmd = self._mapnik_config()
        for flag in flag_candidates:
            try:
                out = self._check_output([cmd, flag]).strip()
            except (FileNotFoundError, subprocess.CalledProcessError):
                continue
            if out:
                return out
        return ""

    def _setup_macos_pkg_config_path(self) -> None:
        """Set up PKG_CONFIG_PATH for macOS Homebrew packages."""
        try:
            brew_prefix = self._check_output(["brew", "--prefix"]).strip()

            # Add ICU and Mapnik pkg-config paths
            pkg_config_paths = []

            # Try to find ICU (could be icu4c or icu4c@version)
            try:
                icu_prefix = self._check_output(["brew", "--prefix", "icu4c"]).strip()
                pkg_config_paths.append(os.path.join(icu_prefix, "lib/pkgconfig"))
            except subprocess.CalledProcessError:
                pass

            # Add Mapnik pkg-config path
            mapnik_prefix = os.path.join(brew_prefix, "opt/mapnik")
            pkg_config_paths.append(os.path.join(mapnik_prefix, "lib/pkgconfig"))

            # Update PKG_CONFIG_PATH environment variable
            if pkg_config_paths:
                existing_path = os.environ.get("PKG_CONFIG_PATH", "")
                new_paths = ":".join(pkg_config_paths)
                if existing_path:
                    os.environ["PKG_CONFIG_PATH"] = f"{new_paths}:{existing_path}"
                else:
                    os.environ["PKG_CONFIG_PATH"] = new_paths
        except (FileNotFoundError, subprocess.CalledProcessError):
            # Homebrew not available, skip
            pass

    def _add_linux_system_paths(self) -> None:
        """Add Linux system paths for Boost if needed."""
        # On Linux, most dependencies are in standard locations via system packages.
        # However, we may need to add Boost include paths in some cases.

        # Common Boost include locations on Linux
        boost_search_paths = [
            "/usr/include/boost",
            "/usr/local/include/boost",
        ]

        for boost_path in boost_search_paths:
            if os.path.exists(boost_path):
                parent_dir = os.path.dirname(boost_path)
                include_flag = f"-I{parent_dir}"
                if include_flag not in self.extra_comp_args:
                    self.extra_comp_args.append(include_flag)
                break

    def _add_macos_homebrew_paths(self) -> None:
        """Add macOS Homebrew paths for Boost and fix HarfBuzz include path."""
        try:
            # Get Homebrew prefix
            brew_prefix = self._check_output(["brew", "--prefix"]).strip()

            # Add Boost include path
            boost_include = os.path.join(brew_prefix, "opt/boost/include")
            if os.path.exists(boost_include):
                self.extra_comp_args.append(f"-I{boost_include}")

            # Fix HarfBuzz include path (Mapnik expects <harfbuzz/hb.h>)
            # The pkg-config gives us -I.../include/harfbuzz but we need -I.../include
            harfbuzz_prefix = self._check_output(
                ["brew", "--prefix", "harfbuzz"]
            ).strip()
            harfbuzz_include = os.path.join(harfbuzz_prefix, "include")
            if os.path.exists(harfbuzz_include):
                # Remove the incorrect harfbuzz include path and add the correct one
                self.extra_comp_args = [
                    arg
                    for arg in self.extra_comp_args
                    if not (arg.startswith("-I") and arg.endswith("/include/harfbuzz"))
                ]
                self.extra_comp_args.append(f"-I{harfbuzz_include}")

            # Add Boost library path
            boost_lib = os.path.join(brew_prefix, "opt/boost/lib")
            if os.path.exists(boost_lib):
                self.linkflags.append(f"-L{boost_lib}")
        except (FileNotFoundError, subprocess.CalledProcessError):
            # Homebrew not available or command failed, skip
            pass

    def _discover_with_mapnik_config(self) -> None:
        cmd = self._mapnik_config()
        prefix = self._check_output([cmd, "--prefix"])
        lib_path = os.path.join(prefix, "lib")

        # flags
        self.linkflags.extend(self._split_flags(self._check_output([cmd, "--libs"])))
        extra_comp_args = self._split_flags(self._check_output([cmd, "--cflags"]))
        self.extra_comp_args = [
            arg for arg in extra_comp_args if arg != "-fvisibility=hidden"
        ]

        # runtime locations (best-effort: flags vary slightly across mapnik versions/distros)
        self.input_plugin_path = self._mapnik_config_try_flag(
            ["--input-plugins", "--input-plugins-dir", "--input-plugins-path"]
        )
        self.font_path = self._mapnik_config_try_flag(
            ["--fonts", "--fonts-dir", "--fonts-path"]
        )

        lib_dir_name = os.environ.get("LIB_DIR_NAME")
        if lib_dir_name:
            self.mapnik_lib_path = lib_path + lib_dir_name
        else:
            self.mapnik_lib_path = lib_path + "/mapnik"

        # Platform-specific path adjustments
        if sys.platform == "darwin":
            # macOS Homebrew: Add Boost and fix HarfBuzz include paths
            self._add_macos_homebrew_paths()
        elif sys.platform.startswith("linux"):
            # Linux: Add system paths if needed
            self._add_linux_system_paths()

    def discover(self) -> None:
        # macOS: Set up PKG_CONFIG_PATH for Homebrew packages
        if sys.platform == "darwin":
            self._setup_macos_pkg_config_path()

        # Prefer pkg-config, but fall back to mapnik-config (common on some distros/builds).
        try:
            self._discover_with_pkg_config()
        except (FileNotFoundError, subprocess.CalledProcessError):
            self._discover_with_mapnik_config()

        if not self.input_plugin_path or not self.font_path:
            raise RuntimeError(
                "Failed to discover Mapnik runtime paths. "
                "Tried pkg-config variables (plugins_dir/fonts_dir) and mapnik-config flags "
                "(--input-plugins/--fonts). You can set MAPNIK_CONFIG to point to mapnik-config."
            )

        self._ensure_cpp_std()

        # Platform-specific linker flags.
        if sys.platform != "darwin":
            self.linkflags.append("-lrt")
            self.linkflags.append("-Wl,-z,origin")
            self.linkflags.append("-Wl,-rpath=$ORIGIN/lib")

        self.linkflags = [arg for arg in self.linkflags if arg]

    def write_paths_py(self, target_file: str = "packaging/mapnik/paths.py") -> None:
        os.makedirs(os.path.dirname(target_file), exist_ok=True)
        with open(target_file, "w", encoding="utf-8") as f_paths:
            f_paths.write("import os\n\n")
            f_paths.write(f"mapniklibpath = {self.mapnik_lib_path!r}\n")
            f_paths.write(f"inputpluginspath = {self.input_plugin_path!r}\n")
            f_paths.write(f"fontscollectionpath = {self.font_path!r}\n")
            # __all__ should be a list of names (strings), not the values.
            f_paths.write(
                '__all__ = ["mapniklibpath", "inputpluginspath", "fontscollectionpath"]\n'
            )


cfg = MapnikBuildConfig("libmapnik")
cfg.discover()
cfg.write_paths_py()

ext_modules = [
    Pybind11Extension(
        "mapnik._mapnik",
        [
            "src/mapnik_python.cpp",
            "src/mapnik_layer.cpp",
            "src/mapnik_query.cpp",
            "src/mapnik_map.cpp",
            "src/mapnik_color.cpp",
            "src/mapnik_composite_modes.cpp",
            "src/mapnik_coord.cpp",
            "src/mapnik_envelope.cpp",
            "src/mapnik_expression.cpp",
            "src/mapnik_datasource.cpp",
            "src/mapnik_datasource_cache.cpp",
            "src/mapnik_gamma_method.cpp",
            "src/mapnik_geometry.cpp",
            "src/mapnik_feature.cpp",
            "src/mapnik_featureset.cpp",
            "src/mapnik_font_engine.cpp",
            "src/mapnik_fontset.cpp",
            "src/mapnik_grid.cpp",
            "src/mapnik_grid_view.cpp",
            "src/mapnik_image.cpp",
            "src/mapnik_image_view.cpp",
            "src/mapnik_projection.cpp",
            "src/mapnik_proj_transform.cpp",
            "src/mapnik_rule.cpp",
            "src/mapnik_symbolizer.cpp",
            "src/mapnik_debug_symbolizer.cpp",
            "src/mapnik_markers_symbolizer.cpp",
            "src/mapnik_polygon_symbolizer.cpp",
            "src/mapnik_polygon_pattern_symbolizer.cpp",
            "src/mapnik_line_symbolizer.cpp",
            "src/mapnik_line_pattern_symbolizer.cpp",
            "src/mapnik_point_symbolizer.cpp",
            "src/mapnik_raster_symbolizer.cpp",
            "src/mapnik_scaling_method.cpp",
            "src/mapnik_style.cpp",
            "src/mapnik_logger.cpp",
            "src/mapnik_placement_finder.cpp",
            "src/mapnik_text_symbolizer.cpp",
            "src/mapnik_palette.cpp",
            "src/mapnik_parameters.cpp",
            "src/python_grid_utils.cpp",
            "src/mapnik_raster_colorizer.cpp",
            "src/mapnik_label_collision_detector.cpp",
            "src/mapnik_dot_symbolizer.cpp",
            "src/mapnik_building_symbolizer.cpp",
            "src/mapnik_shield_symbolizer.cpp",
            "src/mapnik_group_symbolizer.cpp",
        ],
        cxx_std=17,
        extra_compile_args=cfg.extra_comp_args,
        extra_link_args=cfg.linkflags,
    )
]

if os.environ.get("CC", False) == False:
    os.environ["CC"] = "c++"
if os.environ.get("CXX", False) == False:
    os.environ["CXX"] = "c++"

setup(
    name="mapnik",
    version="4.2.0.dev",
    packages=find_packages(where="packaging"),
    package_dir={"": "packaging"},
    package_data={
        "mapnik": ["lib/*.*", "lib/*/*/*", "share/*/*"],
    },
    ext_modules=ext_modules,
    cmdclass={"build_ext": build_ext},
    python_requires=">=3.7",
)

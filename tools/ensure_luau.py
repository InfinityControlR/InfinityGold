"""Locate or provision the official Luau toolchain for validation.

Search order:
  1. INFINITYGOLD_LUAU environment variable (directory with luau-compile.exe)
  2. .tools/luau inside the repository
  3. a cached MagicLoot-Luau-* folder in the system temp directory
  4. download release 0.731 from the official luau-lang GitHub into .tools/luau
"""

from __future__ import annotations

import glob
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOOLCHAIN_DIR = REPO_ROOT / ".tools" / "luau"
RELEASE_TAG = "0.731"
RELEASE_URL = (
    "https://github.com/luau-lang/luau/releases/download/"
    f"{RELEASE_TAG}/luau-windows.zip"
)

COMPILE_NAMES = ("luau-compile.exe", "luau-compile")
RUN_NAMES = ("luau.exe", "luau")


def _first_existing(directory: Path, names) -> Path | None:
    for name in names:
        candidate = directory / name
        if candidate.is_file():
            return candidate
    return None


def _download_release(destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / "luau.zip"
        print(f"ensure_luau: downloading {RELEASE_URL}")
        with urllib.request.urlopen(RELEASE_URL, timeout=60) as response:
            archive.write_bytes(response.read())
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(destination)


def ensure_toolchain() -> Path:
    """Return a directory containing luau-compile.exe (and luau.exe)."""
    env_directory = os.environ.get("INFINITYGOLD_LUAU")
    if env_directory:
        candidate = Path(env_directory)
        if _first_existing(candidate, COMPILE_NAMES):
            return candidate

    if _first_existing(TOOLCHAIN_DIR, COMPILE_NAMES):
        return TOOLCHAIN_DIR

    for pattern in (
        os.path.join(tempfile.gettempdir(), "MagicLoot-Luau-*"),
        os.path.join(tempfile.gettempdir(), "luau-*"),
    ):
        for directory in sorted(glob.glob(pattern), reverse=True):
            candidate = Path(directory)
            if _first_existing(candidate, COMPILE_NAMES):
                shutil.copytree(candidate, TOOLCHAIN_DIR, dirs_exist_ok=True)
                return TOOLCHAIN_DIR

    _download_release(TOOLCHAIN_DIR)
    if not _first_existing(TOOLCHAIN_DIR, COMPILE_NAMES):
        raise RuntimeError("Luau toolchain could not be provisioned")
    return TOOLCHAIN_DIR


def compile_binary() -> Path:
    path = _first_existing(ensure_toolchain(), COMPILE_NAMES)
    if path is None:
        raise RuntimeError("luau-compile not found")
    return path


def run_binary() -> Path:
    path = _first_existing(ensure_toolchain(), RUN_NAMES)
    if path is None:
        raise RuntimeError("luau runner not found")
    return path


if __name__ == "__main__":
    try:
        directory = ensure_toolchain()
    except Exception as error:  # noqa: BLE001 - CLI surface
        print(f"ensure_luau: {error}", file=sys.stderr)
        sys.exit(1)
    print(f"ensure_luau: toolchain ready at {directory}")

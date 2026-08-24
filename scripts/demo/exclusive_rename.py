#!/usr/bin/env python3
"""Atomically rename one directory without replacing an existing destination."""

from __future__ import annotations

import ctypes
import errno
from pathlib import Path
import platform
import subprocess
import sys


RENAME_EXCL = 0x00000004


def ensure_native_apple_silicon() -> None:
    if platform.machine() != "arm64":
        raise RuntimeError("exclusive rename supports native Apple Silicon only")
    translated = subprocess.run(
        ["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"],
        check=False,
        capture_output=True,
        text=True,
    )
    if translated.returncode != 0 or translated.stdout.strip() != "0":
        raise RuntimeError("exclusive rename refuses Rosetta or unknown translation state")


def exclusive_rename(source: Path, destination: Path) -> None:
    if not source.is_absolute() or not destination.is_absolute():
        raise ValueError("exclusive rename paths must be absolute")
    libc = ctypes.CDLL(None, use_errno=True)
    renamex_np = libc.renamex_np
    renamex_np.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    renamex_np.restype = ctypes.c_int
    result = renamex_np(
        bytes(source),
        bytes(destination),
        RENAME_EXCL,
    )
    if result != 0:
        error_number = ctypes.get_errno()
        if error_number == 0:
            error_number = errno.EIO
        raise OSError(error_number, "exclusive directory rename failed", str(destination))


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: exclusive_rename.py SOURCE DESTINATION")
    ensure_native_apple_silicon()
    exclusive_rename(Path(sys.argv[1]), Path(sys.argv[2]))


if __name__ == "__main__":
    main()

"""The machine, in the words the TypeScript step uses (Node's os): Apple M1 Max, 10 cores, darwin 25.5.0 arm64."""

from __future__ import annotations

import os
import platform
import subprocess
from typing import Any


def _sysctl(name: str) -> str:
    try:
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def _memory_bytes() -> int:
    if (mem := _sysctl("hw.memsize")).isdigit():
        return int(mem)
    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (ValueError, OSError, AttributeError):
        return 0


def _cpu() -> str:
    if cpu := _sysctl("machdep.cpu.brand_string"):
        return cpu
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return "unknown"


def detect() -> dict[str, Any]:
    # Node's names for the architecture, so every language's results read the same.
    arch = {"x86_64": "x64", "aarch64": "arm64", "AMD64": "x64"}.get(platform.machine(), platform.machine())
    return {
        "cpu": _cpu(),
        "cores": os.cpu_count() or 0,
        "memory_gb": round(_memory_bytes() / (1 << 30)),
        "os": f"{platform.system().lower()} {platform.release()} {arch}",
        "runtime": f"{platform.python_implementation()} {platform.python_version()}",
        "gc": True,
    }

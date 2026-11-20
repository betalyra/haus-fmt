"""Timing: each task runs once untimed (its output's size goes into the checksum), then for the
warm-up, then in `samples` batches of equal size, garbage collected before each task. A sample
is the mean time per call of one batch (as criterion's and Go's samples are); the mean is over
all calls of all samples, p75 and p99 over the samples. Time is `time.perf_counter_ns`.
"""

from __future__ import annotations

import gc
import os
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass
from typing import Any, Literal

HARNESS = "time.perf_counter_ns (equal batches)"

Group = Literal["parse", "typed", "write"]
Input = Literal["corpus", "per doc"]
Format = Literal["json", "haus"]


@dataclass(frozen=True, slots=True)
class Task:
    id: str
    group: Group
    input: Input
    format: Format
    impl: str
    bytes: int
    """Bytes read (parse, typed) or written (write) per call."""
    run: Callable[[], int]
    """One call of the library: returns a size, for the checksum."""


@dataclass(frozen=True, slots=True)
class Options:
    time_s: float
    warmup_s: float
    samples: int
    quick: bool

    @staticmethod
    def from_env() -> Options:
        """`HAUS_BENCH_QUICK=1`: a short budget that checks the harness, not for publishing."""
        if os.environ.get("HAUS_BENCH_QUICK", "") not in ("", "0"):
            return Options(time_s=0.3, warmup_s=0.05, samples=3, quick=True)
        return Options(time_s=3.0, warmup_s=0.5, samples=10, quick=False)

    def out(self) -> dict[str, Any]:
        return {"time_ms": round(self.time_s * 1000), "warmup_ms": round(self.warmup_s * 1000), "quick": self.quick}


@dataclass(frozen=True, slots=True)
class Row:
    """One task's results, in the shape every language writes (SpeedRow in bench/size/src/results.ts)."""

    group: Group
    input: Input
    format: Format
    impl: str
    bytes: int
    docs: int
    hz: float
    mean_ms: float
    p75_ms: float
    p99_ms: float
    samples: int
    mb_s: float
    us_per_doc: float

    def line(self) -> str:
        task = f"{self.group} | {self.input} | {self.impl}"
        speed = f"{self.mb_s:8.1f} MB/s {self.us_per_doc:9.2f} µs/doc"
        return f"{task:<56} {speed}  p99 {self.p99_ms:.3f} ms  ({self.samples} samples)"

    def out(self) -> dict[str, Any]:
        return asdict(self)


def quantile(xs: list[float], q: float) -> float:
    """The q quantile of sorted values, interpolated between the nearest ranks."""
    pos = q * (len(xs) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (pos - lo)


def _batch(run: Callable[[], int], n: int) -> int:
    """The time of `n` calls, in nanoseconds."""
    start = time.perf_counter_ns()
    for _ in range(n):
        run()
    return time.perf_counter_ns() - start


def measure(task: Task, docs: int, options: Options) -> Row:
    gc.collect()
    first = _batch(task.run, 1)
    per_sample = options.time_s / options.samples * 1e9
    n = max(1, int(per_sample / max(first, 1)))
    warm_until = time.perf_counter_ns() + options.warmup_s * 1e9
    while time.perf_counter_ns() < warm_until:
        _batch(task.run, 1)
    batches = [_batch(task.run, n) for _ in range(options.samples)]
    per_call_ms = sorted(ns / n / 1e6 for ns in batches)
    mean_ms = sum(batches) / (n * len(batches)) / 1e6
    return Row(
        group=task.group,
        input=task.input,
        format=task.format,
        impl=task.impl,
        bytes=task.bytes,
        docs=docs,
        hz=1000 / mean_ms,
        mean_ms=mean_ms,
        p75_ms=quantile(per_call_ms, 0.75),
        p99_ms=quantile(per_call_ms, 0.99),
        samples=len(batches),
        mb_s=task.bytes / 1e6 / (mean_ms / 1000),
        us_per_doc=mean_ms * 1000 / docs,
    )

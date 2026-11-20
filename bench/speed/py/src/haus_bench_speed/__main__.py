"""The speed benchmark of the haus Python binding against json, orjson, pydantic and msgspec, on the
corpus `bench convert` exports (bench/.out/<source>/corpus/), the same documents the other
languages read: `uv run python -m haus_bench_speed` in bench/speed/py. Writes
bench/.out/<source>/speed-python.json for the report. Options come from the environment, as for
the Rust and Go benchmarks:

    HAUS_BENCH_SOURCES=vega-lite,geojson   only these sources (default: every source in sources.haus)
    HAUS_BENCH_QUICK=1                     a short budget: checks the harness, not for publishing
    HAUS_BENCH_OUT=/elsewhere              the results directory convert wrote to (default bench/.out)
    HAUS_BENCH_TASKS=parse-doc-haus,…      only these tasks (results are then not written)
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from . import machine
from .corpus import bench_dir, load_corpus, sources
from .harness import HARNESS, Options, measure
from .tasks import check, prepare, tasks


def main() -> None:
    bench = bench_dir(Path.cwd())
    out = Path(os.environ.get("HAUS_BENCH_OUT") or bench / ".out")
    every = sources(bench / "sources.haus")
    selected = [s for s in os.environ.get("HAUS_BENCH_SOURCES", "").split(",") if s] or every
    for s in selected:
        if s not in every:
            raise SystemExit(f"no corpus source {s} in sources.haus")
    only = {t for t in os.environ.get("HAUS_BENCH_TASKS", "").split(",") if t}
    options = Options.from_env()
    host = machine.detect()
    for source in selected:
        run_source(out, source, options, host, only)


def run_source(out: Path, source: str, options: Options, host: dict[str, object], only: set[str]) -> None:
    corpus = load_corpus(out, source)
    inputs = prepare(corpus)
    checks = check(inputs)
    todo = [t for t in tasks(inputs) if not only or t.id in only]
    checksum = sum(t.run() for t in todo)
    docs = len(corpus.documents)
    rows = []
    for t in todo:
        row = measure(t, docs, options)
        print(f"{source}/{t.id}: {row.line()}", flush=True)
        rows.append(row)
    if only:
        return
    results = {
        "lang": "python",
        "harness": HARNESS,
        "machine": host,
        "options": options.out(),
        "documents": [d.id for d in corpus.documents],
        "jsonNotStable": checks.json_not_stable,
        "typedBaselines": checks.typed_baselines,
        "rows": [r.out() for r in rows],
        "checksum": checksum,
    }
    path = out / source / "speed-python.json"
    path.write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    quick = " (quick)" if options.quick else ""
    print(f"\n{source}: {host['cpu']}, {host['runtime']}{quick}: wrote {path}\n", file=sys.stderr)


if __name__ == "__main__":
    main()

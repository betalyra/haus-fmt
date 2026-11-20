"""The corpus `bench convert` exports (bench/size/src/export.ts), read as it is on disk:

    <out>/<source>/corpus/
      index.haus             { source, schema, documents: [{ id, root, file }] }
      <source>.schema.haus   the schema; `root` is a type of it
      <source>.schema.json   the same types as a JSON Schema of the documents' JSON
      NNNN.haus              document NNNN, minimised haus
      NNNN.pretty.haus       the same, pretty
      NNNN.json              the same document, minified JSON
      all.haus               every document as one haus stream, minimised
      all.json               every document as one JSON array, minified

The sources and their order come from the shared manifest, `bench/sources.haus`.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import haus


@dataclass(frozen=True, slots=True)
class Document:
    id: str
    root: str
    """The document's type in the schema."""
    haus: str
    """Minimised haus (the wire form), as text: the haus binding reads `str`."""
    pretty: str
    json: bytes
    """Minified JSON, as bytes: what the JSON libraries read fastest (json.loads decodes them itself)."""


@dataclass(frozen=True, slots=True)
class Corpus:
    source: str
    schema: str
    json_schema: dict[str, Any]
    documents: list[Document]
    all_haus: str
    """Every document as one haus stream: each item followed by `,` and a line feed."""
    all_json: bytes
    """Every document as one JSON array."""


def bench_dir(start: Path) -> Path:
    """The bench/ directory: the one at or above `start` that holds sources.haus."""
    for d in (start, *start.parents):
        if (d / "sources.haus").is_file():
            return d
    raise SystemExit(f"no sources.haus in {start} or above it")


def _string(r: haus.Value, key: str, where: Path) -> str:
    match r:
        case haus.Record(fields) if isinstance(x := fields.get(key), haus.String):
            return x.value
        case _:
            raise SystemExit(f"{where}: no string {key}")


def _items(r: haus.Value, key: str, where: Path) -> tuple[haus.Value, ...]:
    match r:
        case haus.Record(fields) if isinstance(x := fields.get(key), haus.Array):
            return x.items
        case _:
            raise SystemExit(f"{where}: no array {key}")


def _read_value(path: Path) -> haus.Value:
    return haus.parse(path.read_text(encoding="utf-8"))


def sources(manifest: Path) -> list[str]:
    """The names of the corpus sources in the manifest, in its order."""
    m = _read_value(manifest)
    return [_string(s, "name", manifest) for s in _items(m, "corpus", manifest)]


def load_corpus(out: Path, source: str) -> Corpus:
    """A source's export from the results directory `out`."""
    folder = out / source / "corpus"
    index_path = folder / "index.haus"
    if not index_path.is_file():
        raise SystemExit(
            f"no corpus for {source} in {folder}: run `pnpm --filter haus-bench convert` (from typescript/) first"
        )
    index = _read_value(index_path)
    schema_file = _string(index, "schema", index_path)
    documents = [
        Document(
            id=_string(d, "id", index_path),
            root=_string(d, "root", index_path),
            haus=(folder / f"{(file := _string(d, 'file', index_path))}.haus").read_text(encoding="utf-8"),
            pretty=(folder / f"{file}.pretty.haus").read_text(encoding="utf-8"),
            json=(folder / f"{file}.json").read_bytes(),
        )
        for d in _items(index, "documents", index_path)
    ]
    return Corpus(
        source=_string(index, "source", index_path),
        schema=(folder / schema_file).read_text(encoding="utf-8"),
        json_schema=json.loads((folder / schema_file.replace(".schema.haus", ".schema.json")).read_bytes()),
        documents=documents,
        all_haus=(folder / "all.haus").read_text(encoding="utf-8"),
        all_json=(folder / "all.json").read_bytes(),
    )

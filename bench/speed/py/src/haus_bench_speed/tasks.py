"""The tasks of one source, prepared and checked once, in the order of the other languages' benchmarks:

    parse   json.loads, orjson.loads                    vs  haus.parse, haus.parse_all (text → Value, no schema)
    typed   pydantic TypeAdapter.validate_json,         vs  SchemaType.parse (parse and decode with the document's
            msgspec Decoder(type).decode (the models         type, spec §15); the corpus: parse_all, then decode each
            generated from the same schema: models.py)
    write   json.dumps, orjson.dumps of the parsed      vs  haus.canonical of the parsed value (the Python binding has
            value                                           no compact or minimised writer yet: canonical is minimised
                                                            with sorted keys); typed: SchemaType.canonical of the
                                                            decoded value, against pydantic's dump_json and msgspec's
                                                            encode of the values they decoded

each on the whole corpus as one text (all.json, a JSON array; all.haus, a haus stream) and on
every document on its own (the time is for all of them). The typed JSON tasks run per document
only: GitHub's and Stripe's documents each have their own type.
"""

from __future__ import annotations

import json
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from importlib.metadata import version
from typing import Any

import msgspec
import orjson

import haus
from haus import schema as hs

from .corpus import Corpus
from .harness import Task
from .models import Baselines, baselines
from .mutate import MUTATION_KINDS, mutations


def _dumps(x: Any) -> str:
    """json.dumps without spaces and with the characters as they are: minified, as the corpus is."""
    return json.dumps(x, separators=(",", ":"), ensure_ascii=False)


def _utf8(s: str) -> int:
    return len(s.encode("utf-8"))


@dataclass
class Inputs:
    corpus: Corpus
    types: list[hs.SchemaType]
    """Each document's type, looked up once."""
    values: list[haus.Value]
    json_values: list[Any]
    """Each JSON document, read by json.loads."""
    decoded: list[Any]
    """Each haus document, decoded with its type."""
    baselines: Baselines
    pydantic_values: list[Any]
    msgspec_values: list[Any]


def prepare(c: Corpus) -> Inputs:
    if not c.documents:
        raise SystemExit(f"{c.source}: no documents: run convert first")
    s = hs.compile_schema(c.schema)
    types = [s[d.root] for d in c.documents]
    values = [haus.parse(d.haus) for d in c.documents]
    b = baselines(c.json_schema, [d.root for d in c.documents], c.source)
    return Inputs(
        corpus=c,
        types=types,
        values=values,
        json_values=[json.loads(d.json) for d in c.documents],
        decoded=[t.decode(v) for t, v in zip(types, values, strict=True)],
        baselines=b,
        pydantic_values=[b.pydantic[d.root].validate_json(d.json, strict=True) for d in c.documents],
        msgspec_values=[b.msgspec_decoders[d.root].decode(d.json) for d in c.documents],
    )


@dataclass(frozen=True, slots=True)
class Checks:
    json_not_stable: int
    """Documents whose text json.loads → json.dumps changes."""
    typed_baselines: dict[str, Any]


def _fail(what: str) -> None:
    raise SystemExit(f"check failed: {what}")


def check(inp: Inputs) -> Checks:
    """The checks before timing: the inputs are what they claim to be, and the JSON baselines check
    what haus's typed parse checks (they accept every document and reject the mutated ones)."""
    c = inp.corpus
    json_not_stable = 0
    typed_other = 0
    json_writer_other = 0
    for i, d in enumerate(c.documents):
        v = inp.values[i]
        if not haus.equals(haus.parse(d.pretty), v):
            _fail(f"{d.id}: the pretty text reads as another value")
        if not haus.equals(haus.import_json(d.json.decode("utf-8")), haus.import_json(_dumps(inp.json_values[i]))):
            json_not_stable += 1
        written = inp.types[i].canonical(inp.decoded[i])
        if inp.types[i].parse(written) != inp.decoded[i]:
            _fail(f"{d.id}: the typed haus write reads back as another value")
        if written != haus.canonical(v):
            typed_other += 1
        p = inp.baselines.pydantic[d.root]
        p_text = p.dump_json(inp.pydantic_values[i], by_alias=True, exclude_unset=True)
        if p.validate_json(p_text, strict=True) != inp.pydantic_values[i]:
            _fail(f"{d.id}: pydantic's typed write reads back as another value")
        m_text = inp.baselines.msgspec_encoder.encode(inp.msgspec_values[i])
        if inp.baselines.msgspec_decoders[d.root].decode(m_text) != inp.msgspec_values[i]:
            _fail(f"{d.id}: msgspec's typed write reads back as another value")
        if p_text != d.json or m_text != d.json:
            json_writer_other += 1
    stream = haus.parse_all(c.all_haus)
    if len(stream) != len(inp.values) or not all(map(haus.equals, stream, inp.values)):
        _fail("all.haus doesn't read as the documents' values")
    if len(json.loads(c.all_json)) != len(inp.values):
        _fail("all.json doesn't hold the documents")
    return Checks(
        json_not_stable=json_not_stable,
        typed_baselines={
            "versions": {lib: version(lib) for lib in ("orjson", "pydantic", "msgspec")},
            "rejected": _rejected(inp),
            "typedWriteOtherText": typed_other,
            "jsonWriterOtherText": json_writer_other,
        },
    )


def _rejected(inp: Inputs) -> dict[str, int]:
    """Mutated documents every JSON baseline rejected, by kind; one any baseline accepts fails the check."""
    c = inp.corpus
    rejected = dict.fromkeys(MUTATION_KINDS, 0)
    readers: dict[str, Callable[[str, bytes], object]] = {
        "pydantic": lambda root, text: inp.baselines.pydantic[root].validate_json(text, strict=True),
        "msgspec": lambda root, text: inp.baselines.msgspec_decoders[root].decode(text),
    }
    for m in mutations(c.json_schema, [d.root for d in c.documents], inp.json_values):
        doc = c.documents[m.doc]
        for name, read in readers.items():
            try:
                read(doc.root, orjson.dumps(m.value))
            except (ValueError, msgspec.ValidationError):
                continue
            _fail(f"{name} accepts a mutated document ({m.kind} at {m.where} of {doc.id})")
        rejected[m.kind] += 1
    return {k: n for k, n in rejected.items() if n}


def _total(xs: Iterable[int]) -> int:
    return sum(xs)


def tasks(inp: Inputs) -> list[Task]:
    """Bytes are those of the text read, or written (UTF-8)."""
    c = inp.corpus
    docs = c.documents
    texts = [d.haus for d in docs]
    jsons = [d.json for d in docs]
    pairs = list(zip(inp.types, texts, strict=True))
    typed_pairs = list(zip(inp.types, inp.decoded, strict=True))
    roots = [d.root for d in docs]
    readers = inp.baselines
    pydantic_pairs = [(readers.pydantic[r], j) for r, j in zip(roots, jsons, strict=True)]
    msgspec_pairs = [(readers.msgspec_decoders[r], j) for r, j in zip(roots, jsons, strict=True)]
    pydantic_written = [(readers.pydantic[r], x) for r, x in zip(roots, inp.pydantic_values, strict=True)]
    encode = readers.msgspec_encoder.encode
    canonical = haus.canonical
    values = inp.values
    json_values = inp.json_values

    def parse_docs_haus() -> int:
        return len([haus.parse(t) for t in texts])

    def typed_corpus_haus() -> int:
        stream = haus.parse_all(c.all_haus)
        return len([t.decode(v) for t, v in zip(inp.types, stream, strict=True)])

    def write_corpus_haus() -> int:
        return len(",\n".join(map(canonical, values)) + ",\n")

    def write_typed_haus() -> int:
        return _total(len(t.canonical(x)) for t, x in typed_pairs)

    haus_bytes = _total(_utf8(t) for t in texts)
    json_bytes = _total(map(len, jsons))
    stream_text = ",\n".join(map(canonical, values)) + ",\n"
    return [
        Task("parse-corpus-json", "parse", "corpus", "json", "json.loads", len(c.all_json),
             lambda: len(json.loads(c.all_json))),
        Task("parse-corpus-orjson", "parse", "corpus", "json", "orjson.loads", len(c.all_json),
             lambda: len(orjson.loads(c.all_json))),
        Task("parse-corpus-haus", "parse", "corpus", "haus", "haus.parse_all", _utf8(c.all_haus),
             lambda: len(haus.parse_all(c.all_haus))),
        Task("parse-doc-json", "parse", "per doc", "json", "json.loads", json_bytes,
             lambda: len([json.loads(j) for j in jsons])),
        Task("parse-doc-orjson", "parse", "per doc", "json", "orjson.loads", json_bytes,
             lambda: len([orjson.loads(j) for j in jsons])),
        Task("parse-doc-haus", "parse", "per doc", "haus", "haus.parse", haus_bytes, parse_docs_haus),
        Task("typed-corpus-haus", "typed", "corpus", "haus", "haus.parse_all + SchemaType.decode",
             _utf8(c.all_haus), typed_corpus_haus),
        Task("typed-doc-haus", "typed", "per doc", "haus", "SchemaType.parse", haus_bytes,
             lambda: len([t.parse(x) for t, x in pairs])),
        Task("typed-doc-pydantic", "typed", "per doc", "json", "pydantic TypeAdapter.validate_json (strict)",
             json_bytes, lambda: len([a.validate_json(j, strict=True) for a, j in pydantic_pairs])),
        Task("typed-doc-msgspec", "typed", "per doc", "json", "msgspec.json.Decoder(type).decode", json_bytes,
             lambda: len([dec.decode(j) for dec, j in msgspec_pairs])),
        Task("write-corpus-json", "write", "corpus", "json", "json.dumps", _utf8(_dumps(json_values)),
             lambda: len(_dumps(json_values))),
        Task("write-corpus-orjson", "write", "corpus", "json", "orjson.dumps", len(orjson.dumps(json_values)),
             lambda: len(orjson.dumps(json_values))),
        Task("write-corpus-haus", "write", "corpus", "haus", "haus.canonical (each, a stream)",
             _utf8(stream_text), write_corpus_haus),
        Task("write-doc-json", "write", "per doc", "json", "json.dumps",
             _total(_utf8(_dumps(x)) for x in json_values), lambda: _total(len(_dumps(x)) for x in json_values)),
        Task("write-doc-orjson", "write", "per doc", "json", "orjson.dumps",
             _total(len(orjson.dumps(x)) for x in json_values),
             lambda: _total(len(orjson.dumps(x)) for x in json_values)),
        Task("write-doc-haus", "write", "per doc", "haus", "haus.canonical",
             _total(_utf8(canonical(v)) for v in values), lambda: _total(len(canonical(v)) for v in values)),
        Task("write-doc-haus-typed", "write", "per doc", "haus", "SchemaType.canonical (typed)",
             _total(_utf8(t.canonical(x)) for t, x in typed_pairs), write_typed_haus),
        Task("write-doc-pydantic", "write", "per doc", "json", "pydantic TypeAdapter.dump_json (typed)",
             _total(len(a.dump_json(x, by_alias=True, exclude_unset=True)) for a, x in pydantic_written),
             lambda: _total(len(a.dump_json(x, by_alias=True, exclude_unset=True)) for a, x in pydantic_written)),
        Task("write-doc-msgspec", "write", "per doc", "json", "msgspec.json.Encoder.encode (typed)",
             _total(len(encode(x)) for x in inp.msgspec_values),
             lambda: _total(len(encode(x)) for x in inp.msgspec_values)),
    ]

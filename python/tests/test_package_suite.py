"""The package suite, test-suite/packages/cases.haus (test-suite/README.md, "Package suite").

Each case is a file tree written into a fresh temporary directory, a root
schema file loaded with `load_schema`, and the result. Python gives packages
explicitly (`packages=`, `package_folders=`) and reads no `node_modules`, so
it runs the `Explicit` cases and skips the `Npm` ones (also `Npm { packages,
folders }`). Of the version cases (`should: True`), it runs the explicit
one: the version of a `package.json` next to a given package's manifest is
checked (spec §13.3). The skips are listed by pytest, and
`test_the_suite_runs_explicit_cases` counts them.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import pytest

import haus
from haus import Array, Record, String, Value, Variant
from haus.schema import (
    FileResolver,
    HausSchemaFileError,
    ResolvedModule,
    compile_schema,
    load_schema,
    read_module,
)

CASES = Path(__file__).resolve().parents[2] / "test-suite" / "packages" / "cases.haus"
DEPENDENCIES = ("dependencies", "peerDependencies", "devDependencies", "optionalDependencies")


@dataclass(frozen=True, slots=True)
class Explicit:
    packages: tuple[str, ...]
    folders: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Npm:
    """`node_modules`, together with the packages given explicitly."""

    packages: tuple[str, ...]
    folders: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Ok:
    packages: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Err:
    code: str
    mentions: tuple[str, ...]
    hides: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Case:
    name: str
    files: tuple[Variant, ...]
    root: str
    mode: Explicit | Npm
    expect: Ok | Err
    should: bool
    """The version check, which implementations SHOULD make (spec §13.3)."""


def strings(value: Value | None) -> tuple[str, ...]:
    match value:
        case None:
            return ()
        case Array(items):
            return tuple(text(v) for v in items)
        case _:
            raise ValueError(f"not a list of strings: {haus.canonical(value)}")


def text(value: Value | None) -> str:
    match value:
        case String(s):
            return s
        case _:
            raise ValueError(f"not a string: {value}")


def mode(value: Value) -> Explicit | Npm:
    match value:
        case Variant("Npm", ()):
            return Npm((), ())
        case Variant("Npm", (Record(f),)):
            return Npm(strings(f.get("packages")), strings(f.get("folders")))
        case Variant("Explicit", (Record(f),)):
            return Explicit(strings(f.get("packages")), strings(f.get("folders")))
        case _:
            raise ValueError(f"not a mode: {haus.canonical(value)}")


def expect(value: Value) -> Ok | Err:
    match value:
        case Variant("Ok", (Record(f),)):
            return Ok(strings(f.get("packages")))
        case Variant("Err", (Record(f),)):
            return Err(text(f.get("code")), strings(f.get("mentions")), strings(f.get("hides")))
        case _:
            raise ValueError(f"not an expectation: {haus.canonical(value)}")


def flag(value: Value | None) -> bool:
    match value:
        case None | Variant("False", ()):
            return False
        case Variant("True", ()):
            return True
        case _:
            raise ValueError(f"not a Bool: {haus.canonical(value)}")


def read_cases() -> list[Case]:
    cases: list[Case] = []
    for v in haus.parse_all(CASES.read_text("utf-8")):
        match v:
            case Variant("Case", (Record(f),)):
                files = f.get("files")
                assert isinstance(files, Array)
                assert all(isinstance(file, Variant) for file in files.items)
                cases.append(
                    Case(
                        text(f.get("name")),
                        tuple(file for file in files.items if isinstance(file, Variant)),
                        text(f.get("root")),
                        mode(f["mode"]),
                        expect(f["expect"]),
                        flag(f.get("should")),
                    )
                )
            case _:
                raise ValueError(f"not a case: {haus.canonical(v)}")
    return cases


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, "utf-8")


def write_tree(root: Path, files: tuple[Variant, ...]) -> None:
    """The case's files, as test-suite/README.md says. Links last, once their
    targets exist: on Windows a link to a directory must be made as one."""
    links = [f for f in files if f.tag == "Link"]
    for file in [f for f in files if f.tag != "Link"] + links:
        match file:
            case Variant("File", (String(path), String(content))):
                write(root / path, content)
            case Variant("Package", (String(directory), String(name), String(version), String(schema))):
                manifest = f"{{ name: {json.dumps(name)}, version: {json.dumps(version)} }}"
                write(root / directory / "package.haus", manifest)
                write(root / directory / "schema.haus", schema)
            case Variant("Npm", (String(directory), Record(fields))):
                package: dict[str, object] = {k: text(fields[k]) for k in ("name", "version") if k in fields}
                package |= {k: dict.fromkeys(strings(fields[k]), "*") for k in DEPENDENCIES if k in fields}
                write(root / directory / "package.json", json.dumps(package, indent=2))
            case Variant("Link", (String(path), String(target))):
                link = root / path
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(Path(target), target_is_directory=(link.parent / target).is_dir())
            case _:
                raise ValueError(f"not a file: {haus.canonical(file)}")


@dataclass(frozen=True, slots=True)
class Recording:
    """A resolver that notes every package it finds, as `name@version`."""

    resolver: FileResolver
    found: set[str]

    def resolve(self, module: str, from_key: str | None) -> ResolvedModule:
        r = self.resolver.resolve(module, from_key)
        if r.version is not None:
            self.found.add(f"{r.id.rsplit('@', 1)[0]}@{r.version}")
        return r


BROKEN: dict[str, str] = {}
"""Cases that are wrong, by name: they must fail until fixed (`strict`), then leave this list."""

ALL = read_cases()
SKIPPED = {c.name: "Npm mode: Python reads no node_modules" for c in ALL if isinstance(c.mode, Npm)}
RUN = [c for c in ALL if c.name not in SKIPPED]


def test_the_suite_runs_explicit_cases() -> None:
    print(f"package suite: {len(ALL)} cases, {len(RUN)} run (Explicit), {len(SKIPPED)} skipped (Npm)")
    assert len(ALL) == 92, "test-suite/packages/cases.haus has 92 cases"
    assert len({c.name for c in ALL}) == len(ALL), "case names are unique"
    assert all(isinstance(c.mode, Explicit) for c in RUN)


@pytest.mark.parametrize(
    "case",
    [
        pytest.param(
            c,
            id=c.name,
            marks=[
                *([pytest.mark.skip(reason=SKIPPED[c.name])] if c.name in SKIPPED else []),
                *([pytest.mark.xfail(reason=BROKEN[c.name], strict=True)] if c.name in BROKEN else []),
            ],
        )
        for c in ALL
    ],
)
def test_package_case(case: Case, tmp_path: Path) -> None:
    assert isinstance(case.mode, Explicit)
    write_tree(tmp_path, case.files)
    root = tmp_path / case.root
    packages = [tmp_path / p for p in case.mode.packages]
    folders = [tmp_path / f for f in case.mode.folders]
    match case.expect:
        case Ok(expected):
            load_schema(root, packages=packages, package_folders=folders)
            module = read_module(root)
            found: set[str] = set()
            resolver = Recording(FileResolver(root.parent, packages, folders=folders), found)
            compile_schema(module.text, resolver=resolver, key=module.key, id=module.id)
            assert sorted(found) == list(expected)
        case Err(code, mentions, hides):
            with pytest.raises(HausSchemaFileError) as info:
                load_schema(root, packages=packages, package_folders=folders)
            message = str(info.value)
            assert info.value.code == code, message
            for s in mentions:  # paths are compared with "/", whatever the OS writes
                assert s in message.replace("\\", "/"), f"{s!r} not in {message!r}"
            for s in hides:
                assert s not in message, f"{s!r} in {message!r}"

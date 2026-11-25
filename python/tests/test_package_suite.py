"""The package suite, test-suite/packages/cases.haus (test-suite/README.md, "Package suite").

Each case is a file tree written into a fresh temporary directory, a root
schema file loaded with `load_schema`, and the result. Python gives packages
explicitly (`packages=`, `package_folders=`) and reads no `node_modules`: it
runs the `core` cases and skips the `npm` ones, with a count. Of the version
cases (`should: True`), it runs the explicit ones: the version of a
`package.json` next to a given package's manifest is checked (spec §13.3).
`rootDir` is the `root` option. Cases with `os: "unix"` are skipped on
Windows, and those that set permissions (`Mode`) when running as root. Cases
with a `Fifo` run with a timeout: a resolver that opened it blocking would hang.

The core cases that give packages run a second time with each package and
folder given as a file tree in code (`DirTree`, an `importlib.resources`
`Traversable` that isn't a path and follows no links; spec §13.3,
`packages.explicit.file-tree`). The skips are listed by pytest, and
`test_the_suite_runs_core_cases` counts them.
"""

from __future__ import annotations

import json
import os
import stat
import sys
import threading
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from importlib.resources.abc import Traversable
from pathlib import Path
from typing import IO, Any

import pytest

import haus
from haus import Array, Number, Record, String, Value, Variant
from haus.schema import (
    FileResolver,
    HausSchemaFileError,
    PackageSource,
    ResolvedModule,
    compile_schema,
    load_schema,
    read_module,
)

CASES = Path(__file__).resolve().parents[2] / "test-suite" / "packages" / "cases.haus"
DEPENDENCIES = ("dependencies", "peerDependencies", "devDependencies", "optionalDependencies")
TIMEOUT = 5.0
"""Seconds a case with a FIFO may take: one that blocks on opening it fails."""


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
    root_dir: str | None
    """The build's `root` option, relative to the temporary directory."""
    ecosystem: str
    os: str | None
    mode: Explicit | Npm
    expect: Ok | Err
    should: bool
    """The version check, which implementations SHOULD make (spec §13.3)."""

    def has(self, tag: str) -> bool:
        return any(f.tag == tag for f in self.files)


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


def optional(value: Value | None) -> str | None:
    return None if value is None else text(value)


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
                case = Case(
                    text(f.get("name")),
                    tuple(file for file in files.items if isinstance(file, Variant)),
                    text(f.get("root")),
                    optional(f.get("rootDir")),
                    text(f.get("ecosystem")),
                    optional(f.get("os")),
                    mode(f["mode"]),
                    expect(f["expect"]),
                    flag(f.get("should")),
                )
                assert case.ecosystem in ("core", "npm", "cargo"), case.name
                assert (case.ecosystem == "npm") == isinstance(case.mode, Npm), case.name
                assert case.os in (None, "unix"), case.name
                cases.append(case)
            case _:
                raise ValueError(f"not a case: {haus.canonical(v)}")
    return cases


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, "utf-8")


def write_tree(root: Path, files: tuple[Variant, ...]) -> None:
    """The case's files, as test-suite/README.md says. Links last, once their
    targets exist: on Windows a link to a directory must be made as one.
    Permissions (`Mode`) after the whole tree is written."""
    links = [f for f in files if f.tag == "Link"]
    modes = [f for f in files if f.tag == "Mode"]
    for file in [f for f in files if f.tag not in ("Link", "Mode")] + links + modes:
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
            case Variant("Fifo", (String(path),)):
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                os.mkfifo(root / path)
            case Variant("Large", (String(path), Number(size))):
                write(root / path, " " * int(size))
            case Variant("Mode", (String(path), String(octal))):
                os.chmod(root / path, int(octal, 8))
            case _:
                raise ValueError(f"not a file: {haus.canonical(file)}")


def give_back_permissions(root: Path, files: tuple[Variant, ...]) -> None:
    """`chmod -R u+rwx` on what `Mode` changed, so that the temporary directory can be removed."""
    for file in files:
        match file:
            case Variant("Mode", (String(path), _)):
                os.chmod(root / path, stat.S_IRWXU)
                for directory, subdirectories, _files in os.walk(root / path):
                    for name in subdirectories:
                        os.chmod(Path(directory) / name, stat.S_IRWXU)
            case _:
                pass


class DirTree(Traversable):
    """A read-only file tree given in code, over a directory, that is not a path (not `os.PathLike`) and follows
    no links: what the resolver reads through it, it reads only through the `Traversable` interface."""

    def __init__(self, path: Path) -> None:
        self._path = path

    def _mode(self) -> int | None:
        try:
            return os.lstat(self._path).st_mode
        except OSError:
            return None

    def iterdir(self) -> Iterator[DirTree]:
        return (DirTree(self._path / name) for name in sorted(os.listdir(self._path)))

    def read_bytes(self) -> bytes:
        with self.open("rb") as f:
            data = f.read()
        assert isinstance(data, bytes)
        return data

    def read_text(self, encoding: str | None = None) -> str:
        return self.read_bytes().decode(encoding or "utf-8")

    def is_dir(self) -> bool:
        return (m := self._mode()) is not None and stat.S_ISDIR(m)

    def is_file(self) -> bool:
        return (m := self._mode()) is not None and stat.S_ISREG(m)

    def joinpath(self, *descendants: str | os.PathLike[str]) -> DirTree:
        return DirTree(self._path.joinpath(*descendants))

    def __truediv__(self, child: str | os.PathLike[str]) -> DirTree:
        return self.joinpath(child)

    def open(self, mode: str = "r", *args: Any, **kwargs: Any) -> IO[Any]:
        assert mode in ("r", "rb") and self.is_file(), "the resolver opens only regular files, for reading"
        return open(self._path, mode, *args, **kwargs)

    @property
    def name(self) -> str:
        return self._path.name

    def __str__(self) -> str:
        return f"<tree {self._path.name}>"


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

TREE_SKIPPED: dict[str, str] = {
    "folder-subdirectory-is-a-link": "the folder's subdirectory is a link, and a file tree follows no links",
}
"""Core cases that don't run with packages given as file trees, by name, and why."""

ALL = read_cases()
WINDOWS = sys.platform == "win32"
AS_ROOT = hasattr(os, "geteuid") and os.geteuid() == 0


def skipped(case: Case) -> str | None:
    if case.ecosystem != "core":
        return f"{case.ecosystem} ecosystem: Python reads no node_modules (spec §13.3, ecosystems)"
    if case.os == "unix" and WINDOWS:
        return "a Unix-only case (os: unix)"
    if case.has("Mode") and AS_ROOT:
        return "sets permissions, which don't stop root (uid 0)"
    return None


SKIPPED = {c.name: why for c in ALL if (why := skipped(c)) is not None}
RUN = [c for c in ALL if c.name not in SKIPPED]
TREES = [c for c in RUN if isinstance(c.mode, Explicit) and (c.mode.packages or c.mode.folders)]


def test_the_suite_runs_core_cases() -> None:
    npm = [c for c in ALL if c.ecosystem == "npm"]
    print(
        f"package suite: {len(ALL)} cases, {len(RUN)} run (core), {len(SKIPPED)} skipped"
        f" ({len(npm)} npm, {len(SKIPPED) - len(npm)} for the OS or the user);"
        f" {len(TREES) - len(TREE_SKIPPED)} run again with file trees"
    )
    assert len(ALL) == 136, "test-suite/packages/cases.haus has 136 cases"
    assert len([c for c in ALL if c.ecosystem == "core"]) == 90
    assert len(npm) == 46
    assert len({c.name for c in ALL}) == len(ALL), "case names are unique"
    assert all(isinstance(c.mode, Explicit) for c in RUN)
    assert set(TREE_SKIPPED) <= {c.name for c in TREES}


def within(seconds: float, run: Callable[[], None]) -> None:
    """`run`, failing if it takes longer than `seconds` (it is left blocked on a daemon thread then)."""
    outcome: list[BaseException | None] = []

    def target() -> None:
        try:
            run()
        except BaseException as e:
            outcome.append(e)
        else:
            outcome.append(None)

    thread = threading.Thread(target=target, daemon=True)
    thread.start()
    thread.join(seconds)
    if thread.is_alive():
        pytest.fail(f"the case took more than {seconds} s: a FIFO was opened blocking?")
    if (error := outcome[0]) is not None:
        raise error


def check(case: Case, tmp_path: Path, packages: list[PackageSource], folders: list[PackageSource]) -> None:
    root = tmp_path / case.root
    root_dir = tmp_path / case.root_dir if case.root_dir is not None else None
    match case.expect:
        case Ok(expected):
            load_schema(root, packages=packages, package_folders=folders, root=root_dir)
            module = read_module(root)
            found: set[str] = set()
            resolver = Recording(FileResolver(root.parent, packages, folders=folders, root=root_dir), found)
            compile_schema(module.text, resolver=resolver, key=module.key, id=module.id)
            assert sorted(found) == list(expected)
        case Err(code, mentions, hides):
            with pytest.raises(HausSchemaFileError) as info:
                load_schema(root, packages=packages, package_folders=folders, root=root_dir)
            message = str(info.value)
            assert info.value.code == code, message
            for s in mentions:  # paths are compared with "/", whatever the OS writes
                assert s in message.replace("\\", "/"), f"{s!r} not in {message!r}"
            for s in hides:
                assert s not in message, f"{s!r} in {message!r}"


def run_case(case: Case, tmp_path: Path, given: Callable[[Path], PackageSource]) -> None:
    assert isinstance(case.mode, Explicit)
    write_tree(tmp_path, case.files)
    try:
        packages = [given(tmp_path / p) for p in case.mode.packages]
        folders = [given(tmp_path / f) for f in case.mode.folders]
        if case.has("Fifo"):
            within(TIMEOUT, lambda: check(case, tmp_path, packages, folders))
        else:
            check(case, tmp_path, packages, folders)
    finally:
        give_back_permissions(tmp_path, case.files)


def marks(case: Case, skips: dict[str, str]) -> list[pytest.MarkDecorator]:
    return [
        *([pytest.mark.skip(reason=skips[case.name])] if case.name in skips else []),
        *([pytest.mark.xfail(reason=BROKEN[case.name], strict=True)] if case.name in BROKEN else []),
    ]


@pytest.mark.parametrize("case", [pytest.param(c, id=c.name, marks=marks(c, SKIPPED)) for c in ALL])
def test_package_case(case: Case, tmp_path: Path) -> None:
    run_case(case, tmp_path, lambda path: path)


@pytest.mark.parametrize("case", [pytest.param(c, id=c.name, marks=marks(c, TREE_SKIPPED)) for c in TREES])
def test_package_case_with_file_trees(case: Case, tmp_path: Path) -> None:
    """Each package and folder given as a file tree in code, at its real path (a tree follows no links)."""
    run_case(case, tmp_path, lambda path: DirTree(Path(os.path.realpath(path))))

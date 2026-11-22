"""Resolving schema imports from the file system (spec §13.3).

    import ./common (Address)      → common.schema.haus, next to the importing file
    import @haus-fmt/money (Money) → the package given for "@haus-fmt/money"

Python has no scoped package names, so packages are never searched for (no
`node_modules`, no global folders): the application gives its schema packages
explicitly, as directories (`packages=`, named by their manifests), as a
mapping from names to directories, or as folders whose direct subdirectories
are packages (`folders=`). Given packages count as declared dependencies.
A package or a folder may also be a read-only file tree that code provides, an
`importlib.resources` `Traversable` (such as `importlib.resources.files("acme_ids") / "schema"`
inside a zip file), read by the same rules. `installed_package` finds the
directory of an installed Python package that ships one, without importing it.
A package directory holds a manifest, `package.haus`, and one schema file,
`schema.haus`:

    { name: "@haus-fmt/money", version: "1.2.0" }

The manifest gives types their identity in every language (`@haus-fmt/money@1#Money`).
A package that is also an npm package has a `package.json` next to its manifest: its
`version`, when it is a string, must be the manifest's (`package-version`), so that a
package published with two versions is caught; nothing else in it is read.
A package's schema imports other packages by name, never files. Files outside
a schema package are identified by the nearest `pyproject.toml` project name
and their path (`my-app/schemas/order#Root`), or without a project by their
path relative to the root schema file's directory (`billing/common#Address`);
their relative imports can't reach into a package directory. A file's id never
has the form of a package's (`@org/name@N`): one that would start with `@` starts
with `./@` instead.

A build has a root directory (spec §13.3, "The root"): the directory of the
real path of the schema file it starts from, or the `root` option, a directory
that contains it (a relative one is relative to the schema file's real
directory). Both are resolved to real paths once, at the start. A relative
import follows no link: from the importing file's real directory, its `..`
names go up, and those that go above the root are `import-outside-root`,
before anything is looked at; its other names go down one at a time, each
listed by its directory with that spelling and none a symbolic link (checked
without following it; a link is `import-not-found`, and nothing behind it is
looked at). So the file reached is inside the root. Then the directories from
the file's up to the root are looked at for a `package.haus` (`package-path`;
one that can't be listed is `import-not-found`), and the file is opened.
Messages show paths relative to the root (`../vendor/money` outside it), not
absolute ones.

Files are read as spec §13.3 says. The names looked up, `package.haus`,
`schema.haus`, `package.json`, `pyproject.toml` and each name of a relative
import, must be spelled as their directory lists them (a directory that can't
be listed has none of them). Every file read is a regular file: it is opened in
its real directory without following a link at its last name and without
blocking, checked on the opened file and read from it. A package's
`package.haus`, `schema.haus` and `package.json` are never links (its directory
may be one); a `pyproject.toml` that is a link names no project. A schema file
and a `package.json` are at most 1 MiB (`file-too-large`), and each file is read
once, by its real path, also when it is needed in two roles: every use sees the
same bytes, and the checks of each role still apply to it.
"""

from __future__ import annotations

import errno
import importlib.util
import json
import os
import re
import stat
import threading
import tomllib
from collections.abc import Iterable, Iterator, Mapping
from dataclasses import dataclass
from importlib.resources.abc import Traversable
from pathlib import Path
from typing import TypeAlias, TypeGuard, cast

from ._error_codes import ErrorCode
from ._errors import HausError
from ._parser import Parser
from ._schema_file import FILE_PATH, ModuleError, ResolvedModule, escape, quote
from ._value import Record, String

StrPath: TypeAlias = str | os.PathLike[str]
"""A file system path, as a string or a `Path`."""
PackageSource: TypeAlias = StrPath | Traversable
"""A package's directory, or a read-only file tree that code provides (an `importlib.resources` `Traversable`)."""
Packages: TypeAlias = Mapping[str, PackageSource] | Iterable[PackageSource]
"""Schema packages given explicitly: package directories or file trees (named by their manifests),
or a mapping from each package name to its directory or tree."""

MANIFEST = "package.haus"
"""The file name of a schema package's manifest."""
PACKAGE_SCHEMA = "schema.haus"
"""The file name of a schema package's one schema file, next to its manifest."""
PACKAGE_JSON = "package.json"
"""The file name of npm's package file, which may sit next to a manifest: its `version` is checked."""
PYPROJECT = "pyproject.toml"
"""The file name of a Python project, whose `[project] name` names the files under it."""
MAX_MANIFEST_SIZE = 64 * 1024
"""A manifest is at most 64 KiB (spec §13.3, `package-manifest`)."""
MAX_SCHEMA_SIZE = 1024 * 1024
"""A schema file is at most 1 MiB (spec §13.3, `file-too-large`)."""
MAX_PACKAGE_JSON_SIZE = 1024 * 1024
"""A `package.json` is at most 1 MiB (spec §13.3, `file-too-large`)."""
MAX_FOLDER_ENTRIES = 4096
"""A folder of packages has at most 4096 entries (spec §13.3, `too-many-files`)."""
EXTENSION = ".schema.haus"

_SEGMENT = r"(?!node_modules/|node_modules\Z)[a-z0-9][a-z0-9._-]*"
_NAME = re.compile(rf"@{_SEGMENT}/{_SEGMENT}")
"""A package name: npm's rules for scoped names, in lowercase; no part is `node_modules` (spec §13.3)."""
_MAX_NAME_LENGTH = 214
_NUMBER = r"(?:0|[1-9][0-9]*)"
_PRE = rf"(?:{_NUMBER}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
_BUILD = r"[0-9A-Za-z-]+"
_SEMVER = re.compile(rf"{_NUMBER}\.{_NUMBER}\.{_NUMBER}(?:-{_PRE}(?:\.{_PRE})*)?(?:\+{_BUILD}(?:\.{_BUILD})*)?")
"""A semantic version (SemVer 2.0), with pre-release and build. ASCII digits only; always `fullmatch`."""

_NOFOLLOW: int = getattr(os, "O_NOFOLLOW", 0)
_OPEN_FLAGS = (
    os.O_RDONLY | _NOFOLLOW | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOCTTY", 0) | getattr(os, "O_BINARY", 0)
)
"""Never through a link; a FIFO or a device doesn't block the open (its type is checked right after), and a
terminal doesn't become the process's controlling terminal."""


def _is_tree(source: object) -> TypeGuard[Traversable]:
    """A file tree given in code: a `Traversable` that isn't a path (a `Path` is read as a directory on disk)."""
    return isinstance(source, Traversable) and not isinstance(source, (str, os.PathLike))


@dataclass(frozen=True, slots=True)
class Manifest:
    """A schema package's `package.haus`. Fields other than `name` and `version` are ignored."""

    name: str
    version: str
    dir: Path | Traversable
    """The package directory, with the manifest and `schema.haus`, or the file tree given in code."""

    @property
    def major(self) -> str:
        return self.version.split(".")[0]


def _is_link(st: os.stat_result) -> bool:
    """Whether `lstat` saw a symbolic link, or on Windows any reparse point (a junction too)."""
    return stat.S_ISLNK(st.st_mode) or bool(getattr(st, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def _read_file(path: Path, limit: int, what: str, *, irregular: ErrorCode, too_large: ErrorCode) -> bytes:
    """The bytes of the regular file `path`, which is not a link, at most `limit` of them (spec §13.3).

    Opened without following a link and without blocking (a FIFO), and checked
    on the opened file, so that the file checked is the file read. Where there
    is no `O_NOFOLLOW` (Windows), `lstat` first and the opened file must be the
    same file. Raises `ModuleError` (`irregular`, `too_large`) without reading
    the file, and `OSError` (such as `FileNotFoundError`) for one that can't be opened.
    """
    refused = ModuleError(irregular, f"{what} is a symbolic link or not a regular file; it is not read")
    before = None
    if not _NOFOLLOW:
        before = os.lstat(path)
        if not stat.S_ISREG(before.st_mode):
            raise refused
    try:
        fd = os.open(path, _OPEN_FLAGS)
    except OSError as e:
        if e.errno in (errno.ELOOP, errno.EMLINK):  # a link (EMLINK on FreeBSD)
            raise refused from None
        raise
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or (
            before is not None and (st.st_ino, st.st_dev) != (before.st_ino, before.st_dev)
        ):
            raise refused
        if st.st_size > limit:
            raise ModuleError(too_large, f"{what} is larger than {limit // 1024} KiB; it is not read")
        chunks: list[bytes] = []
        size = 0
        while size <= limit and (chunk := os.read(fd, limit + 1 - size)):
            chunks.append(chunk)
            size += len(chunk)
        if size > limit:  # it grew since fstat
            raise ModuleError(too_large, f"{what} is larger than {limit // 1024} KiB; it is not read")
        return b"".join(chunks)
    finally:
        os.close(fd)


class _Files:
    """Every file read for one schema, by real path (each is read once), the directories listed, and the root
    that messages show paths from (spec §13.3)."""

    __slots__ = ("_listings", "_read", "root")

    def __init__(self, root: Path | None = None) -> None:
        self.root = root
        """The build's root (a real path): messages show paths relative to it. None: as given."""
        self._read: dict[str, bytes] = {}
        self._listings: dict[Path, frozenset[str] | None] = {}

    def read(self, path: Path, limit: int, what: str, *, irregular: ErrorCode, too_large: ErrorCode) -> bytes:
        """`_read_file` on `path`'s name in its real directory, or the bytes already read from the same real path,
        checked for this use."""
        real = os.path.realpath(path)
        if (data := self._read.get(real)) is None:
            opened = Path(os.path.realpath(path.parent)) / path.name
            data = self._read[real] = _read_file(opened, limit, what, irregular=irregular, too_large=too_large)
            return data
        # Read in another role: this use's checks, on the path it uses and the bytes read.
        if not stat.S_ISREG(os.lstat(path).st_mode):
            raise ModuleError(irregular, f"{what} is a symbolic link or not a regular file; it is not read")
        if len(data) > limit:
            raise ModuleError(too_large, f"{what} is larger than {limit // 1024} KiB; it is not read")
        return data

    def listing(self, directory: Path) -> frozenset[str] | None:
        """The names `directory` lists, or None if it can't be listed (spec §13.3, "Spelling")."""
        if directory in self._listings:
            return self._listings[directory]
        try:
            names: frozenset[str] | None = frozenset(os.listdir(directory))
        except OSError:
            names = None
        self._listings[directory] = names
        return names

    def listed(self, directory: Path, name: str) -> bool:
        """Whether `directory` lists `name`, spelled so, also where the file system ignores case. A directory that
        can't be listed lists nothing."""
        return name in (self.listing(directory) or ())

    def shown(self, path: StrPath, given: StrPath | None = None) -> str:
        """`path` as a message shows it (`relative`), escaped."""
        return escape(self.relative(path, given))

    def relative(self, path: StrPath, given: StrPath | None = None) -> str:
        """`path` as messages show it, from its real directory, relative to the root (`../vendor/x` outside it)
        (spec §13.3, "The root"). On another drive than the root (Windows), as the application gave it (`given`,
        else `path`): never made absolute."""
        if self.root is None:
            return str(path)
        absolute = os.path.abspath(path)
        real = os.path.join(os.path.realpath(os.path.dirname(absolute)), os.path.basename(absolute))
        try:
            return os.path.relpath(real, self.root)
        except ValueError:  # another drive
            return str(given if given is not None else path)


def _decode(data: bytes, what: str) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise ModuleError("invalid-utf8", f"{what} is not UTF-8") from None


def _invalid(shown: str, why: str) -> ModuleError:
    return ModuleError("package-manifest", f"{shown} is not a valid manifest: {why}")


def read_manifest(path: StrPath) -> Manifest:
    """Read and check a schema package manifest (spec §13.3).

    Raises `OSError` for a file that can't be read, and `ModuleError` with the
    code `package-manifest` for one that isn't a manifest (more than 64 KiB, not
    one record, a `name` that isn't a lowercase `@org/name`, a `version` that
    isn't a semantic version), `package-path` for a link or a file that isn't
    regular (not read).
    """
    return _read_manifest(path, _Files())


def _read_manifest(path: StrPath, files: _Files) -> Manifest:
    path = Path(os.path.abspath(path))
    shown = files.shown(path)
    data = files.read(
        path, MAX_MANIFEST_SIZE, f"the manifest {shown}", irregular="package-path", too_large="package-manifest"
    )
    return _parse_manifest(data, shown, path.parent)


def _parse_manifest(data: bytes, shown: str, directory: Path | Traversable) -> Manifest:
    try:
        values = Parser(data.decode("utf-8")).parse_sequence()
    except UnicodeDecodeError:
        raise _invalid(shown, "it is not UTF-8") from None
    except HausError as e:  # its own message could quote the file
        raise _invalid(shown, f"it is not haus ({e.code})") from None
    match values:
        case [Record(fields)]:
            pass
        case _:
            raise _invalid(shown, "a manifest is one record, { name: …, version: … }")

    def text(key: str) -> str:
        match fields.get(key):
            case String(value):
                return value
            case _:
                raise _invalid(shown, f"it needs a string field {key}")

    manifest = Manifest(text("name"), text("version"), directory)
    if not _NAME.fullmatch(manifest.name) or len(manifest.name) > _MAX_NAME_LENGTH:
        raise _invalid(
            shown,
            f'the name "{quote(manifest.name)}" isn\'t @org/name in lowercase'
            " (a-z, 0-9, -, ., _, no part node_modules, at most 214 characters)",
        )
    if not _SEMVER.fullmatch(manifest.version):
        raise _invalid(shown, f'the version "{quote(manifest.version)}" isn\'t a semantic version, like 1.2.0')
    return manifest


def schema_path(manifest: Manifest) -> Path:
    """The package's schema file, `schema.haus` next to its manifest (spec §13.3), for a package on disk.

    Checked, not read: raises `FileNotFoundError` if its directory doesn't list it
    (spelled so), and `ModuleError` (`package-path`) for a symbolic link or a file
    that isn't regular.
    """
    if not isinstance(manifest.dir, Path):
        raise TypeError(f"{quote(manifest.name)} is a file tree, not a directory on disk")
    path = manifest.dir / PACKAGE_SCHEMA
    if not _Files().listed(manifest.dir, PACKAGE_SCHEMA):
        raise FileNotFoundError(
            f"{quote(manifest.name)} has no {PACKAGE_SCHEMA} next to its manifest ({escape(str(manifest.dir))})"
        )
    if not stat.S_ISREG(os.lstat(path).st_mode):
        raise ModuleError(
            "package-path",
            f"{quote(manifest.name)}: its {PACKAGE_SCHEMA} is a symbolic link or not a regular file; it is not read",
        )
    return path


def _ancestors(directory: Path) -> Iterator[Path]:
    yield directory
    yield from directory.parents


def _stem(path: Path) -> str:
    return path.as_posix().removesuffix(EXTENSION)


def _project_name(directory: Path, files: _Files) -> str | None:
    """The project name in the `pyproject.toml` of the real directory `directory`, if it has one.

    Opened in the directory without following a link: a link, or a file that isn't regular, names no project."""
    if not files.listed(directory, PYPROJECT):
        return None
    pyproject = directory / PYPROJECT
    try:
        text = files.read(
            pyproject,
            MAX_SCHEMA_SIZE,
            f"the project file {files.shown(pyproject)}",
            irregular="import-not-found",
            too_large="file-too-large",
        ).decode("utf-8")
        data = tomllib.loads(text)
    except (OSError, ModuleError, ValueError, RecursionError):  # TOMLDecodeError and UnicodeDecodeError too
        return None
    match data:
        case {"project": {"name": str(name)}}:
            return name
        case _:
            return None


def _package_of(file: Path, files: _Files) -> Manifest | None:
    """The manifest of the package whose schema is `file`, if it is one (`schema.haus` next to a manifest)."""
    if file.name == PACKAGE_SCHEMA and files.listed(file.parent, MANIFEST):
        return _read_manifest(file.parent / MANIFEST, files)
    return None


def _relative(file: Path, root: Path) -> Path:
    """`file` relative to `root` (with `..` where it is outside), or absolute if it can't be (another drive)."""
    try:
        return Path(os.path.relpath(file, root))
    except ValueError:
        return file


def identify(path: StrPath, root: StrPath | None = None) -> str:
    """The identity of a schema file (spec §13.3).

    `@haus-fmt/money@1` for a package's `schema.haus`; for other files, their
    path without the extension, after the nearest `pyproject.toml`'s project
    name (`my-app/schemas/order`), or without a project relative to `root`, by
    default the file's own directory (`order`, `billing/common`). A file's id
    never has the form of a package's: one that would start with `@` starts
    with `./@`. Different files have different identities, apart from files of
    two projects with the same name.
    """
    file, files = Path(os.path.abspath(path)), _Files()
    return _identify(file, _package_of(file, files), root, files)


def _identify(file: Path, package: Manifest | None, root: StrPath | None, files: _Files) -> str:
    if package is not None:
        return f"{package.name}@{package.major}"
    file = Path(os.path.realpath(file))
    for d in _ancestors(file.parent):
        if (name := _project_name(d, files)) is not None:
            return _file_id(f"{name}/{_stem(file.relative_to(d))}")
    return _file_id(_stem(_relative(file, Path(os.path.realpath(root)) if root is not None else file.parent)))


def _file_id(id: str) -> str:
    """A file's id, which never has the form of a package's, `@org/name@N` (spec §13.3, "Identity"): a project
    or an entry file may be called `@org`, `name@1`."""
    return f"./{id}" if id.startswith("@") else id


def read_module(path: StrPath, root: StrPath | None = None) -> ResolvedModule:
    """A schema file as a resolved module: its key (real path), identity (see `identify`), text and package version.

    The file is regular and at most 1 MiB (`file-too-large`); it is read from
    its real path, without following links.
    """
    return _read_module(path, root, _Files())


def _read_module(path: StrPath, root: StrPath | None, files: _Files) -> ResolvedModule:
    file = Path(os.path.abspath(path))
    package = _package_of(file, files)
    key = Path(os.path.realpath(file))
    what = f"the schema file {files.shown(key)}"
    data = files.read(key, MAX_SCHEMA_SIZE, what, irregular="import-not-found", too_large="file-too-large")
    identity = _identify(file, package, root, files)
    shown = files.relative(key) if files.root is not None else None
    return ResolvedModule(str(key), identity, _decode(data, what), package.version if package else None, shown)


class _Directory:
    """A package directory on disk: its files are opened in its real directory, never through a link."""

    __slots__ = ("_files", "given", "path")

    def __init__(self, path: Path, files: _Files, given: StrPath) -> None:
        self.path = path
        self._files = files
        self.given = given
        """The directory as the application gave it, shown where it can't be shown relative to the root."""

    @property
    def dir(self) -> Path:
        return self.path

    @property
    def shown(self) -> str:
        return self._files.shown(self.path, self.given)

    def where(self, name: str) -> str:
        return self._files.shown(self.path / name, os.path.join(self.given, name))

    def has(self, name: str) -> bool:
        return self._files.listed(self.path, name)

    def read(self, name: str, limit: int, what: str, *, irregular: ErrorCode, too_large: ErrorCode) -> bytes:
        return self._files.read(self.path / name, limit, what, irregular=irregular, too_large=too_large)

    def key(self) -> str:
        return str(Path(os.path.realpath(self.path)) / PACKAGE_SCHEMA)

    def place(self) -> str:
        """Where its schema is, for messages: relative to the root, not escaped."""
        return self._files.relative(self.path / PACKAGE_SCHEMA, os.path.join(self.given, PACKAGE_SCHEMA))


class _Tree:
    """A package given in code as a read-only file tree (spec §13.3, `packages.explicit.file-tree`).

    The same rules as a directory: exact names (as `iterdir` lists them), regular files only (`is_file`; a tree
    that can hold links is expected to follow none), the limits, each file read once."""

    __slots__ = ("_entries", "_read", "tree")

    def __init__(self, tree: Traversable) -> None:
        self.tree = tree
        self._entries: dict[str, Traversable] | None = None
        self._read: dict[str, bytes] = {}

    @property
    def dir(self) -> Traversable:
        return self.tree

    @property
    def shown(self) -> str:
        return f"the file tree {escape(self.tree.name)}"

    def where(self, name: str) -> str:
        return f"{escape(self.tree.name)}/{escape(name)} (a file tree)"

    def entries(self) -> dict[str, Traversable]:
        """The tree's entries by name; none for one that can't be listed."""
        if self._entries is None:
            try:
                self._entries = {entry.name: entry for entry in self.tree.iterdir()}
            except (OSError, ValueError):
                self._entries = {}
        return self._entries

    def has(self, name: str) -> bool:
        return name in self.entries()

    def read(self, name: str, limit: int, what: str, *, irregular: ErrorCode, too_large: ErrorCode) -> bytes:
        if (data := self._read.get(name)) is None:
            entry = self.entries().get(name)
            if entry is None:
                raise FileNotFoundError(f"{what} is not there")
            if not entry.is_file():
                raise ModuleError(irregular, f"{what} is not a regular file; it is not read")
            chunks: list[bytes] = []
            size = 0
            with entry.open("rb") as stream:
                while size <= limit and (chunk := stream.read(limit + 1 - size)):
                    chunks.append(chunk)
                    size += len(chunk)
            data = b"".join(chunks)
            if size <= limit:
                self._read[name] = data
        if len(data) > limit:
            raise ModuleError(too_large, f"{what} is larger than {limit // 1024} KiB; it is not read")
        return data

    def key(self) -> str:
        return f"{str(self.tree).rstrip('/')}/{PACKAGE_SCHEMA}"

    def place(self) -> str:
        """Where its schema is, for messages, not escaped."""
        return f"{self.tree.name}/{PACKAGE_SCHEMA} (a file tree)"

    @property
    def name(self) -> str:
        return self.tree.name

    def subtrees(self) -> Iterator[Traversable]:
        yield from self.tree.iterdir()


_Source: TypeAlias = _Directory | _Tree


def _manifest_of(source: _Source) -> Manifest:
    """The checked manifest of a package directory or tree."""
    where = source.where(MANIFEST)
    data = source.read(
        MANIFEST, MAX_MANIFEST_SIZE, f"the manifest {where}", irregular="package-path", too_large="package-manifest"
    )
    return _parse_manifest(data, where, source.dir)


@dataclass(frozen=True, slots=True)
class _Given:
    """A package given to a resolver: its manifest, where it is, and the name it was given under in a mapping."""

    manifest: Manifest
    named: str | None
    source: _Source


class FileResolver:
    """Finds relative files next to the importing file, and the packages it is given (spec §13.3).

    `packages` are package directories, each named by its manifest, or a mapping
    from each package name to its directory (the name must be the manifest's);
    each of `folders` is a directory whose direct subdirectories with a
    `package.haus` are packages (at most 4096 entries). Each of them may also be
    a read-only file tree given in code, an `importlib.resources` `Traversable`
    that isn't a path (`importlib.resources.files("acme_ids") / "schema"` in a zip
    file, say), read by the same rules. Relative directories are relative to
    `base`. Nothing else is searched: given packages are the declared
    dependencies. A given directory without `package.haus`, or a folder that
    isn't a directory, raises `ModuleError` (`import-not-found`) here.

    `root` is the build's root directory (spec §13.3, "The root"), relative to
    `base`; by default `base`, resolved to a real path once. A relative import
    whose `..` names go above it fails with `import-outside-root`, one with a
    symbolic link on its path with `import-not-found` (no link is followed), and
    messages show paths relative to it.

    The given packages are read when the first package is imported. A manifest
    given by its directory is checked then; a subdirectory of a folder whose
    manifest is invalid is ignored, and named when an import isn't found. One
    name has one package: a package given by its directory is used instead of
    the ones in folders with its name, and two different packages with one
    name are an error (`duplicate-package`). Copies whose `package.haus` and
    `schema.haus` are byte for byte the same are one package; their imports
    reach the same packages, since packages are found by name only.

    Each file is read once by a resolver: make a new one to see changed files.
    A resolver may be shared by threads loading schemas at once: it resolves
    one import at a time.
    """

    __slots__ = (
        "_by_name",
        "_dirs",
        "_files",
        "_folders",
        "_invalid",
        "_lock",
        "_modules",
        "_named",
        "_package_keys",
        "_real_base",
        "base",
        "root",
    )

    base: Path
    """Where relative imports of a root file without a key resolve from, and relative directories."""
    root: Path
    """The build's root directory, a real path: relative imports don't reach outside it."""

    def __init__(
        self,
        base: StrPath | None = None,
        packages: Packages = (),
        *,
        folders: Iterable[PackageSource] = (),
        root: StrPath | None = None,
    ) -> None:
        if isinstance(packages, (str, os.PathLike)) or _is_tree(packages):
            raise TypeError("packages is a list of package directories or a mapping from names, not one path")
        self.base = Path(base) if base is not None else Path.cwd()
        self._real_base = Path(os.path.realpath(self.base))
        self.root = Path(os.path.realpath(self._path(root))) if root is not None else self._real_base
        self._files = _Files(self.root)
        """Every file read, by real path: each is read once, whatever it is read as; and the directories listed."""
        self._named: tuple[tuple[str, _Source], ...] = ()
        self._dirs: tuple[_Source, ...] = ()
        if isinstance(packages, Mapping):
            named = cast(Mapping[str, PackageSource], packages)
            self._named = tuple((name, self._source(p)) for name, p in named.items())
        else:
            self._dirs = tuple(self._source(p) for p in packages)
        self._folders = tuple(self._source(f) for f in folders)
        # The configuration is checked here, not at some import.
        for source in (*(s for _, s in self._named), *self._dirs):
            if not source.has(MANIFEST):
                raise ModuleError("import-not-found", f"the package directory {source.shown} has no {MANIFEST}")
        for folder in self._folders:
            if not (folder.tree.is_dir() if isinstance(folder, _Tree) else folder.path.is_dir()):
                raise ModuleError("import-not-found", f"the package folder {folder.shown} is not a directory")
        self._by_name: dict[str, list[_Given]] | None = None
        self._invalid: list[str] = []
        """Subdirectories of folders whose manifests are invalid, as `folder/name`."""
        self._modules: dict[str, ResolvedModule] = {}
        """Every module resolved, by real path for files and by name for packages."""
        self._package_keys: dict[str, str] = {}
        """The key of each package's schema, with the package's name as messages quote it."""
        self._lock = threading.Lock()
        """Held by `resolve`: the caches above are read and filled by one import at a time."""

    def _path(self, path: StrPath) -> Path:
        return Path(os.path.abspath(self.base / path))

    def _source(self, source: PackageSource) -> _Source:
        if _is_tree(source):
            return _Tree(source)
        if isinstance(source, (str, os.PathLike)):
            return _Directory(self._path(source), self._files, source)
        raise TypeError(f"a package is a directory or an importlib.resources Traversable, not {type(source).__name__}")

    def _scan(self, folder: _Source) -> list[tuple[str, _Source]]:
        """The direct subdirectories of `folder` (links to directories too) that list a `package.haus`, each with
        how a message names it: the folder's last name and its own (spec §13.3).

        The folder's last name is the last name of its real path, however the folder was given (`./schemas/` and a
        link to `schemas` are both `schemas`)."""
        found: list[tuple[str, _Source]] = []

        def too_many() -> ModuleError:
            return ModuleError(
                "too-many-files", f"the package folder {folder.shown} has more than {MAX_FOLDER_ENTRIES} entries"
            )

        if isinstance(folder, _Tree):
            for count, entry in enumerate(folder.subtrees(), 1):
                if count > MAX_FOLDER_ENTRIES:
                    raise too_many()
                try:
                    if entry.is_dir() and (package := _Tree(entry)).has(MANIFEST):
                        found.append((f"{escape(folder.name)}/{escape(entry.name)}", package))
                except OSError:  # an entry that can't be read is skipped
                    continue
            return sorted(found, key=lambda f: f[0])
        real = os.path.realpath(folder.path)
        with os.scandir(real) as entries:
            for count, dir_entry in enumerate(entries, 1):
                if count > MAX_FOLDER_ENTRIES:
                    raise too_many()
                try:
                    path = Path(dir_entry.path)
                    if dir_entry.is_dir() and self._files.listed(path, MANIFEST):
                        label = f"{escape(os.path.basename(real))}/{escape(dir_entry.name)}"
                        given = os.path.join(folder.given, dir_entry.name)
                        found.append((label, _Directory(path, self._files, given)))
                except OSError:  # an entry that can't be read is skipped
                    continue
        return sorted(found, key=lambda f: f[0])

    def _given(self) -> dict[str, list[_Given]]:
        """Every given package by name. Read once, at the first package import."""
        if self._by_name is not None:
            return self._by_name
        direct: dict[str, list[_Given]] = {}
        for name, source in self._named:
            direct.setdefault(name, []).append(_Given(_manifest_of(source), name, source))
        for source in self._dirs:
            manifest = _manifest_of(source)
            direct.setdefault(manifest.name, []).append(_Given(manifest, None, source))
        in_folders: dict[str, list[_Given]] = {}
        for folder in self._folders:
            for label, source in self._scan(folder):
                try:
                    manifest = _manifest_of(source)
                except (OSError, ModuleError):
                    self._invalid.append(label)
                    continue
                # Another version in its package.json: skipped the same way (spec §13.3).
                if self._version_mismatch(source, manifest) is not None:
                    self._invalid.append(label)
                    continue
                in_folders.setdefault(manifest.name, []).append(_Given(manifest, None, source))
        # A package given by its directory is used instead of the ones in folders with its name.
        self._by_name = in_folders | direct
        return self._by_name

    def _not_found(self, name: str) -> LookupError:
        given = sorted(self._given())
        listed = ", ".join(quote(n) for n in given[:10]) + (f" and {len(given) - 10} more" if len(given) > 10 else "")
        message = f"package {quote(name)} is not among the packages given to the resolver ({listed or 'none'})"
        if self._invalid:
            dirs = ", ".join(self._invalid[:10])
            more = f" and {len(self._invalid) - 10} more" if len(self._invalid) > 10 else ""
            message += (
                f"; these package directories were skipped (no valid {MANIFEST},"
                f" or another version in their {PACKAGE_JSON}): {dirs}{more}"
            )
        return LookupError(message)

    def _package(self, name: str) -> ResolvedModule:
        if (known := self._modules.get(name)) is not None:
            return known
        given = self._given().get(name)
        if not given:
            raise self._not_found(name)
        for g in given:
            if g.manifest.name != name:
                raise LookupError(
                    f"{g.source.where(MANIFEST)} names the package {quote(g.manifest.name)}, not {quote(name)}"
                )
        for g in given:
            if (mismatch := self._version_mismatch(g.source, g.manifest)) is not None:
                raise ModuleError("package-version", mismatch)
        # Each copy's files are read once; equal bytes are one package.
        copies = [(g, self._package_files(g)) for g in given]
        (first, files), *others = copies
        for other, other_files in others:
            if other_files != files:
                raise ModuleError(
                    "duplicate-package",
                    f"two packages are called {quote(name)}: {quote(first.manifest.version)} in {first.source.shown}"
                    f" and {quote(other.manifest.version)} in {other.source.shown}; give one of them",
                )
        text = _decode(files[1], f"the {PACKAGE_SCHEMA} of {quote(name)}")
        module = ResolvedModule(
            first.source.key(), f"{name}@{first.manifest.major}", text, first.manifest.version, first.source.place()
        )
        self._modules[name] = module
        self._package_keys[module.key] = quote(name)
        return module

    def _version_mismatch(self, source: _Source, manifest: Manifest) -> str | None:
        """Why the `package.json` next to the manifest gives another version, or None if it doesn't (spec §13.3).

        A package given explicitly is checked too, as npm would install it: a different version is
        `package-version` for a package given by its directory, and skips a package of a folder.
        Python has no npm mode, so the `package.json` only gives a version, and one that can't be read is
        ignored (spec §13.3, "Package versions"): a link or not a regular file, larger than 1 MiB, not
        valid JSON, not an object, or a `version` that isn't a string gives no version. The message
        quotes the version only when it is a semantic version.
        """
        if not source.has(PACKAGE_JSON):
            return None
        try:
            data = source.read(
                PACKAGE_JSON,
                MAX_PACKAGE_JSON_SIZE,
                f"{quote(manifest.name)}: its {PACKAGE_JSON}",
                irregular="package-path",
                too_large="file-too-large",
            )
            package = json.loads(data.decode("utf-8"))
        except (OSError, ModuleError, ValueError, RecursionError):  # JSONDecodeError and UnicodeDecodeError too
            return None
        match package:
            case {"version": str(version)} if version != manifest.version:
                theirs = (
                    f"version {quote(version)}"
                    if _SEMVER.fullmatch(version)
                    else "a version that isn't a semantic version"
                )
                return (
                    f"{quote(manifest.name)}: its {MANIFEST} says version {quote(manifest.version)},"
                    f" its {PACKAGE_JSON} {theirs} ({source.shown})"
                )
            case _:
                return None

    def _package_files(self, given: _Given) -> tuple[bytes, bytes]:
        """The bytes of a package's `package.haus` and `schema.haus`, regular files that aren't links."""
        source, name = given.source, quote(given.manifest.name)
        if not source.has(PACKAGE_SCHEMA):
            raise FileNotFoundError(f"{name} has no {PACKAGE_SCHEMA} next to its manifest ({source.shown})")
        return (
            source.read(
                MANIFEST,
                MAX_MANIFEST_SIZE,
                f"{name}: its {MANIFEST}",
                irregular="package-path",
                too_large="package-manifest",
            ),
            source.read(
                PACKAGE_SCHEMA,
                MAX_SCHEMA_SIZE,
                f"{name}: its {PACKAGE_SCHEMA}",
                irregular="package-path",
                too_large="file-too-large",
            ),
        )

    def _walk(self, directory: Path, names: list[str]) -> Path:
        """The file `names` name from the real directory `directory`, walked down one name at a time (spec §13.3,
        "Resolution"): each spelled as its directory lists it, also where the file system ignores case or Unicode
        normalization (`./Common` isn't `common.schema.haus`), and none a symbolic link, checked without following
        it, so nothing behind a link is looked at. Each name but the last is a directory. The path reached has no
        links: it is a real path. A directory that can't be listed lists nothing.
        """
        path = directory
        for i, part in enumerate(names):
            if not self._files.listed(path, part):
                wanted = self._files.shown(directory.joinpath(*names))
                raise FileNotFoundError(
                    f"file not found: {wanted} (no {escape(part)} in {self._files.shown(path)},"
                    " spelled as the directory lists it)"
                )
            path = path / part
            try:
                st = os.lstat(path)
            except OSError:
                raise FileNotFoundError(f"file not found: {self._files.shown(path)}") from None
            if _is_link(st):
                raise ModuleError(
                    "import-not-found",
                    f"{escape(part)} is a symbolic link; a relative import follows no link,"
                    " and nothing behind it is read",
                )
            if i < len(names) - 1 and not stat.S_ISDIR(st.st_mode):
                raise FileNotFoundError(f"file not found: {self._files.shown(path)} is not a directory")
        return path

    def _in_package(self, path: Path) -> None:
        """Raises if the real path `path` is in a package's directory (spec §13.3, "Imports"): the directories from
        its own up to the root, the root included, each a package's when it lists `package.haus`. One that can't be
        listed can't show whether it is a package's: the import fails (`import-not-found`), never passes."""
        for directory in _ancestors(path.parent):
            if not directory.is_relative_to(self.root):
                return
            names = self._files.listing(directory)
            if names is None:
                raise ModuleError(
                    "import-not-found",
                    f"whether {self._files.shown(directory)} is a package's directory can't be checked"
                    " (it can't be listed); it is not read",
                )
            if MANIFEST in names:
                raise ModuleError(
                    "package-path",
                    f"the file is in the package directory {self._files.shown(directory)}:"
                    " import the package by its name",
                )

    def _file(self, module: str, from_key: str | None) -> ResolvedModule:
        files = self._files
        # The checks in the order of spec §13.3 ("Resolution"): the path's syntax first.
        if not FILE_PATH.fullmatch(module):
            raise ModuleError("schema-syntax", f"{escape(module)} is not a file path")
        # A package is one file: its schema imports other packages by name (also one in a file tree). Whether the
        # importing file is a package's schema is how it was read (a package, or an entry file read as a package's
        # schema), not what is above it on the disk: an application's file may sit in a package's directory.
        if from_key is not None and (name := self._package_keys.get(from_key)) is not None:
            raise ModuleError("package-path", f"the schema of {name} can't import files, only packages by name")
        # `..` only at the start (grammar `path`): up from the importing file's real directory, then down.
        directory = Path(os.path.realpath(Path(from_key).parent)) if from_key is not None else self._real_base
        parts = module.split("/")
        ups = parts.count("..")
        names = parts[ups:] if ups else parts[1:]
        names[-1] += EXTENSION
        start = directory
        for _ in range(ups):
            start = start.parent
        # Above the root by its `..` alone, on the text: rejected before anything is looked at (spec §13.3,
        # "The root"). As the walk follows no link, the file reached is inside the root too.
        if not start.is_relative_to(self.root):
            raise ModuleError(
                "import-outside-root",
                f"{module} goes above the build's root directory: a relative import reaches only files inside it"
                " (give the build a root option that contains both files)",
            )
        path = self._walk(start, names)
        # An application's file doesn't reach into a package: it imports the package by name.
        self._in_package(path)
        if (known := self._modules.get(str(path))) is not None:
            return known
        module_ = _read_module(path, self.base, files)
        self._modules[module_.key] = module_
        return module_

    @classmethod
    def for_root(
        cls,
        path: StrPath,
        packages: Packages = (),
        *,
        folders: Iterable[PackageSource] = (),
        root: StrPath | None = None,
    ) -> tuple[ResolvedModule, FileResolver]:
        """A root schema file (see `read_module`), and a resolver for its imports that has read it.

        Its relative imports and relative directories are relative to the file's real directory, and so is
        `root`, the build's root directory, which must contain the file (`import-outside-root` otherwise);
        by default the file's real directory. Imported (in a cycle), the root is not read again.
        """
        entry = Path(os.path.realpath(path))
        base = entry.parent
        real_root = Path(os.path.realpath(base / root)) if root is not None else base
        if not entry.is_relative_to(real_root):
            raise ModuleError(
                "import-outside-root",
                f"the build's root directory doesn't contain the schema file it starts from ({escape(entry.name)})",
            )
        resolver = cls(base, packages, folders=folders, root=real_root)
        module = _read_module(entry, None, resolver._files)
        resolver._modules[module.key] = module
        # An entry file read as a package's schema (`schema.haus` next to a manifest) imports no files either.
        if (package := _package_of(entry, resolver._files)) is not None:
            resolver._package_keys[module.key] = quote(package.name)
        return module, resolver

    def resolve(self, module: str, from_key: str | None) -> ResolvedModule:
        with self._lock:
            if module.startswith(("./", "../")):
                return self._file(module, from_key)
            # The package directory may be a symbolic link (pnpm, workspaces); its files may not be.
            return self._package(module)


def installed_package(name: str) -> Path:
    """The directory of an installed Python package (e.g. one that ships a schema package), without importing it.

    FileResolver(packages=[installed_package("haus_money")])

    For a package installed inside a zip file, give `importlib.resources.files(name)` (a file tree) instead.
    """
    spec = importlib.util.find_spec(name)
    if spec is None:
        raise LookupError(f"no installed Python package {name}")
    if spec.submodule_search_locations:
        return Path(next(iter(spec.submodule_search_locations)))
    if spec.origin is None:
        raise LookupError(f"Python package {name} has no location")
    return Path(spec.origin).parent

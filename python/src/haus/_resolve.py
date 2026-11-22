"""Resolving schema imports from the file system (spec §13.3).

    import ./common (Address)      → common.schema.haus, next to the importing file
    import @haus-fmt/money (Money) → the package given for "@haus-fmt/money"

Python has no scoped package names, so packages are never searched for (no
`node_modules`, no global folders): the application gives its schema packages
explicitly, as directories (`packages=`, named by their manifests), as a
mapping from names to directories, or as folders whose direct subdirectories
are packages (`folders=`). Given packages count as declared dependencies.
`installed_package` finds the directory of an installed Python package that
ships one, without importing it. A package directory holds a manifest,
`package.haus`, and one schema file, `schema.haus`:

    { name: "@haus-fmt/money", version: "1.2.0" }

The manifest gives types their identity in every language (`@haus-fmt/money@1#Money`).
A package that is also an npm package has a `package.json` next to its manifest: its
`version`, when it is a string, must be the manifest's (`package-version`), so that a
package published with two versions is caught; nothing else in it is read.
A package's schema imports other packages by name, never files. Files outside
a schema package are identified by the nearest `pyproject.toml` project name
and their path (`my-app/schemas/order#Root`), or without a project by their
path relative to the root schema file's directory (`billing/common#Address`);
their relative imports can't reach into a package directory.

Files are read as spec §13.3 says: a package's `package.haus`, `schema.haus`
and `package.json` are regular files, never links (its directory may be one),
opened without following links, checked on the opened file and read from it; a
schema file and a `package.json` are at most 1 MiB (`file-too-large`), and each file is read once,
by its real path, also when it is needed in two roles (a `pyproject.toml` that
is a link to a schema file): every use sees the same bytes, and the checks of
each role still apply to it.
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
from pathlib import Path
from typing import TypeAlias, cast

from ._error_codes import ErrorCode
from ._errors import HausError
from ._parser import Parser
from ._schema_file import ModuleError, ResolvedModule, escape, quote
from ._value import Record, String

StrPath: TypeAlias = str | os.PathLike[str]
"""A file system path, as a string or a `Path`."""
Packages: TypeAlias = Mapping[str, StrPath] | Iterable[StrPath]
"""Schema packages given explicitly: package directories (named by their manifests),
or a mapping from each package name to its directory."""

MANIFEST = "package.haus"
"""The file name of a schema package's manifest."""
PACKAGE_SCHEMA = "schema.haus"
"""The file name of a schema package's one schema file, next to its manifest."""
PACKAGE_JSON = "package.json"
"""The file name of npm's package file, which may sit next to a manifest: its `version` is checked."""
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
_OPEN_FLAGS = os.O_RDONLY | _NOFOLLOW | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_BINARY", 0)
"""Never through a link; a FIFO doesn't block the open (its type is checked right after)."""


@dataclass(frozen=True, slots=True)
class Manifest:
    """A schema package's `package.haus`. Fields other than `name` and `version` are ignored."""

    name: str
    version: str
    dir: Path
    """The package directory, with the manifest and `schema.haus`."""

    @property
    def major(self) -> str:
        return self.version.split(".")[0]


def _read_file(path: Path, limit: int, what: str, *, irregular: ErrorCode, too_large: ErrorCode) -> bytes:
    """The bytes of the regular file `path`, which is not a link, at most `limit` of them (spec §13.3).

    Opened without following a link and checked on the opened file, so that
    the file checked is the file read. Where there is no `O_NOFOLLOW`
    (Windows), `lstat` first and the opened file must be the same file.
    Raises `ModuleError` (`irregular`, `too_large`) without reading the file,
    and `OSError` (such as `FileNotFoundError`) for one that can't be opened.
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
    """Every file read for one schema, by real path: each is read once (spec §13.3)."""

    __slots__ = ("_read",)

    def __init__(self) -> None:
        self._read: dict[str, bytes] = {}

    def read(self, path: Path, limit: int, what: str, *, irregular: ErrorCode, too_large: ErrorCode) -> bytes:
        """`_read_file`, or the bytes already read from the same real path, checked for this use."""
        real = os.path.realpath(path)
        if (data := self._read.get(real)) is None:
            data = self._read[real] = _read_file(path, limit, what, irregular=irregular, too_large=too_large)
            return data
        # Read in another role: this use's checks, on the path it uses and the bytes read.
        if not stat.S_ISREG(os.lstat(path).st_mode):
            raise ModuleError(irregular, f"{what} is a symbolic link or not a regular file; it is not read")
        if len(data) > limit:
            raise ModuleError(too_large, f"{what} is larger than {limit // 1024} KiB; it is not read")
        return data


def _decode(data: bytes, what: str) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise ModuleError("invalid-utf8", f"{what} is not UTF-8") from None


def _invalid(path: Path, why: str) -> ModuleError:
    return ModuleError("package-manifest", f"{escape(str(path))} is not a valid manifest: {why}")


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
    data = files.read(
        path,
        MAX_MANIFEST_SIZE,
        f"the manifest {escape(str(path))}",
        irregular="package-path",
        too_large="package-manifest",
    )
    try:
        values = Parser(data.decode("utf-8")).parse_sequence()
    except UnicodeDecodeError:
        raise _invalid(path, "it is not UTF-8") from None
    except HausError as e:  # its own message could quote the file
        raise _invalid(path, f"it is not haus ({e.code})") from None
    match values:
        case [Record(fields)]:
            pass
        case _:
            raise _invalid(path, "a manifest is one record, { name: …, version: … }")

    def text(key: str) -> str:
        match fields.get(key):
            case String(value):
                return value
            case _:
                raise _invalid(path, f"it needs a string field {key}")

    manifest = Manifest(text("name"), text("version"), path.parent)
    if not _NAME.fullmatch(manifest.name) or len(manifest.name) > _MAX_NAME_LENGTH:
        raise _invalid(
            path,
            f'the name "{quote(manifest.name)}" isn\'t @org/name in lowercase'
            " (a-z, 0-9, -, ., _, no part node_modules, at most 214 characters)",
        )
    if not _SEMVER.fullmatch(manifest.version):
        raise _invalid(path, f'the version "{quote(manifest.version)}" isn\'t a semantic version, like 1.2.0')
    return manifest


def schema_path(manifest: Manifest) -> Path:
    """The package's schema file, `schema.haus` next to its manifest (spec §13.3).

    Checked, not read: raises `FileNotFoundError` if it is missing, and
    `ModuleError` (`package-path`) for a symbolic link or a file that isn't regular.
    """
    path = manifest.dir / PACKAGE_SCHEMA
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        raise FileNotFoundError(
            f"{quote(manifest.name)} has no {PACKAGE_SCHEMA} next to its manifest ({escape(str(manifest.dir))})"
        ) from None
    if not stat.S_ISREG(st.st_mode):
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


def _project_name(pyproject: Path, files: _Files) -> str | None:
    """The project name in a `pyproject.toml` (read through links), if it has one."""
    if not pyproject.is_file():
        return None
    try:
        what = f"the project file {escape(str(pyproject))}"
        text = files.read(
            Path(os.path.realpath(pyproject)),
            MAX_SCHEMA_SIZE,
            what,
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


def _package_dir(file: Path) -> Path | None:
    """The package directory a file is in, if any: the nearest directory above it with a manifest."""
    return next((d for d in _ancestors(file.parent) if os.path.lexists(d / MANIFEST)), None)


def _package_of(file: Path, files: _Files) -> Manifest | None:
    """The manifest of the package whose schema is `file`, if it is one (`schema.haus` next to a manifest)."""
    m = file.parent / MANIFEST
    return _read_manifest(m, files) if file.name == PACKAGE_SCHEMA and os.path.lexists(m) else None


def _package_name(directory: Path, files: _Files) -> str:
    """The name of the package in `directory`, or the directory if its manifest can't be read."""
    try:
        return quote(_read_manifest(directory / MANIFEST, files).name)
    except (OSError, ModuleError):
        return escape(str(directory))


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
    default the file's own directory (`order`, `billing/common`).
    Different files have different identities, apart from files of two projects
    with the same name.
    """
    file, files = Path(os.path.abspath(path)), _Files()
    return _identify(file, _package_of(file, files), root, files)


def _identify(file: Path, package: Manifest | None, root: StrPath | None, files: _Files) -> str:
    if package is not None:
        return f"{package.name}@{package.major}"
    file = file.resolve()
    for d in _ancestors(file.parent):
        if (name := _project_name(d / "pyproject.toml", files)) is not None:
            return f"{name}/{_stem(file.relative_to(d))}"
    return _stem(_relative(file, Path(root).resolve() if root is not None else file.parent))


def read_module(path: StrPath, root: StrPath | None = None) -> ResolvedModule:
    """A schema file as a resolved module: its key (real path), identity (see `identify`), text and package version.

    The file is regular and at most 1 MiB (`file-too-large`); it is read from
    its real path, without following links.
    """
    return _read_module(path, root, _Files())


def _read_module(path: StrPath, root: StrPath | None, files: _Files) -> ResolvedModule:
    file = Path(os.path.abspath(path))
    package = _package_of(file, files)
    key = file.resolve()
    what = f"the schema file {escape(str(key))}"
    data = files.read(key, MAX_SCHEMA_SIZE, what, irregular="import-not-found", too_large="file-too-large")
    identity = _identify(file, package, root, files)
    return ResolvedModule(str(key), identity, _decode(data, what), package.version if package else None)


@dataclass(frozen=True, slots=True)
class _Given:
    """A package given to a resolver: its manifest, and the name it was given under in a mapping."""

    manifest: Manifest
    named: str | None


class FileResolver:
    """Finds relative files next to the importing file, and the packages it is given (spec §13.3).

    `packages` are package directories, each named by its manifest, or a mapping
    from each package name to its directory (the name must be the manifest's);
    each of `folders` is a directory whose direct subdirectories with a
    `package.haus` are packages (at most 4096 entries). Relative directories
    are relative to `base`. Nothing else is searched: given packages are the
    declared dependencies. A given directory without `package.haus`, or a
    folder that isn't a directory, raises `ModuleError` (`import-not-found`) here.

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
        "_listings",
        "_lock",
        "_modules",
        "_named",
        "base",
    )

    base: Path
    """Where relative imports of a root file without a key resolve from, and relative directories."""

    def __init__(
        self, base: StrPath | None = None, packages: Packages = (), *, folders: Iterable[StrPath] = ()
    ) -> None:
        if isinstance(packages, (str, os.PathLike)):
            raise TypeError("packages is a list of package directories or a mapping from names, not one path")
        self.base = Path(base) if base is not None else Path.cwd()
        self._named: tuple[tuple[str, Path], ...] = ()
        self._dirs: tuple[Path, ...] = ()
        if isinstance(packages, Mapping):
            named = cast(Mapping[str, StrPath], packages)
            self._named = tuple((name, self._path(p)) for name, p in named.items())
        else:
            self._dirs = tuple(self._path(p) for p in packages)
        self._folders = tuple(self._path(f) for f in folders)
        # The configuration is checked here, not at some import.
        for directory in (*(d for _, d in self._named), *self._dirs):
            if not os.path.lexists(directory / MANIFEST):
                raise ModuleError(
                    "import-not-found", f"the package directory {escape(str(directory))} has no {MANIFEST}"
                )
        for folder in self._folders:
            if not folder.is_dir():
                raise ModuleError("import-not-found", f"the package folder {escape(str(folder))} is not a directory")
        self._by_name: dict[str, list[_Given]] | None = None
        self._invalid: list[Path] = []
        """Subdirectories of folders whose manifests are invalid."""
        self._files = _Files()
        """Every file read, by real path: each is read once, whatever it is read as."""
        self._modules: dict[str, ResolvedModule] = {}
        """Every module resolved, by real path for files and by name for packages."""
        self._listings: dict[Path, frozenset[str]] = {}
        self._lock = threading.Lock()
        """Held by `resolve`: the caches above are read and filled by one import at a time."""

    def _path(self, path: StrPath) -> Path:
        return Path(os.path.abspath(self.base / path))

    def _scan(self, folder: Path) -> list[Path]:
        """The direct subdirectories of `folder` (links to directories too) that have a `package.haus`.

        Under the folder's real path, so that a skipped one is named by its last name however the folder
        was given (`./schemas/` and a link to `schemas` are both `schemas`, spec §13.3)."""
        found: list[Path] = []
        with os.scandir(os.path.realpath(folder)) as entries:
            for count, entry in enumerate(entries, 1):
                if count > MAX_FOLDER_ENTRIES:
                    raise ModuleError(
                        "too-many-files",
                        f"the package folder {escape(str(folder))} has more than {MAX_FOLDER_ENTRIES} entries",
                    )
                try:
                    if entry.is_dir() and os.path.lexists(os.path.join(entry.path, MANIFEST)):
                        found.append(Path(entry.path))
                except OSError:  # an entry that can't be read is skipped
                    continue
        return sorted(found)

    def _given(self) -> dict[str, list[_Given]]:
        """Every given package by name. Read once, at the first package import."""
        if self._by_name is not None:
            return self._by_name
        direct: dict[str, list[_Given]] = {}
        for name, directory in self._named:
            direct.setdefault(name, []).append(_Given(_read_manifest(directory / MANIFEST, self._files), name))
        for directory in self._dirs:
            manifest = _read_manifest(directory / MANIFEST, self._files)
            direct.setdefault(manifest.name, []).append(_Given(manifest, None))
        in_folders: dict[str, list[_Given]] = {}
        for folder in self._folders:
            for directory in self._scan(folder):
                try:
                    manifest = _read_manifest(directory / MANIFEST, self._files)
                except (OSError, ModuleError):
                    self._invalid.append(directory)
                    continue
                # Another version in its package.json: skipped the same way (spec §13.3).
                if self._version_mismatch(manifest) is not None:
                    self._invalid.append(directory)
                    continue
                in_folders.setdefault(manifest.name, []).append(_Given(manifest, None))
        # A package given by its directory is used instead of the ones in folders with its name.
        self._by_name = in_folders | direct
        return self._by_name

    def _not_found(self, name: str) -> LookupError:
        given = sorted(self._given())
        listed = ", ".join(quote(n) for n in given[:10]) + (f" and {len(given) - 10} more" if len(given) > 10 else "")
        message = f"package {quote(name)} is not among the packages given to the resolver ({listed or 'none'})"
        if self._invalid:
            dirs = ", ".join(escape(str(d)) for d in self._invalid[:10])
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
                    f"{escape(str(g.manifest.dir / MANIFEST))} names the package {quote(g.manifest.name)},"
                    f" not {quote(name)}"
                )
        for g in given:
            self._check_version(g.manifest)
        # Each copy's files are read once; equal bytes are one package.
        copies = [(g.manifest, self._package_files(g.manifest)) for g in given]
        (first, files), *others = copies
        for other, other_files in others:
            if other_files != files:
                raise ModuleError(
                    "duplicate-package",
                    f"two packages are called {quote(name)}: {quote(first.version)} in {escape(str(first.dir))}"
                    f" and {quote(other.version)} in {escape(str(other.dir))}; give one of them",
                )
        key = Path(os.path.realpath(first.dir)) / PACKAGE_SCHEMA
        text = _decode(files[1], f"the {PACKAGE_SCHEMA} of {quote(name)}")
        module = ResolvedModule(str(key), f"{name}@{first.major}", text, first.version)
        self._modules[name] = module
        return module

    def _check_version(self, manifest: Manifest) -> None:
        """The version of the `package.json` next to the manifest, if it has one, is the manifest's (spec §13.3).

        A package given explicitly is checked too, as npm would install it. A different version is
        `package-version` (see `_version_mismatch`).
        """
        if (mismatch := self._version_mismatch(manifest)) is not None:
            raise ModuleError("package-version", mismatch)

    def _version_mismatch(self, manifest: Manifest) -> str | None:
        """Why the `package.json` next to the manifest gives another version, or None if it doesn't.

        Python has no npm mode, so the `package.json` only gives a version, and one that can't be read is
        ignored (spec §13.3, "Package versions"): a link or not a regular file, larger than 1 MiB, not
        valid JSON, not an object, or a `version` that isn't a string gives no version. The message
        quotes the version only when it is a semantic version.
        """
        path = manifest.dir / PACKAGE_JSON
        if not os.path.lexists(path):
            return None
        try:
            data = self._files.read(
                path,
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
                    f" its {PACKAGE_JSON} {theirs} ({escape(str(manifest.dir))})"
                )
            case _:
                return None

    def _package_files(self, manifest: Manifest) -> tuple[bytes, bytes]:
        """The bytes of a package's `package.haus` and `schema.haus`, regular files that aren't links."""
        schema = schema_path(manifest)
        what = f"{quote(manifest.name)}: its"
        return (
            self._files.read(
                manifest.dir / MANIFEST,
                MAX_MANIFEST_SIZE,
                f"{what} {MANIFEST}",
                irregular="package-path",
                too_large="package-manifest",
            ),
            self._files.read(
                schema,
                MAX_SCHEMA_SIZE,
                f"{what} {PACKAGE_SCHEMA}",
                irregular="package-path",
                too_large="file-too-large",
            ),
        )

    def _listing(self, directory: Path) -> frozenset[str]:
        if directory not in self._listings:
            try:
                self._listings[directory] = frozenset(os.listdir(directory))
            except OSError:
                self._listings[directory] = frozenset()
        return self._listings[directory]

    def _spelled(self, directory: Path, module: str) -> Path:
        """The file `module` names from `directory`, each name spelled as its directory lists it (spec §13.3).

        Also where the file system ignores case or Unicode normalization: `./Common` isn't `common.schema.haus`.
        """
        path = directory
        for part in (module + EXTENSION).split("/"):
            if part in ("", "."):
                continue
            if part == "..":
                path = path.parent
                continue
            if part not in self._listing(path):
                wanted = Path(os.path.normpath(directory / (module + EXTENSION)))
                raise FileNotFoundError(
                    f"file not found: {escape(str(wanted))} (no {escape(part)} in {escape(str(path))},"
                    " spelled as the directory lists it)"
                )
            path = path / part
        return path

    def _file(self, module: str, from_key: str | None) -> ResolvedModule:
        # A package is one file: its schema imports other packages by name.
        if from_key is not None and (package := _package_dir(Path(os.path.abspath(from_key)))) is not None:
            name = _package_name(package, self._files)
            raise ModuleError("package-path", f"the schema of {name} can't import files, only packages by name")
        directory = Path(os.path.abspath(Path(from_key).parent if from_key is not None else self.base))
        path = self._spelled(directory, module)
        real = path.resolve()
        # An application's file doesn't reach into a package: it imports the package by name.
        if (into := _package_dir(path) or _package_dir(real)) is not None:
            raise ModuleError(
                "package-path",
                f"the file is in the package directory {escape(str(into))}: import the package by its name",
            )
        if not real.name.endswith(EXTENSION):  # a link to another kind of file: not read
            raise FileNotFoundError(
                f"{escape(str(path))} is not a schema file: its real name doesn't end in {EXTENSION}"
            )
        if (known := self._modules.get(str(real))) is not None:
            return known
        module_ = _read_module(real, self.base, self._files)
        self._modules[module_.key] = module_
        return module_

    @classmethod
    def for_root(
        cls, path: StrPath, packages: Packages = (), *, folders: Iterable[StrPath] = ()
    ) -> tuple[ResolvedModule, FileResolver]:
        """A root schema file (see `read_module`), and a resolver for its imports that has read it.

        Its relative imports and relative directories are relative to the file's real directory.
        Imported (in a cycle), the root is not read again.
        """
        files = _Files()
        module = _read_module(path, None, files)
        resolver = cls(os.path.dirname(module.key), packages, folders=folders)
        resolver._files = files
        resolver._modules[module.key] = module
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
    """
    spec = importlib.util.find_spec(name)
    if spec is None:
        raise LookupError(f"no installed Python package {name}")
    if spec.submodule_search_locations:
        return Path(next(iter(spec.submodule_search_locations)))
    if spec.origin is None:
        raise LookupError(f"Python package {name} has no location")
    return Path(spec.origin).parent

"""Resolving schema imports from the file system (spec §13.3).

    import ./common (Address)      → common.schema.haus, next to the importing file
    import @haus-fmt/money (Money) → the package directory given for "@haus-fmt/money"

Python has no scoped package names, so packages are never searched for: the
application lists its direct schema dependencies, by name, with their
directories (`packages=`). `installed_package` finds the directory of an
installed Python package that ships one, without importing it. A package
directory holds a manifest, `package.haus`, and one schema file, `schema.haus`:

    { name: "@haus-fmt/money", version: "1.2.0" }

The manifest gives types their identity in every language (`@haus-fmt/money@1#Money`).
A package's schema imports other packages by name, never files. Files outside
a schema package are identified by the nearest `pyproject.toml` project name
and their path (`my-app/schemas/order#Root`); their relative imports can't
reach into a package directory.
"""

from __future__ import annotations

import importlib.util
import os
import re
import tomllib
from collections.abc import Iterator, Mapping
from dataclasses import dataclass, field
from functools import cache
from pathlib import Path

from ._parser import Parser
from ._schema_file import ModuleError, ResolvedModule
from ._value import Record, String

MANIFEST = "package.haus"
"""The file name of a schema package's manifest."""
PACKAGE_SCHEMA = "schema.haus"
"""The file name of a schema package's one schema file, next to its manifest."""
EXTENSION = ".schema.haus"

_NAME = re.compile(r"@[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
_SEMVER = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+.*")


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


def _check_inside(root: Path, path: Path, what: str) -> None:
    """A file read for a package stays inside it (spec §13.3).

    `path`, in the package directory `root`, is still inside it after resolving
    symbolic links. Checked before the file is read.
    """
    if path.exists() and not path.resolve().is_relative_to(root.resolve()):
        raise ModuleError("package-path", f"{what} is a symbolic link to a file outside the package {root}")


@cache
def read_manifest(path: Path) -> Manifest:
    """Read and check a schema package manifest. Raises `ValueError`, or `ModuleError` for one outside its package."""
    path = Path(os.path.abspath(path))
    _check_inside(path.parent, path, f"the manifest {path}")
    values = Parser(path.read_text("utf-8")).parse_sequence()
    match values:
        case [Record(fields)]:
            pass
        case _:
            raise ValueError(f"{path}: a manifest is one record")

    def text(key: str) -> str:
        match fields.get(key):
            case String(value):
                return value
            case _:
                raise ValueError(f"{path}: the manifest needs a string field {key}")

    manifest = Manifest(text("name"), text("version"), path.parent)
    if not _NAME.fullmatch(manifest.name):
        raise ValueError(f"{path}: name must look like @org/name, found {manifest.name}")
    if not _SEMVER.fullmatch(manifest.version):
        raise ValueError(f"{path}: version must be semver (1.2.0), found {manifest.version}")
    return manifest


def schema_path(manifest: Manifest) -> Path:
    """The package's schema file, `schema.haus` next to its manifest (spec §13.3).

    Checked, not read: raises `FileNotFoundError` if it is missing, and
    `ModuleError` (`package-path`) for a symbolic link to a file outside the package.
    """
    path = manifest.dir / PACKAGE_SCHEMA
    if not path.is_file():
        raise FileNotFoundError(f"{manifest.name} has no {PACKAGE_SCHEMA} next to its manifest ({manifest.dir})")
    _check_inside(manifest.dir, path, f"{manifest.name}: its {PACKAGE_SCHEMA}")
    return path


def _ancestors(directory: Path) -> Iterator[Path]:
    yield directory
    yield from directory.parents


def _stem(path: Path) -> str:
    return path.as_posix().removesuffix(EXTENSION)


@cache
def _project_name(pyproject: Path) -> str | None:
    try:
        data = tomllib.loads(pyproject.read_text("utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return None
    match data:
        case {"project": {"name": str(name)}}:
            return name
        case _:
            return None


def _package_dir(file: Path) -> Path | None:
    """The package directory a file is in, if any: the nearest directory above it with a manifest."""
    return next((d for d in _ancestors(file.parent) if (d / MANIFEST).is_file()), None)


def _package_of(file: Path) -> Manifest | None:
    """The manifest of the package whose schema is `file`, if it is one (`schema.haus` next to a manifest)."""
    m = file.parent / MANIFEST
    return read_manifest(m) if file.name == PACKAGE_SCHEMA and m.is_file() else None


def _package_name(directory: Path) -> str:
    """The name of the package in `directory`, or the directory if its manifest can't be read."""
    try:
        return read_manifest(directory / MANIFEST).name
    except (OSError, ValueError):
        return str(directory)


def identify(path: str | Path) -> str:
    """The identity of a schema file (spec §13.3).

    `@haus-fmt/money@1` for a package's `schema.haus`, else `my-app/schemas/order`.
    """
    file = Path(os.path.abspath(path))
    if (manifest := _package_of(file)) is not None:
        return f"{manifest.name}@{manifest.major}"
    file = file.resolve()
    for d in _ancestors(file.parent):
        if (p := d / "pyproject.toml").is_file() and (name := _project_name(p)) is not None:
            return f"{name}/{_stem(file.relative_to(d))}"
    # Outside any project: just the file name.
    return _stem(Path(file.name))


def read_module(path: str | Path) -> ResolvedModule:
    """A schema file as a resolved module: its key (real path), identity, text and package version."""
    file = Path(os.path.abspath(path))
    package = _package_of(file)
    key = file.resolve()
    return ResolvedModule(str(key), identify(file), key.read_text("utf-8"), package.version if package else None)


@dataclass(frozen=True, slots=True)
class FileResolver:
    """Finds relative files next to the importing file, and the packages listed in `packages`.

    `packages` maps a package name to its directory (the one with `package.haus`):
    the project's direct schema dependencies (spec §13.3). Nothing else is searched.
    """

    base: Path = field(default_factory=Path.cwd)
    """Where relative imports of a root file without a key resolve from."""
    packages: Mapping[str, Path] = field(default_factory=dict[str, Path])

    def resolve(self, module: str, from_key: str | None) -> ResolvedModule:
        directory = Path(from_key).parent if from_key is not None else self.base
        if module.startswith(("./", "../")):
            # A package is one file: its schema imports other packages by name.
            if from_key is not None and (package := _package_dir(Path(os.path.abspath(from_key)))) is not None:
                name = _package_name(package)
                raise ModuleError("package-path", f"the schema of {name} can't import files, only packages by name")
            path = Path(os.path.normpath(Path(os.path.abspath(directory)) / (module + EXTENSION)))
            # An application's file doesn't reach into a package: it imports the package by name.
            into = _package_dir(path) or (_package_dir(path.resolve()) if path.exists() else None)
            if into is not None:
                raise ModuleError(
                    "package-path", f"the file is in the package directory {into}: import the package by its name"
                )
            if not path.is_file():
                raise FileNotFoundError(f"file not found: {path}")
            return read_module(path)
        package_dir = self.packages.get(module)
        if package_dir is None:
            listed = ", ".join(self.packages) or "none"
            raise LookupError(f"package {module} is not among the packages given to the resolver ({listed})")
        # The package directory may be a symbolic link (pnpm, workspaces); its files may not leave it.
        manifest_path = Path(os.path.abspath(self.base / package_dir)) / MANIFEST
        if not manifest_path.is_file():
            raise FileNotFoundError(f"no {MANIFEST} in {manifest_path.parent}")
        manifest = read_manifest(manifest_path)
        if manifest.name != module:
            raise ValueError(f"{manifest_path} names the package {manifest.name}, not {module}")
        return read_module(schema_path(manifest))


def installed_package(name: str) -> Path:
    """The directory of an installed Python package (e.g. one that ships a schema package), without importing it.

    FileResolver(packages={"@haus-fmt/money": installed_package("haus_money")})
    """
    spec = importlib.util.find_spec(name)
    if spec is None:
        raise LookupError(f"no installed Python package {name}")
    if spec.submodule_search_locations:
        return Path(next(iter(spec.submodule_search_locations)))
    if spec.origin is None:
        raise LookupError(f"Python package {name} has no location")
    return Path(spec.origin).parent

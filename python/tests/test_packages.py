"""A schema package is a directory with `package.haus` and `schema.haus` (spec §13.3).

Every file read for it stays inside it, also through symbolic links; its
schema imports other packages by name, never files; application files don't
import files inside a package directory. Errors have the code `package-path`
and never quote a file that wasn't read. And imports name only major versions.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from haus.schema import FileResolver, HausSchemaFileError, compile_schema, load_schema

SECRET = "API_TOKEN=hunter2"
MONEY = "type Money = closed < Money Decimal Currency >\ntype Currency = < >\n"
MANIFEST = '{ name: "@acme/evil", version: "1.2.0" }'
symlinks = pytest.mark.skipif(os.name == "nt", reason="needs symbolic links")


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, "utf-8")


class App:
    """An app, app/main.schema.haus with `main`, next to a directory `secret` that must never be read.

    It gets `@acme/evil` from app/vendor/evil, with `files`.
    """

    def __init__(self, root: Path, files: dict[str, str], main: str = "import @acme/evil (Money)\ntype Root = Money\n"):
        self.root = root
        write(root / "secret" / "creds.txt", SECRET)
        write(root / "secret" / "creds.schema.haus", SECRET)
        self.package.mkdir(parents=True)
        for path, text in files.items():
            write(self.package / path, text)
        write(self.main, main)

    @property
    def package(self) -> Path:
        return self.root / "app" / "vendor" / "evil"

    @property
    def main(self) -> Path:
        return self.root / "app" / "main.schema.haus"

    def load(self) -> object:
        return load_schema(self.main, packages={"@acme/evil": self.package})

    def rejected(self, code: str = "package-path") -> str:
        with pytest.raises(HausSchemaFileError) as info:
            self.load()
        assert info.value.code == code, str(info.value)
        assert "API_TOKEN" not in str(info.value) and "hunter2" not in str(info.value)
        return str(info.value)


def test_a_package_is_its_manifest_and_schema_haus(tmp_path: Path) -> None:
    s = compile_schema(
        "import @acme/evil (Money)\ntype Root = Money",
        resolver=FileResolver(
            tmp_path, {"@acme/evil": App(tmp_path, {"package.haus": MANIFEST, "schema.haus": MONEY}).package}
        ),
    )
    assert s.file.imported["Money"].id == "@acme/evil@1#Money"


def test_other_manifest_fields_are_ignored(tmp_path: Path) -> None:
    manifest = '{ name: "@acme/evil", version: "1.2.0", schema: "../../../secret/creds.txt", x: 1 }'
    App(tmp_path, {"package.haus": manifest, "schema.haus": MONEY}).load()


def test_a_package_without_schema_haus(tmp_path: Path) -> None:
    assert "has no schema.haus" in App(tmp_path, {"package.haus": MANIFEST}).rejected("import-not-found")


@symlinks
def test_a_schema_or_manifest_that_links_outside_the_package(tmp_path: Path) -> None:
    app = App(tmp_path / "a", {"package.haus": MANIFEST})
    (app.package / "schema.haus").symlink_to(app.root / "secret" / "creds.schema.haus")
    assert "schema.haus is a symbolic link to a file outside the package" in app.rejected()
    manifest = App(tmp_path / "b", {"schema.haus": MONEY})
    (manifest.package / "package.haus").symlink_to(manifest.root / "secret" / "creds.txt")
    assert "is a symbolic link" in manifest.rejected()


@symlinks
def test_links_to_the_package_and_inside_it_are_followed(tmp_path: Path) -> None:
    store = tmp_path / "store" / "evil"
    write(store / "package.haus", MANIFEST)
    write(store / "real.haus", MONEY)
    (store / "schema.haus").symlink_to(store / "real.haus")
    (tmp_path / "link").symlink_to(store)
    resolver = FileResolver(tmp_path, {"@acme/evil": tmp_path / "link"})
    s = compile_schema("import @acme/evil (Money)\ntype Root = Money", resolver=resolver)
    assert s.file.imported["Money"].id == "@acme/evil@1#Money"


@pytest.mark.parametrize("module", ["./money", "../../../secret/creds"])
def test_a_package_schema_imports_no_files(tmp_path: Path, module: str) -> None:
    files = {
        "package.haus": MANIFEST,
        "schema.haus": f"import {module} (Money)\ntype M = Money\n",
        "money.schema.haus": MONEY,
    }
    assert "the schema of @acme/evil can't import files, only packages by name" in App(tmp_path, files).rejected()


def test_app_files_import_no_files_inside_a_package(tmp_path: Path) -> None:
    files = {"package.haus": MANIFEST, "schema.haus": MONEY, "sub/extra.schema.haus": MONEY}
    direct = App(tmp_path / "a", files, "import ./vendor/evil/sub/extra (Money)\ntype Root = Money\n")
    message = direct.rejected()
    assert "is in the package directory" in message and "import the package by its name" in message


@symlinks
def test_app_files_import_no_files_inside_a_package_through_links(tmp_path: Path) -> None:
    files = {"package.haus": MANIFEST, "schema.haus": MONEY, "sub/extra.schema.haus": MONEY}
    linked = App(tmp_path, files, "import ./link/extra (Money)\ntype Root = Money\n")
    (linked.root / "app" / "link").symlink_to(linked.package / "sub")
    assert "is in the package directory" in linked.rejected()


def test_app_files_import_schema_files_anywhere_else(tmp_path: Path) -> None:
    write(tmp_path / "shared" / "money.schema.haus", MONEY)
    write(tmp_path / "app" / "main.schema.haus", "import ../shared/money (Money)\ntype Root = { m: Money }\n")
    load_schema(tmp_path / "app" / "main.schema.haus")
    # The extension is always added: `./x.schema.haus` is x.schema.haus.schema.haus.
    write(tmp_path / "app" / "twice.schema.haus", "import ../shared/money.schema.haus (Money)\ntype R = Money\n")
    with pytest.raises(HausSchemaFileError, match=r"money\.schema\.haus\.schema\.haus") as info:
        load_schema(tmp_path / "app" / "twice.schema.haus")
    assert info.value.code == "import-not-found"


@pytest.mark.parametrize("version", ["1.1", "1.1.0", "01", "x", ""])
def test_imports_name_only_major_versions(version: str) -> None:
    with pytest.raises(HausSchemaFileError) as info:
        compile_schema(f"import @haus-fmt/money@{version} (Money)\ntype A = Money")
    assert info.value.code == "import-version"
    if version == "1.1":
        assert "(@haus-fmt/money@1)" in str(info.value)
        assert "dependency range" in info.value.hint

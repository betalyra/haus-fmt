"""A schema package is a directory with `package.haus` and `schema.haus` (spec §13.3).

Both are regular files, never symbolic links (the directory may be one); its
schema imports other packages by name, never files; application files don't
import files inside a package directory. Errors have the code `package-path`
and never quote a file that wasn't read. And imports name only major versions.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from haus.schema import (
    MAX_FOLDER_ENTRIES,
    FileResolver,
    HausSchemaFileError,
    ModuleError,
    ModuleResolver,
    ResolvedModule,
    compile_schema,
    load_schema,
)

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
def test_a_schema_or_manifest_that_is_a_link(tmp_path: Path) -> None:
    app = App(tmp_path / "a", {"package.haus": MANIFEST})
    (app.package / "schema.haus").symlink_to(app.root / "secret" / "creds.schema.haus")
    assert "schema.haus is a symbolic link or not a regular file" in app.rejected()
    manifest = App(tmp_path / "b", {"schema.haus": MONEY})
    (manifest.package / "package.haus").symlink_to(manifest.root / "secret" / "creds.txt")
    assert "is a symbolic link" in manifest.rejected()
    inside = App(tmp_path / "c", {"package.haus": MANIFEST, "real.haus": MONEY})
    (inside.package / "schema.haus").symlink_to("real.haus")  # inside the package: still a link
    assert "is a symbolic link" in inside.rejected()


@symlinks
def test_a_package_directory_may_be_a_link(tmp_path: Path) -> None:
    store = tmp_path / "store" / "evil"
    write(store / "package.haus", MANIFEST)
    write(store / "schema.haus", MONEY)
    (tmp_path / "link").symlink_to(store)
    resolver = FileResolver(tmp_path, {"@acme/evil": tmp_path / "link"})
    s = compile_schema("import @acme/evil (Money)\ntype Root = Money", resolver=resolver)
    assert s.file.imported["Money"].id == "@acme/evil@1#Money"


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="needs FIFOs")
def test_package_files_are_regular_files(tmp_path: Path) -> None:
    fifo = App(tmp_path / "a", {"package.haus": MANIFEST})
    os.mkfifo(fifo.package / "schema.haus")  # opening it must not block
    assert "not a regular file" in fifo.rejected()
    directory = App(tmp_path / "b", {"schema.haus": MONEY})
    (directory.package / "package.haus").mkdir()
    assert "not a regular file" in directory.rejected()


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


# ── given packages, manifests, one package per name (spec §13.3) ──


def package(directory: Path, name: str, version: str = "1.0.0", schema: str = MONEY) -> Path:
    write(directory / "package.haus", f'{{ name: "{name}", version: "{version}" }}')
    write(directory / "schema.haus", schema)
    return directory


def failure(code: str, text: str, resolver: ModuleResolver) -> str:
    with pytest.raises(HausSchemaFileError) as info:
        compile_schema(text, resolver=resolver)
    assert info.value.code == code, str(info.value)
    return info.value.reason


USE = "import @acme/money@1 (Money)\ntype Root = Money"


def test_packages_are_directories_mappings_or_folders(tmp_path: Path) -> None:
    money = package(tmp_path / "vendor" / "money-v1", "@acme/money")
    other = package(tmp_path / "vendor" / "other", "@acme/other")
    for resolver in [
        FileResolver(tmp_path, [money]),
        FileResolver(tmp_path, ["vendor/money-v1"]),
        FileResolver(tmp_path, {"@acme/money": money}),
        FileResolver(tmp_path, folders=["vendor"]),
        FileResolver(tmp_path, [money], folders=[tmp_path / "vendor"]),  # the same directory twice
    ]:
        assert compile_schema(USE, resolver=resolver).file.imported["Money"].id == "@acme/money@1#Money"
    assert "names the package @acme/other, not @acme/money" in failure(
        "import-not-found", USE, FileResolver(tmp_path, {"@acme/money": other})
    )
    assert "(@acme/other)" in failure("import-not-found", USE, FileResolver(tmp_path, [other]))
    with pytest.raises(TypeError):
        FileResolver(tmp_path, "vendor/money-v1")


def test_the_configuration_is_checked_when_the_resolver_is_made(tmp_path: Path) -> None:
    """A package directory without a manifest, or a folder that isn't one, fails before any import."""
    for packages, folders, why in [([tmp_path], [], "has no package.haus"), ([], ["nowhere"], "is not a directory")]:
        with pytest.raises(ModuleError, match=why) as info:
            FileResolver(tmp_path, packages, folders=folders)
        assert info.value.code == "import-not-found"
    write(tmp_path / "app" / "main.schema.haus", "type Root = Int")  # no imports at all
    with pytest.raises(HausSchemaFileError, match="is not a directory") as error:
        load_schema(tmp_path / "app" / "main.schema.haus", package_folders=["nowhere"])
    assert error.value.code == "import-not-found"


def test_load_schema_takes_packages_and_folders(tmp_path: Path) -> None:
    package(tmp_path / "schemas" / "money", "@acme/money")
    write(tmp_path / "app" / "main.schema.haus", USE)
    for s in [
        load_schema(tmp_path / "app" / "main.schema.haus", packages=["../schemas/money"]),
        load_schema(tmp_path / "app" / "main.schema.haus", package_folders=[tmp_path / "schemas"]),
    ]:
        assert s.file.imported["Money"].id == "@acme/money@1#Money"


def test_one_package_per_name(tmp_path: Path) -> None:
    a = package(tmp_path / "a", "@acme/money", "1.0.0")
    copy = package(tmp_path / "copy", "@acme/money", "1.0.0")
    newer = package(tmp_path / "newer", "@acme/money", "1.1.0")
    changed = package(tmp_path / "changed", "@acme/money", "1.0.0", MONEY + "type Rate = Decimal\n")
    compile_schema(USE, resolver=FileResolver(tmp_path, [a, copy]))  # byte for byte the same: one package
    reason = failure("duplicate-package", USE, FileResolver(tmp_path, [a, newer]))
    assert all(s in reason for s in ["1.0.0", "1.1.0", str(a), str(newer)]), reason
    failure("duplicate-package", USE, FileResolver(tmp_path, [a, changed]))


def test_two_major_versions_in_one_schema(tmp_path: Path) -> None:
    package(tmp_path / "v1", "@acme/money", "1.0.0")
    package(tmp_path / "v2", "@acme/money", "2.0.0")
    write(tmp_path / "app" / "one.schema.haus", "import @acme/money@1 (Money)\ntype One = Money")
    write(tmp_path / "app" / "two.schema.haus", "import @acme/money@2 (Money)\ntype Two = Money")
    write(tmp_path / "other" / "two.schema.haus", "import @acme/money@1 (Money)\ntype Two = Money")
    # Each file is given a resolver of its own here, so that each finds another version.

    class ByFile:
        def resolve(self, module: str, from_key: str | None) -> ResolvedModule:
            version = "v2" if from_key and from_key.endswith("two.schema.haus") else "v1"
            return FileResolver(tmp_path / "app", [tmp_path / version]).resolve(module, from_key)

    reason = failure(
        "duplicate-package", "import ./one (One)\nimport ./two (Two)\ntype Root = { a: One, b: Two }", ByFile()
    )
    assert "1.0.0" in reason and "2.0.0" in reason


@pytest.mark.parametrize(
    ("manifest", "why"),
    [
        ('{ name: "@Acme/money", version: "1.0.0" }', "isn't @org/name in lowercase"),
        ('{ name: "@acme/..", version: "1.0.0" }', "isn't @org/name in lowercase"),
        ('{ name: "@acme/.money", version: "1.0.0" }', "isn't @org/name in lowercase"),
        ('{ name: "acme/money", version: "1.0.0" }', "isn't @org/name in lowercase"),
        ('{ name: "@acme/' + "m" * 209 + '", version: "1.0.0" }', "at most 214 characters"),
        ('{ name: "@acme/money", version: "1" }', "isn't a semantic version"),
        ('{ name: "@acme/money", version: "01.0.0" }', "isn't a semantic version"),
        ('{ name: "@acme/money", version: "1.0.0-01" }', "isn't a semantic version"),
        ('{ name: "@acme/money", version: "v1.0.0" }', "isn't a semantic version"),
        ('{ name: "@acme/money" }', "needs a string field version"),
        ('{ name: "@acme/money", version: 1 }', "needs a string field version"),
        ('"@acme/money"', "is one record"),
        ('{ name: "@acme/money", version: "1.0.0" },\n{ }', "is one record"),
        ("{ name: ", "is not haus"),
        ('{ name: "@acme/money", version: "1.0.0", pad: "' + "x" * 65536 + '" }', "larger than 64 KiB"),
    ],
)
def test_manifests_are_checked(tmp_path: Path, manifest: str, why: str) -> None:
    write(tmp_path / "money" / "package.haus", manifest)
    write(tmp_path / "money" / "schema.haus", MONEY)
    assert why in failure("package-manifest", USE, FileResolver(tmp_path, [tmp_path / "money"]))


@pytest.mark.parametrize(
    "version", ["1.0.0", "0.0.0", "1.2.3-alpha.1", "1.2.3-0.x-y.7", "1.2.3+build.5", "1.2.3-rc.1+sha.abc", "10.20.30"]
)
def test_semantic_versions(tmp_path: Path, version: str) -> None:
    resolver = FileResolver(tmp_path, [package(tmp_path / "money", "@acme/money", version)])
    compile_schema("import @acme/money (Money)\ntype Root = Money", resolver=resolver)


def test_a_broken_manifest_among_the_given_packages(tmp_path: Path) -> None:
    package(tmp_path / "vendor" / "money", "@acme/money")
    write(tmp_path / "vendor" / "broken" / "package.haus", '{ name: "@acme/broken", version: "1.0" }')
    # Given by its directory, it is checked; in a folder, it is ignored unless an import isn't found.
    reason = failure("package-manifest", USE, FileResolver(tmp_path, [tmp_path / "vendor" / "broken"]))
    assert "broken" in reason
    compile_schema(USE, resolver=FileResolver(tmp_path, folders=["vendor"]))
    reason = failure(
        "import-not-found", "import @acme/broken (X)\ntype Root = X", FileResolver(tmp_path, folders=["vendor"])
    )
    assert str(tmp_path / "vendor" / "broken") in reason and "no valid package.haus" in reason


def test_folders_are_scanned_one_level_deep_and_bounded(tmp_path: Path) -> None:
    package(tmp_path / "deep" / "acme" / "money", "@acme/money")
    failure("import-not-found", USE, FileResolver(tmp_path, folders=["deep"]))
    package(tmp_path / "wide" / "money", "@acme/money")
    for i in range(MAX_FOLDER_ENTRIES - 1):
        (tmp_path / "wide" / f"f{i}").touch()
    compile_schema(USE, resolver=FileResolver(tmp_path, folders=["wide"]))  # 4096 entries
    (tmp_path / "wide" / "one-more").touch()
    assert "more than 4096 entries" in failure("too-many-files", USE, FileResolver(tmp_path, folders=["wide"]))


def test_a_package_directory_wins_over_a_folder(tmp_path: Path) -> None:
    package(tmp_path / "shared" / "money", "@acme/money", "1.0.0")
    local = package(tmp_path / "local" / "money", "@acme/money", "1.1.0")
    resolver = FileResolver(tmp_path, [local], folders=["shared"])
    assert resolver.resolve("@acme/money", None).version == "1.1.0"
    package(tmp_path / "shared" / "money-2", "@acme/money", "1.2.0")  # two in folders: two packages
    failure("duplicate-package", USE, FileResolver(tmp_path, folders=["shared"]))


@pytest.mark.parametrize("module", ["@Acme/money", "@acme/Money", "@acme/.money", "@-acme/money", "@acme/m$"])
def test_package_imports_are_lowercase(module: str) -> None:
    with pytest.raises(HausSchemaFileError) as info:
        compile_schema(f"import {module} (Money)\ntype Root = Money", resolver=FileResolver())
    assert info.value.code in ("unknown-module", "schema-syntax"), str(info.value)
    if module != "@acme/m$":
        assert info.value.code == "unknown-module"


def test_names_follow_npm_rules_for_new_names(tmp_path: Path) -> None:
    resolver = FileResolver(tmp_path, [package(tmp_path / "m", "@acme/m1._-x")])
    compile_schema("import @acme/m1._-x@1 (Money)\ntype Root = Money", resolver=resolver)
    # `~` isn't allowed in new npm names, and `node_modules` is no name.
    for name in ["@acme/m~1", "@node_modules/money", "@acme/node_modules"]:
        resolver = FileResolver(tmp_path, [package(tmp_path / name[1:], name)])
        assert "isn't @org/name" in failure("package-manifest", USE, resolver)
        assert compile_error(f"import {name} (Money)\ntype Root = Money").code == "unknown-module"
    compile_error("import @acme/node_modules.x (Money)\ntype Root = Money", "import-not-found")


def compile_error(text: str, code: str | None = None) -> HausSchemaFileError:
    with pytest.raises(HausSchemaFileError) as info:
        compile_schema(text, resolver=FileResolver())
    assert code is None or info.value.code == code, str(info.value)
    return info.value


def test_app_files_with_one_name_in_two_folders(tmp_path: Path) -> None:
    write(tmp_path / "app" / "billing" / "common.schema.haus", "type Iban = { iban: String }")
    write(tmp_path / "app" / "shipping" / "common.schema.haus", "type Address = { street: String }")
    write(tmp_path / "shared" / "common.schema.haus", "type Rate = Decimal")
    write(
        tmp_path / "app" / "main.schema.haus",
        "import ./billing/common (Iban)\nimport ./shipping/common (Address)\nimport ../shared/common (Rate)\n"
        "type Root = { bill: Iban, ship: Address, rate: Rate }",
    )
    s = load_schema(tmp_path / "app" / "main.schema.haus")
    assert s["Root"].id == "main#Root"
    ids = {name: s.file.imported[name].id for name in ["Iban", "Address", "Rate"]}
    assert ids == {"Iban": "billing/common#Iban", "Address": "shipping/common#Address", "Rate": "../shared/common#Rate"}
    # In a project, from the project's directory.
    write(tmp_path / "app" / "pyproject.toml", '[project]\nname = "shop"\n')
    s = load_schema(tmp_path / "app" / "main.schema.haus")
    assert s.file.imported["Iban"].id == "shop/billing/common#Iban"
    assert s.file.imported["Address"].id == "shop/shipping/common#Address"


# ── files: spelling, real names, sizes, counts, reading once (spec §13.3) ──


def test_relative_imports_spell_names_as_the_directory_lists_them(tmp_path: Path) -> None:
    write(tmp_path / "app" / "billing" / "common.schema.haus", "type Iban = String")
    for module in ["./Billing/common", "./billing/Common", "./BILLING/common"]:
        write(tmp_path / "app" / "main.schema.haus", f"import {module} (Iban)\ntype Root = Iban")
        with pytest.raises(HausSchemaFileError, match="spelled as the directory lists it") as info:
            load_schema(tmp_path / "app" / "main.schema.haus")
        assert info.value.code == "import-not-found"
    write(tmp_path / "app" / "main.schema.haus", "import ./billing/../billing/./common (Iban)\ntype Root = Iban")
    load_schema(tmp_path / "app" / "main.schema.haus")


@symlinks
def test_a_relative_import_reads_only_schema_files(tmp_path: Path) -> None:
    app = App(tmp_path, {"package.haus": MANIFEST, "schema.haus": MONEY}, "import ./pins (Pin)\ntype Root = Pin\n")
    (app.root / "app" / "pins.schema.haus").symlink_to(app.root / "secret" / "creds.txt")
    assert "its real name doesn't end in .schema.haus" in app.rejected("import-not-found")
    # A link to another schema file is fine.
    (app.root / "app" / "pins.schema.haus").unlink()
    write(app.root / "shared" / "pins.schema.haus", "type Pin = String")
    (app.root / "app" / "pins.schema.haus").symlink_to(app.root / "shared" / "pins.schema.haus")
    app.load()


def test_schema_files_are_at_most_1_mib(tmp_path: Path) -> None:
    big = "type T = Int\n" + "// " + "x" * (1024 * 1024) + "\n"
    write(tmp_path / "app" / "big.schema.haus", big)
    write(tmp_path / "app" / "main.schema.haus", "import ./big (T)\ntype Root = T")
    for root in ["big", "main"]:
        with pytest.raises(HausSchemaFileError, match="larger than 1024 KiB") as info:
            load_schema(tmp_path / "app" / f"{root}.schema.haus")
        assert info.value.code == "file-too-large"
    money = package(tmp_path / "vendor" / "money", "@acme/money", schema=MONEY + "// " + "x" * (1024 * 1024))
    assert "larger than 1024 KiB" in failure("file-too-large", USE, FileResolver(tmp_path, [money]))


def test_a_schema_reaches_at_most_256_files(tmp_path: Path) -> None:
    def chain(n: int) -> Path:
        directory = tmp_path / f"chain{n}"
        for i in range(n):
            imports = f"import ./f{i + 1} (T{i + 1})\n" if i + 1 < n else ""
            write(directory / f"f{i}.schema.haus", f"{imports}type T{i} = Int")
        return directory / "f0.schema.haus"

    load_schema(chain(256))  # the root included
    with pytest.raises(HausSchemaFileError, match="more than 256") as info:
        load_schema(chain(257))
    assert info.value.code == "too-many-files"


def count_opens(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """The names of the files opened from now on, through a test hook on `os.open`."""
    opened: list[str] = []
    real_open = os.open

    def counting_open(path: str, flags: int, *args: int) -> int:
        opened.append(os.path.basename(path))
        return real_open(path, flags, *args)

    monkeypatch.setattr(os, "open", counting_open)
    return opened


def test_each_file_is_read_once(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    write(tmp_path / "common.schema.haus", "type C = Int")
    write(tmp_path / "a.schema.haus", "import ./common (C)\nimport @acme/money (Money)\ntype A = C")
    write(tmp_path / "b.schema.haus", "import ./common (C)\nimport @acme/money (Money)\ntype B = C")
    money = package(tmp_path / "vendor" / "money", "@acme/money")
    opened = count_opens(monkeypatch)
    # The package given twice: the manifest is read once, for listing the packages and comparing copies.
    resolver = FileResolver(tmp_path, [money, money])
    compile_schema("import ./a (A)\nimport ./b (B)\ntype Root = { a: A, b: B }", resolver=resolver)
    assert sorted(opened) == ["a.schema.haus", "b.schema.haus", "common.schema.haus", "package.haus", "schema.haus"]


@symlinks
def test_a_file_in_two_roles_is_read_once(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Spec §13.3: by its real path, whatever it is read as; each role's checks still apply."""
    app = tmp_path / "app"
    write(app / "x.schema.haus", "type X = Int")
    write(app / "a.schema.haus", "import ./x (X)\nimport @acme/money (Money)\ntype Root = { x: X, m: Money }")
    (app / "pyproject.toml").symlink_to("x.schema.haus")  # read for the identity of a and x, as TOML
    money = package(tmp_path / "vendor" / "money", "@acme/money")
    opened = count_opens(monkeypatch)
    schema = load_schema(app / "a.schema.haus", packages=[money])
    assert schema["Root"].parse("{ x: 1, m: Money(1.5, EUR) }") is not None
    assert sorted(opened) == ["a.schema.haus", "package.haus", "schema.haus", "x.schema.haus"]
    # The root, imported again in a cycle, is not read again.
    write(app / "x.schema.haus", "import ./a (Root)\ntype X = Int")
    opened.clear()
    with pytest.raises(HausSchemaFileError) as info:
        load_schema(app / "a.schema.haus", packages=[money])
    assert info.value.code == "import-cycle"
    assert sorted(opened) == ["a.schema.haus", "x.schema.haus"]
    # A package's manifest that is a link to a file read as a schema is still refused, unread as a manifest.
    write(app / "x.schema.haus", "type X = Int")
    (money / "package.haus").unlink()
    (money / "package.haus").symlink_to(app / "x.schema.haus")
    with pytest.raises(HausSchemaFileError) as info:
        load_schema(app / "a.schema.haus", packages=[money])
    assert info.value.code == "package-path"


def test_messages_escape_and_shorten_text_from_files(tmp_path: Path) -> None:
    name = "@acme/" + "x" * 60 + "\\u{1b}[2J\\u{202e}"  # haus escapes in the manifest
    write(tmp_path / "money" / "package.haus", '{ name: "' + name + '", version: "1.0.0" }')
    write(tmp_path / "money" / "schema.haus", MONEY)
    reason = failure("package-manifest", USE, FileResolver(tmp_path, [tmp_path / "money"]))
    assert "\x1b" not in reason and "\u202e" not in reason
    assert '"@acme/' + "x" * 33 + '…"' in reason
    write(tmp_path / "money" / "package.haus", '{ name: "@acme/money", version: "1.0.0-\\u{202e}\\u{1b}" }')
    reason = failure("package-manifest", USE, FileResolver(tmp_path, [tmp_path / "money"]))
    assert '"1.0.0-\\u{202E}\\u{1B}"' in reason
    # Tokens of a schema file, too.
    e = compile_error('type Root = Int\n"' + "x" * 100 + '"')
    assert "x" * 40 not in str(e) and "'" + "x" * 39 + "…'" in str(e)


def test_a_manifest_that_is_not_haus_is_not_quoted(tmp_path: Path) -> None:
    write(tmp_path / "money" / "package.haus", "{ name: do-not-print")
    write(tmp_path / "money" / "schema.haus", MONEY)
    reason = failure("package-manifest", USE, FileResolver(tmp_path, [tmp_path / "money"]))
    assert "do-not-print" not in reason and "is not haus" in reason


def test_a_schema_file_that_is_not_utf8(tmp_path: Path) -> None:
    (tmp_path / "bad.schema.haus").write_bytes(b"type T = \xff")
    reason = failure("invalid-utf8", "import ./bad (T)\ntype Root = T", FileResolver(tmp_path))
    assert "is not UTF-8" in reason


def test_a_major_version_is_compared_as_text(tmp_path: Path) -> None:
    resolver = FileResolver(tmp_path, [package(tmp_path / "money", "@acme/money", "1.0.0")])
    for major in ["18446744073709551617", "1" + "0" * 40]:
        assert "wants major version" in failure("import-version", f"import @acme/money@{major} (Money)", resolver)

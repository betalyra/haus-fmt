"""Copies the schema package's files into the module, so that the wheel carries them.

In a checkout they are one directory up (the package directory, shared with the npm package and
the crate); the sdist gets them in `src/haus_money/`, where a wheel built from it finds them.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

FILES = ("package.haus", "schema.haus", "profiles")


class SchemaPackageHook(BuildHookInterface):  # type: ignore[type-arg]
    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        source = Path(self.root).parent
        if not (source / "package.haus").is_file():
            return  # built from the sdist: the files are in the module already
        module = "haus_money" if self.target_name == "wheel" else "src/haus_money"
        for name in FILES:
            build_data["force_include"][str(source / name)] = f"{module}/{name}"

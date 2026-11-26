# haus packages — draft 0.1

This document is the package layer of haus: where a build finds the schema
packages its imports name, the manifest fields beyond `name` and `version`,
profiles, and how codecs are wired to them. It is a companion to the
specification, [`README.md`](README.md), which it calls "the core": the data
syntax, the layouts, the canonical form and the hash, the error codes, the
prelude, `std/time`, the schema language with relative imports, the import
syntax and type ids are the core's (core §10). References such as "core §13.3"
are to sections of the core; the other references are to this document.

"MUST", "SHOULD" and "MAY" are used as in RFC 2119.

## 1. Versions

This document has its own version. Versions 0.x are drafts, in which anything
may still change, also after the core's 1.0. An implementation states both
versions: "haus 1.0, packages 0.3" (core §10). The places of the errors this
document defines (`undeclared-package`, `package-version`, a manifest's or a
`package.json`'s errors) are informative, as the places of errors in schema
files are (core §8). The error codes are the core's catalogue (core §17).

What a schema package is, its manifest's `name` and `version`, the identity of
its types, the import rules and the version policy are in core §13.3. This
document says where an import's package comes from, and what a build checks
on the way.

## 2. Where packages come from

Resolution follows five principles, and the rules below apply them; an implementation for another ecosystem derives its rules from them the same way:

<!-- rule: packages.principles.own-files -->
1. A build reads only a package's own files, and those are plain files, never links.
   <!-- rule: packages.principles.declared-places -->
2. Packages are found only where the build declared them, never because something happens to be nearby or in a shared place.
   <!-- rule: packages.principles.no-silent-sharing -->
3. Two different packages never share a name silently.
   <!-- rule: packages.principles.bounded-work -->
4. The work is bounded: sizes, the number of files, each file read once.
   <!-- rule: packages.principles.escaped-text -->
5. Text from files is never repeated unescaped.

<!-- rule: packages.lookup.only-two-places -->
Where an implementation looks for packages is part of the security model (core §9.2). It MUST look only in:

<!-- rule: packages.explicit.accepted -->
<!-- rule: packages.explicit.folder-children -->
<!-- rule: packages.explicit.directory-wins -->
<!-- rule: packages.explicit.folder-no-override -->
- packages given to it explicitly: a package's directory, or a folder whose subdirectories with a `package.haus` are packages. A subdirectory of such a folder whose manifest can't be read or breaks the rules (core §13.3) is skipped, not rejected, and named when an import isn't found, by the folder's last name and its own (`schemas/broken`), however the folder was given: the folder's last name is the last name of its real path (`./schemas/` and a link to `schemas` are both `schemas`; for `.`, the current directory's own name). A subdirectory whose `package.json` gives another version than its manifest, where versions are checked ("Package versions" below), is skipped the same way. A package given by its directory with such a manifest is rejected, with such a version `package-version`. Tools and runtime loaders MUST accept these; a code generator whose output uses the packages' own generated code takes them from the package manager instead. A package given by its directory is used instead of any other one with the same name. A package found in a folder is not: if the importer's dependencies hold another package with its name and other files, the schema has two packages with one name;
  <!-- rule: packages.lookup.build-dependencies -->
- the dependencies of the build, as its package manager installed them, by the rules of its ecosystem (below): `node_modules` (npm), the crate's dependencies (Cargo);

<!-- rule: packages.lookup.never-global -->
and never in global or environment-wide locations (npm's global folder, `NODE_PATH`, a shared cache), and never over the network.

<!-- rule: packages.explicit.file-tree -->
A package given explicitly is a directory on disk, or a read-only tree of files that code provides, such as a Go `fs.FS`, a Swift `Bundle`, classpath resources on the JVM or a Python `importlib.resources` `Traversable`, so that a schema package can be published inside a library of any language. A tree is a package under the same rules as a directory: its `package.haus` and `schema.haus`, the version check, the limits, exact names, and no links (a tree that can hold links follows none of them). How to publish a schema package for each language is documentation, not specification.

<!-- rule: packages.installed.declared -->
<!-- rule: packages.installed.project-local -->
<!-- rule: packages.installed.manager-resolution -->
<!-- rule: packages.installed.same-rules -->
**Installed packages.** Packages that the build's package manager installed follow these rules, whatever the ecosystem:

- A file imports only packages that the build declared as its dependencies in its own manifest (`package.json`, `Cargo.toml`), checked before anything is looked for.
- They are installed in a place of the project's own (`node_modules`, Cargo's build), never in a global or shared cache, and never found on the network.
- Each one is the package the package manager's own resolution gives for that dependency: an implementation reads where the package manager put it, and doesn't search for it elsewhere.
- Its files follow the rules of a package's files (core §13.3, "Files read" and "Files and limits"), and its version is checked against its `package.haus` ("Package versions", below).

## 3. Ecosystems

<!-- rule: packages.ecosystems.defined -->
<!-- rule: packages.ecosystems.npm-only -->
An **ecosystem** says how a package manager meets these rules, in a subsection of its own; a later ecosystem adds one, and the rules above stay. Two are defined: npm and Cargo. Only implementations of the npm ecosystem, JavaScript runtimes that resolve modules from `node_modules` (Node, Bun, Deno), look in `node_modules`; every other implementation MUST NOT, also when a `node_modules` is next to its files, since its build declares its dependencies elsewhere (`go.mod`, `pyproject.toml`). A project in several languages installs a schema package once per language: the copies define the same types (`@haus-fmt/money@1#Money`), so data passes between them unchanged.

**npm.** An implementation of the npm ecosystem MUST follow these rules, so that every such implementation finds the same package and a dependency can't place one where another is looked for:

<!-- rule: packages.npm.declared-first -->
<!-- rule: packages.npm.declaration-source -->
<!-- rule: packages.npm.declared-fields -->
<!-- rule: packages.npm.explicit-declared -->
- A file imports only packages it declares, and the implementation checks this before it looks. For a package's `schema.haus`, the declarations are in the package's own `package.json`. For other files, they are in the nearest `package.json` above the file's real path, skipping one that is valid JSON but not an object, or an object with neither a `name` nor a dependency field (such as `{ "type": "module" }`). The search stops at a `package.json` that isn't valid JSON or isn't a regular file (a directory, a symbolic link, a FIFO): that one declares nothing, and is not read. The declared packages are the member names of `dependencies`, `peerDependencies` and `optionalDependencies`, and for every file other than a package's `schema.haus` also `devDependencies`; a dependency field that isn't an object declares nothing, and still makes the file a project's. Without such a `package.json`, a file declares nothing. Explicit packages count as declared. Otherwise: `undeclared-package`.
  <!-- rule: packages.npm.search-upward -->
  <!-- rule: packages.npm.skip-node-modules-dirs -->
  <!-- rule: packages.npm.skip-world-writable -->
- It starts from the real path of the importing file and tries `D/node_modules/@org/name` for each directory `D` from the file's directory up to the root of the file system, nearest first, as Node does: the build's root (core §13.3) bounds relative imports, not this search, so that a schema finds the packages Node finds for the code next to it. It skips a `D` that is itself named `node_modules`, a scope directory directly inside one (`node_modules/@acme`), or the root of a Windows drive or share (`C:\`, `\\server\share\`), where any user can create `node_modules`. On Unix it SHOULD skip a `D` that everyone may write to (the mode's write bit for others, such as `/tmp`), so that a `node_modules` planted there is never used. Windows has no such simple test (who may create a directory is the outcome of inherited and denying entries of an ACL), so this rule is Unix-only; an implementation MAY skip on Windows a `D` whose ACL lets Everyone, Authenticated Users or Users create subdirectories.
  <!-- rule: packages.npm.first-found-stops -->
  <!-- rule: packages.npm.candidate-stops -->
- The first `node_modules/@org/name` that exists is the package, where it exists when its directory lists it (as `lstat` sees it, not following it). If it has no `package.haus`, the import is not found; the search doesn't go on. A candidate that exists but can't be used stops the search the same way, with `import-not-found`: a link that dangles or is part of a cycle of links (`ENOENT`, `ELOOP` when followed), or a candidate that can't be told apart from a missing one because `D`, `D/node_modules` or `D/node_modules/@org` can't be listed or entered (`EACCES`): a directory `D` on the way up that can't be listed can't show whether it has a `node_modules`, so it stops the search too (it fails closed). Only a `D` that lists no `node_modules`, a `D/node_modules` that isn't a directory or doesn't list `@org`, or a `D/node_modules/@org` that doesn't list `name`, lets the search go on, so that a broken install never falls through to a package further up.
  <!-- rule: packages.npm.name-matches -->
- A package found this way MUST have the imported name in its manifest, and npm's name for it (its directory) is that name too.
  <!-- rule: packages.npm.package-json-strict -->
- The `package.json` of a package found this way is one of its files: a symbolic link, or a file that isn't a regular one, is `package-path`, and one larger than its limit `file-too-large`. It declares the package's own dependencies and gives its version. So does the `package.json` of a package found in a folder given explicitly, when the build uses it. (Beside a package given by its directory, it is read leniently instead, below.)

<!-- rule: packages.package-json.invalid -->
A `package.json` that isn't valid JSON, or isn't an object, declares nothing and gives no version to check. Its `version` is checked only when it is a string.

<!-- rule: packages.cargo.direct-dependencies -->
**Cargo.** A schema package published as a crate has a build script that tells Cargo where its directory is (`haus_build::package()`, through the crate's `links` metadata), and Cargo passes that only to the crates that depend on it directly (`DEP_<LINKS>_HAUS_PACKAGE`): a crate's own files import its direct dependencies, the dependencies' graph is passed on by each package crate for the packages they import, and nothing is searched. The version checked is the crate's package version. A build script's build has the crate's directory (`CARGO_MANIFEST_DIR`) as its root by default (core §13.3, "The root"), for a schema inside the crate, rather than the schema's own directory: a crate's schemas share files across its folders, and not with other crates. Code generators of other languages that build with Cargo follow the same rules (`haus-build` for Roc).

## 4. Manifests and package versions

<!-- rule: packages.manifest.other-fields-ignored -->
A manifest's fields other than `name` and `version` (core §13.3) are ignored, so later versions of this document can add some.

<!-- rule: packages.version.check-manager -->
**Package versions** (`package-version`): implementations SHOULD check that a package's manifest `version` equals the version the package manager gives it, where it gives one (the `version` of npm's `package.json`, Cargo's package version). The check catches publishing mistakes and doesn't change what a schema means.
<!-- rule: packages.version.explicit-too -->
This holds for packages given explicitly too: an implementation that finds a version next to the manifest (the `version` of a `package.json` beside the `package.haus`, Cargo's package version) checks it, and reports `package-version` when it differs for a package given by its directory; a subdirectory of a folder with such a version is skipped (§2).
<!-- rule: packages.version.explicit-unreadable -->
A `package.json` beside a package given explicitly is read leniently, by every implementation of every ecosystem, npm included: only to catch a version that differs. One that can't be read (a symbolic link or not a regular file, larger than its limit, not JSON) is ignored: it gives no version, and is no error. This holds for a package given by its directory, and for each package of a folder when the folder is read. Under npm, a package's `package.json` also declares the dependencies of its own imports: beside a package given by its directory it is read leniently for that too, while a package of a folder that a build uses reads it as the npm rules say (§3), as it reads every package the npm search could find in that place, so that a folder never changes how a package is read.

## 5. Distribution

There is no haus registry. Authors publish schema packages however their users install dependencies: language registries (npm, crates.io, PyPI, …), private registries, git dependencies, workspaces, or copies in the project (vendored, still imported by name). Codec libraries for registries that reject git dependencies (crates.io, PyPI) can carry the schema text they target.

The reasons:

- Package managers already provide hosting, mirrors, lock files, hashes, authentication and private registries.
- A haus registry would be one more service to run and one more point of failure for every build.
- Types are identified by manifest names (`@haus-fmt/money@1#Money`), not by a registry, so a registry or a catalog can be added later without breaking anything; removing one could not be done the same way.

What this means for users:

<!-- rule: packages.publishing.owned-names -->
- **Names are claims.** A manifest name doesn't prove who wrote a package: trust comes from the dependency the application chose to add. Scopes make names reliable on npm, and less so on registries with unscoped names. `@haus-fmt/` is reserved by convention; on npm the `@haus-fmt` scope enforces it. Organisations SHOULD use a name they own: their domain or their code hosting organisation.
  <!-- rule: packages.publishing.no-install-scripts -->
- **No install scripts.** A schema package is data and MUST NOT need code to install, such as npm `postinstall`. Codecs are code, and are trusted like any other library.
  <!-- rule: packages.publishing.one-source -->
- **Copies in several languages.** A package published to several registries SHOULD be published from one source, so that equal versions have equal files.
  <!-- rule: packages.npm.peer-dependencies -->
- **One copy per build.** On npm, a schema package SHOULD declare the schema packages it imports as `peerDependencies`, so that npm installs one copy for the whole application or reports a conflict when installing, as Cargo does.
- **Discovery.** There is no index. The official extensions are listed in [`../extensions`](../extensions).

## 6. Profiles

<!-- rule: packages.profiles.definitions -->
A package MAY define profiles, named like `@haus-fmt/money/iso`. A profile is a definition of the package's types: which of the values its schema accepts are values of the type. It follows the four rules of core §13.1, as every rule about values does. A package has one profile when its domain has one definition (`@haus-fmt/geo/wgs84`), and several when its domain has several (which codes are currencies). Codecs implement profiles (core §13.4), and the application picks one. Profiles are how the official extensions say what "valid money" means without putting rules into the schema language.

<!-- rule: packages.profiles.vectors -->
<!-- rule: packages.profiles.rule-over-vectors -->
A profile is defined by its **rule**, written in prose in `profiles/<name>.md`: which values a codec implementing it accepts, stated on the value the type's schema decoded (core §13.4), never on how it was written. Its **test vectors** (`profiles/<name>.vectors.haus`) are examples of the rule that every implementation must pass: values it accepts, with the text they encode back to where that differs from the input, and values it rejects. The rule defines the profile, and the vectors only test it: two codecs can pass all of them and still disagree, so where a rule and its vectors disagree, the vectors are wrong. The official profiles also have a reference checker in Lean, which the bindings' codecs are fuzzed against.

<!-- rule: packages.profiles.spellings -->
Where a type's values have several spellings that mean the same (the host of a URL in upper or lower case, its percent-escapes), the profile's rule decides, before its package is first published, whether it accepts one spelling only (lowercase hosts, say) or several. A profile that accepts several says so in its rule, and that haus equality (core §2), the canonical form and the hash tell them apart.

<!-- rule: codecs.apply.rules-on-schema-values -->
**A profile's rule and other codecs.** A profile's rule is checked on the values the schema decoded, never on what an inner codec made of them (core §13.4: what an outer codec receives is otherwise the binding's choice), so no codec can make a value pass the rule of another codec. With `iso`'s codec for `Money`, `Money(19.90, Bitcoin)` is `codec-rejected`, whatever codec the application sets for `Currency`.

## 7. Codec wiring

A codec chooses the host type of a named type, selected by the type's id
(core §13.4). This section says how an application sets codecs, and what a
binding reports about the codecs it set and those it didn't.

<!-- rule: codecs.api.one-per-id -->
**One codec per id.** An application sets at most one codec per id: a binding given two for one id rejects them, as a mistake of its configuration (not of the data, so with no code of core §17).

<!-- rule: packages.codecs.missing-warning -->
**A profile without its codec.** A package's rule is checked only where a codec applies it: without one, the values of its types are checked for their shape only (`Money(19.90, Eur)` decodes). So a schema binding SHOULD report the warning `missing-codec` when a type it decodes reaches a type that an official profile has a rule for, and no codec is set for that type's id. These types are:

| Type | Profiles |
|---|---|
| `@haus-fmt/money@1#Currency` | `iso` |
| `@haus-fmt/geo@1#LatLng` | `wgs84` |
| `@haus-fmt/geo@1#BBox` | `wgs84` |
| `@haus-fmt/uuid@1#Uuid` | `rfc9562` |

(`iso`'s rule for `Money` is its currency's, so `Currency` stands for it.) Only the types the decoded type reaches count (a binding that builds every type of a schema file at once: the types the file's own definitions reach), and a type reached only inside a type that has a codec doesn't: that codec decides which values it holds (a codec for `Money` covers its `Currency`). The warning is reported where the binding learns which codecs are set (when a set of codecs is built, a schema is compiled with them, or decoding starts), once per type id, at no place, through the channel of the binding's other schema warnings (`unknown-attribute`, `deprecated`, `no-json-form`). Its message names the type's id and its profiles: `@haus-fmt/money@1#Currency has profiles (iso), but no codec is set for it: its values are checked for their shape only`. It is a warning, never an error: decoding is unchanged. Tools that have no codecs (`haus check`, editors) report instead, with the same code as a note of the lowest severity (a hint), once per import of a package that has such a type, at the import: `the rules of @haus-fmt/money (profiles: iso) are not checked here; your application checks them by adding a codec`.

<!-- rule: codecs.unused.warning -->
**A codec that matches no type.** A codec set for an id that no type has never runs, and the values it was meant to check pass: a typo, or `@haus-fmt/money@2#Money` when the schema imports major 1. So a schema binding SHOULD report the warning `unused-codec` for a codec whose id is no type of the prelude or a standard module, nor of the schema's files and the packages they import. It is reported as `missing-codec` is: where the binding learns which codecs are set, once per id, at no place, through the channel of its other schema warnings; its message names the id. It MAY also be reported on request, through a function of the binding's that the application calls with its codecs and its schema, once per id, at no place: a binding whose codecs aren't bound to a schema (they are given to each decode) has no other place to report it. A binding MAY reject such a codec instead, as a mistake of its configuration, and MAY leave out codecs that a library ships as a set (the codecs of a profile) when the application passes the whole set.

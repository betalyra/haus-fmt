# haus packages — draft 0.2

This document is the package layer of haus: where a build gets the schema
packages its imports name (the official packages built into every binding,
packages given as values, packages read from directories), the manifest
fields beyond `name` and `version`, package rules and how they are checked,
and how codecs are wired to types. It is a companion to the specification,
[`README.md`](README.md), which it calls "the core": the data syntax, the
layouts, the canonical form and the hash, the error codes, the prelude,
`std/time`, the schema language with relative imports, the import syntax and
type ids are the core's (core §10). References such as "core §13.3" are to
sections of the core; the other references are to this document.

"MUST", "SHOULD" and "MAY" are used as in RFC 2119.

## 1. Versions

This document has its own version. Versions 0.x are drafts, in which anything
may still change, also after the core's 1.0. An implementation states both
versions: "haus 1.0, packages 0.3" (core §10), the package layer's in its
documentation at least; a function of its API that gives the core's version
need not give this one. The places of the errors this
document defines (`package-version`, `missing-codec`, a manifest's errors) are informative, as the places of errors in schema
files are (core §8). The error codes are the core's catalogue (core §17).

Draft 0.2 changes draft 0.1 in these points: packages can be given as values
(§3); the official packages are built into every binding and can't be
replaced (§3); no implementation looks for installed packages any more (the
npm lookup of 0.1 is gone, §2); a package's manifest says which of its types
have a rule (`rules`, §4), and its rules, which 0.1 called profiles, are
checked by the binding on by default (§6), with `missing-codec` an error that
a program opts out of per package (§7).

What a schema package is, its manifest's `name` and `version`, the identity of
its types, what imports may do and the version policy are in core §13.3. This
document says where an import's package comes from, and what a build checks
on the way.

## 2. Where packages come from

Resolution follows five principles, and the requirements below apply them; an implementation for another language derives its own from them the same way:

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

<!-- rule: packages.lookup.given-only -->
Where an implementation gets packages is part of the security model (core §9.2). A build has the packages it is given, and looks for none. It MUST take them only from:

- the official packages built into the implementation (§3);
- packages the program gives it as values (§3), such as the bundle of a library that the program imported with its language's own imports;
- packages read from directories given to it explicitly (below).

<!-- rule: packages.lookup.no-search -->
No implementation searches for packages, neither a library nor a tool: none looks in a project's `node_modules`, a Python environment's `site-packages`, a package manager's cache or install location, or a directory above the schema, also when one is next to its files. A package that a package manager installs reaches a build as the library that carries it, which the program imports and passes as a value (§3), or as a directory the program gives. Cargo's build-script metadata (§3, "Cargo") is how Rust passes a crate's package to the crates that depend on it, not a search.

<!-- rule: packages.lookup.never-global -->
So packages never come from global or environment-wide locations (npm's global folder, `NODE_PATH`, a shared cache), and never from the network.

**Packages read from directories.** A program that loads schemas chosen at run time gives a build packages as files:

<!-- rule: packages.explicit.accepted -->
<!-- rule: packages.explicit.folder-children -->
<!-- rule: packages.explicit.directory-wins -->
<!-- rule: packages.explicit.folder-no-override -->
- a package's directory, or a folder whose subdirectories with a `package.haus` are packages. A subdirectory of such a folder whose manifest can't be read or breaks the requirements of core §13.3 is skipped, not rejected, and named when an import isn't found, by the folder's last name and its own (`schemas/broken`), however the folder was given: the folder's last name is the last name of its real path (`./schemas/` and a link to `schemas` are both `schemas`; for `.`, the current directory's own name). A subdirectory whose `package.json` gives another version than its manifest, where versions are checked ("Package versions", §4), is skipped the same way. A package given by its directory with such a manifest is rejected, with such a version `package-version`. Tools and runtime loaders MUST accept these; a code generator whose output uses the packages' own generated code takes them as its language's libraries instead (§3, "Cargo"). A package given by its directory is used instead of one with the same name found in a folder. A package found in a folder replaces none: if a package given as a value has its name and other files, the schema has two packages with one name (core §13.3), as it has for a value and a package given by its directory.

<!-- rule: packages.explicit.file-tree -->
A package given explicitly is a directory on disk, or a read-only tree of files that code provides, such as a Go `fs.FS`, a Swift `Bundle`, classpath resources on the JVM or a Python `importlib.resources` `Traversable`. A tree is a package under the same requirements as a directory: its `package.haus` and `schema.haus`, its `rules/` documents (§4), the version check, the limits, exact names, and no links (a tree that can hold links follows none of them). How to publish a schema package for each language is documentation, not specification.

<!-- rule: packages.read.separate -->
**Reading is separate from compiling.** Reading a package's directory, a folder or a file tree is the only step of the package layer that touches files: it applies the requirements on a package's files (core §13.3, "Files read", "Spelling" and "Files and limits"; the version check and the rule documents of §4) and gives package values (§3). A compile takes package values only, and reads no file. A binding MAY offer one call that reads and then compiles, as a composition of the two.

<!-- rule: packages.tools.given-only -->
**Tools.** Tools that check or edit schemas without a program to give them packages, such as a command-line tool or an editor extension, have the official packages built in (§3) and take every other package from directories given to them explicitly (a command-line option, an editor's settings), which are not searched for. They follow §2 as libraries do: an import of a package that isn't built in nor given is `import-not-found`, and its message SHOULD say how to give the package.

## 3. Packages as values

<!-- rule: packages.values.bundle -->
A **package value** holds a package's manifest text and its schema text. A library that publishes a schema package for a language exports one, a **bundle**, which also holds the implementations of the package's rules in that language (§6) and the bundles of the packages its schema imports (its direct dependencies, which the library gets through its language's own imports). A schema names a bundle's package by its manifest's name, as any package: `import @acme/orders (Order)`. A program gives a compile the bundles it imported; the binding collects them with the bundles they hold.

<!-- rule: packages.values.checks -->
A package value is checked as a package read from a directory is, except for what concerns files: its manifest (core §13.3: one record, `name`, `version`, at most 64 KiB) and its `rules` field (§4), its schema text's limit, the requirements on imports (the manifest's name is the name imported, the major version, a package's schema imports no files, no cycles), and one package per name: two values, or a value and a package read from files, with one name are `duplicate-package`, unless their manifest and schema texts are byte for byte the same and their imports reach the same packages (core §13.3). Their texts are untrusted input, as files are.

<!-- rule: packages.values.plain-data -->
A program MAY make package values from plain data it has from anywhere, a file, a database, a URL or memory: a manifest text and a schema text (`Package.make({ manifest, schema })` in TypeScript, the same in each language's idiom). Such a value has the checks above and none of the files' (links, regular files, the rule documents of §4).

<!-- rule: packages.values.version -->
A package value's version is its manifest's `version`. The version of the library that carries it doesn't count, and no package manager gives it another, so `package-version` (§4) is not checked on values. A publisher checks that a library's bundle holds the manifest and schema of the package's source with `haus package check`.

**The official packages.**

<!-- rule: packages.official.built-in -->
The official packages (`@haus-fmt/money`, `@haus-fmt/geo`, `@haus-fmt/uuid`, core §13) are built into every schema binding's library, with an implementation of every rule their manifests name, and are part of every compile: a schema imports them by name, and nothing gives them to the build. Their texts are byte for byte the files of [`../extensions`](../extensions) at the version the library ships. In Rust they are crates of their own instead ("Cargo", below), which a program adds as dependencies.

<!-- rule: packages.official.not-replaced -->
An official package can't be replaced. A package given to a compile with an official package's name, as a value, by its directory or found in a folder, MUST be byte for byte the built-in one, its manifest and its schema, else `duplicate-package`, whether a schema imports it or not. So a vendored or modified copy can't change the official types or turn their rules off, and a library's own release doesn't decide which version of an official package a program uses.

<!-- rule: packages.official.not-in-bundles -->
A bundle never carries an official package: a library whose schema imports one refers to it by name, and the built-in one is used.

<!-- rule: packages.cargo.direct-dependencies -->
**Cargo.** In Rust, a schema package published as a crate is its package value: the crate has a build script that tells Cargo where its directory is (`haus_build::package()`, through the crate's `links` metadata), and Cargo passes that only to the crates that depend on it directly (`DEP_<LINKS>_HAUS_PACKAGE`): a crate's own files import its direct dependencies, the dependencies' graph is passed on by each package crate for the packages they import, and nothing is searched. This is Rust's own import of a library: Cargo resolves the crates when it builds, and checks each crate's version range. The crate's generated code carries the implementations of the package's rules. The official packages are the crates `haus-fmt-money`, `haus-fmt-geo` and `haus-fmt-uuid`. The version checked is the crate's package version (§4). A build script's build has the crate's directory (`CARGO_MANIFEST_DIR`) as its root by default (core §13.3, "The root"), for a schema inside the crate, rather than the schema's own directory: a crate's schemas share files across its folders, and not with other crates. Code generators of other languages that build with Cargo do the same (`haus-build` for Roc).

## 4. Manifests and package versions

<!-- rule: packages.manifest.other-fields-ignored -->
A manifest's fields other than `name`, `version` (core §13.3) and `rules` (below) are ignored, so later versions of this document can add some.

<!-- rule: packages.manifest.rules-field -->
**Rules.** A manifest MAY have the field `rules`, which says which of the package's types have a package's rule (§6): a record from a type's name to its rule's name, one rule per type, in plain haus (`rules?: Map String`):

```
{ name: "@haus-fmt/money", version: "1.0.1", rules: { "Currency": "iso" } }
{ name: "@haus-fmt/geo", version: "1.0.1", rules: { "LatLng": "wgs84", "BBox": "wgs84" } }
```

Type names start with a capital letter, so as keys they are quoted (a bare key starts with a lowercase letter or `_`, core §1). A rule's name has the form `[a-z][a-z0-9-]*`. A type has one rule; a list of rules for one type is not a rule's name.

<!-- rule: packages.manifest.rules-checked -->
Each type the field names MUST be defined in the package's `schema.haus`, without parameters and not as a `Stream` (a rule decides on one value of its type, §6); each rule's name MUST have the form above; the field MUST be a record, and each of its values a string. A package whose field breaks these requirements is `package-manifest`. The field is checked on each package a schema reaches, when it is compiled (its types need the schema), and before any rule is looked for (§7). The field of a package no import reaches is not checked: a folder's package with a broken `rules` field is not skipped, as one whose `name` or `version` breaks core §13.3 is, and is reported when it is reached.

<!-- rule: packages.manifest.rules-documents -->
Each package's rule is defined in prose in `rules/<name>.md`, in the package's directory (§6). A package read from a directory or a file tree MUST have it for each rule its field names, as a regular file and not a symbolic link, else `package-manifest`, reported as the field's other errors are. The file is looked at, not read: reading the package notes which documents it has. A package value made from plain data has no files, and isn't checked for them (§3); `haus package check` checks a package's source.

<!-- rule: packages.version.check-manager -->
**Package versions** (`package-version`): where a package read from files comes with a version of its package manager, implementations SHOULD check that it equals the manifest's `version`: the `version` of a `package.json` beside the package's `package.haus`, or Cargo's package version of a package crate (§3). The check catches publishing mistakes and doesn't change what a schema means. A package value has no such version (§3).
<!-- rule: packages.version.explicit-too -->
This holds for packages given explicitly: an implementation that finds a version next to the manifest (the `version` of a `package.json` beside the `package.haus`) checks it, and reports `package-version` when it differs for a package given by its directory; a subdirectory of a folder with such a version is skipped (§2).
<!-- rule: packages.version.explicit-unreadable -->
A `package.json` beside a package given explicitly is read leniently, by every implementation: only to catch a version that differs. One that can't be read (a symbolic link or not a regular file, larger than 1 MiB, not JSON) is ignored: it gives no version, and is no error. This holds for a package given by its directory, and for each package of a folder when the folder is read.

<!-- rule: packages.package-json.invalid -->
A `package.json` that isn't valid JSON, or isn't an object, gives no version to check. Its `version` is checked only when it is a string.

## 5. Distribution

There is no haus registry. Authors publish a schema package however their users install dependencies, as a library of each language its users write (a bundle, §3) or as files that programs read: language registries (npm, crates.io, PyPI, …), private registries, git dependencies, workspaces, or copies in the project (vendored, still imported by name). The official packages are built into every binding (§3) and are not published on their own, except as Rust crates.

The reasons:

- Package managers already provide hosting, mirrors, lock files, hashes, authentication and private registries.
- A haus registry would be one more service to run and one more point of failure for every build.
- Types are identified by manifest names (`@haus-fmt/money@1#Money`), not by a registry, so a registry or a catalog can be added later without breaking anything; removing one could not be done the same way.

What this means for users:

<!-- rule: packages.publishing.owned-names -->
- **Names are claims.** A manifest name doesn't prove who wrote a package: trust comes from the dependency the application chose to add. Scopes make names reliable on npm, and less so on registries with unscoped names. `@haus-fmt/` is reserved by convention; on npm the `@haus-fmt` scope enforces it. Organisations SHOULD use a name they own: their domain or their code hosting organisation.
  <!-- rule: packages.publishing.no-install-scripts -->
- **No install scripts.** A schema package is data and MUST NOT need code to install, such as npm `postinstall`. The implementations of its rules and codecs are code, and are trusted like any other library.
  <!-- rule: packages.publishing.one-source -->
- **Copies in several languages.** A package published to several registries SHOULD be published from one source, so that equal versions have equal files; `haus package check` checks each library's bundle against it.
  <!-- rule: packages.npm.peer-dependencies -->
- **One copy per build.** On npm, a library that exports a bundle SHOULD declare the libraries of the schema packages its schema imports as `peerDependencies`, so that npm installs one copy for the whole application or reports a conflict when installing, as Cargo does.
- **Discovery.** There is no index. The official packages are listed in [`../extensions`](../extensions).

## 6. Packages' rules

<!-- rule: packages.rules.definitions -->
A package MAY give some of its types a **rule** (its manifest's `rules`, §4): a definition of the type, which of the values its schema accepts are values of the type. In this document, "rule" alone means such a package's rule, never a requirement of this document. A package's rule meets the four requirements of core §13.1, as every rule about values does. Rules are how the official packages say what "valid money" means without putting rules into the schema language. A type has at most one rule. Where a domain has several legitimate definitions (which codes are currencies), a package's rule is one of them: an application that wants another takes the package shape-only and checks its own (§7), or defines a type of its own.

<!-- rule: packages.rules.vectors -->
<!-- rule: packages.rules.prose-over-vectors -->
A rule is defined by its prose, `rules/<name>.md`: which values it accepts, stated on the value the type's schema decoded (core §13.4), never on how it was written. Its **test vectors** (`rules/<name>.vectors.haus`) are examples of the rule that every implementation must pass: values it accepts, with the text they encode back to where that differs from the input, and values it rejects. The prose defines the rule, and the vectors only test it: two implementations can pass all of them and still disagree, so where a rule's prose and its vectors disagree, the vectors are wrong. The official rules also have a reference checker in Lean (`extensions/<name>/lean/`), which the bindings' implementations are fuzzed against.

<!-- rule: packages.rules.spellings -->
Where a type's values have several spellings that mean the same (the host of a URL in upper or lower case, its percent-escapes), the rule decides, before its package is first published, whether it accepts one spelling only (lowercase hosts, say) or several. A rule that accepts several says so in its prose, and that haus equality (core §2), the canonical form and the hash tell them apart.

<!-- rule: packages.rules.by-type-id -->
**A package's rule belongs to its type.** A package's rule is the rule of a type id (`@haus-fmt/money@1#Currency`, core §13.3), whichever copy of the package gave the schema the type: a binding's implementation of the rule applies to the type with that id. An implementation runs on whatever the schema decoded, and rejects any value it doesn't expect (`codec-rejected`), so a modified copy of a package can't slip a value past it.

<!-- rule: packages.rules.checked-by-binding -->
**Packages' rules are on by default.** A schema binding checks the package's rule of every type that has one, on every value of the type it decodes: on the value the schema decoded, before any codec of the type runs, and whichever codecs the application set. A value the rule rejects is `codec-rejected`, at the place of the type (core §13.4), and inside a `Secret` `invalid-secret` at the secret. When encoding, a value of the type that the rule rejects is `cannot-encode`, at the place of the type. A codec chooses the host type and may reject more values, never fewer. A rule is turned off only by taking its package shape-only (§7).

<!-- rule: codecs.apply.rules-on-schema-values -->
**A package's rule and codecs.** A rule is checked on the values the schema decoded, never on what an inner codec made of them (core §13.4: what an outer codec receives is otherwise the binding's choice), so no codec can make a value pass a rule. With `@haus-fmt/money`'s rule `iso`, `Money(19.90, Bitcoin)` is `codec-rejected`, whatever codecs the application sets for `Currency` and `Money`.

<!-- rule: packages.rules.covered-through -->
**Types that hold a checked type.** A type whose values hold a type with a rule is checked through it: `Money` holds a `Currency`, so the rule `iso` of `Currency` checks the currency of every `Money`, and `Money` needs no rule of its own. A rule's prose says what it means for the types that hold its type (`iso`: a `Money` is any `Decimal` with an accepted currency).

## 7. Compiling: packages' rules, opt-outs and codecs

A package's rule decides which values a type has (§6); a codec chooses the host type of a named type, selected by the type's id (core §13.4). This section says what a compile requires of the program, how the program opts out, and how it sets codecs.

<!-- rule: packages.rules.missing-codec -->
**A package's rule the program doesn't implement.** A compile MUST fail with the error `missing-codec` when the schema reaches a type that its package gives a rule (§4) and the program has no implementation of it, unless the program takes the package shape-only (below). The program has the rules of the official packages (built in, §3), the rules the bundles it gives carry in the binding's language (§3), and the rules it supplies itself (below). The types the schema reaches are those that the definitions of every one of the application's schema files name, directly or through other types, in any package (an `Order` whose lines hold a `Code` reaches `Code`), the same in every binding, also one that compiles a single type for decoding. A rule on a type the schema doesn't reach is not required: no value of the type is decoded, so its absence lets nothing through. The `rules` field of every reached package is checked first, whichever of its types are reached (§4). A package read from a directory or made from plain data carries no implementation. The error is reported once per type id, at no place, and its message names the type's id and its rule, and the two ways out: `@acme/ids@1#Id has the rule ulid, and this program has no implementation of it: add the package's rule (withRule), or take the package shape-only (shapeOnly)`.

<!-- rule: packages.rules.shape-only -->
**Shape only.** A program MAY take a package shape-only (`Package.shapeOnly(pkg)` in TypeScript, the same in each language's idiom): the rules of its types are not checked, their values are checked for their shape only, and `missing-codec` is not reported for them. The opt-out is per package, and written where the program gives the package, so reviewing that call shows what goes unchecked. It applies to official packages too. It doesn't excuse a `rules` field that breaks §4.

<!-- rule: packages.rules.with-rule -->
**Supplying a package's rule.** A program MAY supply the implementation of a package's rule for one of its types (`Package.withRule`): a check of the value the schema decoded, which the binding runs as §6 says. A rule supplied for a type that the package's `rules` field gives no rule is a mistake of the program's configuration (not of the data, so with no code of core §17).

<!-- rule: packages.rules.tools-hint -->
**Tools.** A tool that checks data with a schema (`haus check`, an editor) checks the official packages' rules, which it has built in (§2). For a reached package's rule that it has no implementation of, and no program to supply one, it reports instead, with the code `missing-codec`, a note of the lowest severity (a hint), once per import of such a package, at the import: `the rules of @acme/ids (Id: ulid) are not checked here`.

<!-- rule: codecs.api.one-per-id -->
**One codec per id.** An application sets at most one codec per id: a binding given two for one id rejects them, as a mistake of its configuration (not of the data, so with no code of core §17).

<!-- rule: codecs.api.no-codec-types -->
**A codec for a type that can't have one.** Codecs are for named types without parameters (core §13.4). A codec set for the id of a type that can't have one never runs: a generic type (`@acme/lib@1#Pair`, `prelude#Maybe`) or a `Stream` definition (`app#Log` for `type Log = Stream Entry`). A binding rejects it as a mistake of its configuration, as it rejects two codecs for one id, with no code, and its message says why: `Log is a Stream: set the codec for Entry`.

<!-- rule: codecs.unused.warning -->
**A codec that matches no type.** A codec set for an id that no type has never runs, and the values it was meant to check pass: a typo, or `@haus-fmt/money@2#Money` when the schema imports major 1. So a schema binding SHOULD report the warning `unused-codec` for a codec whose id is no type of the prelude or a standard module, nor of the schema's files and the packages they import. It is reported where the binding learns which codecs are set (when a set of codecs is built, a schema is compiled with them, or decoding starts), once per id, at no place, through the channel of its other schema warnings (`unknown-attribute`, `deprecated`, `no-json-form`); its message names the id. It MAY also be reported on request, through a function of the binding's that the application calls with its codecs and its schema, once per id, at no place: a binding whose codecs aren't bound to a schema (they are given to each decode) has no other place to report it. A binding MAY reject such a codec instead, as a mistake of its configuration, and MAY leave out codecs that a library ships as a set when the application passes the whole set.

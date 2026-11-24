# Publishing

How each binding and package gets to its users. No secrets here: publishing
runs from GitHub Actions with trusted publishing (OIDC) where the registry
supports it, so no registry token is stored in the repository's secrets.

| Language | Packages | Where | How | Status |
|---|---|---|---|---|
| TypeScript | `@haus-fmt/haus`, `@haus-fmt/effect`, `@haus-fmt/import` | npm | changesets, [release.yml](.github/workflows/release.yml) | published, 0.1.0 |
| Schema packages | `@haus-fmt/money`, `@haus-fmt/geo`, `@haus-fmt/uuid` | npm | the same | published, 1.0.0 |
| Zig, C | the Zig package, `libhaus` | GitHub release | tag `zig-vX.Y.Z`, [zig-release.yml](.github/workflows/zig-release.yml) | ready, not released yet |
| Rust | `haus-fmt`, `haus-fmt-schema`, `haus-fmt-build`, `haus-fmt-cli`; `haus-fmt-money`, `-geo`, `-uuid` | crates.io | a version bump merged to main, [rust-release.yml](.github/workflows/rust-release.yml) | `haus-fmt` 0.1.0 published by hand (outdated); 0.2.0 being set up |
| Python | `haus-fmt`; `haus-fmt-money`, `-geo`, `-uuid` | PyPI | a version bump merged to main, [python-release.yml](.github/workflows/python-release.yml) | `haus-fmt-geo` and `-uuid` 1.0.0 published by hand; `haus-fmt` 0.1.0 and `-money` 1.0.0 with the workflow |
| Go | `github.com/betalyra/haus-fmt/go` | the Go proxy, from git tags | tag `go/vX.Y.Z` | v0.1.0 |
| Swift | `Haus` (root `Package.swift`) | SwiftPM, from git tags | tag `vX.Y.Z` | 0.1.0 |
| JVM | `org.haus-fmt:haus`, `org.haus-fmt:haus-kotlin` | Maven Central | a version bump merged to main, [jvm-release.yml](.github/workflows/jvm-release.yml) (secrets, no OIDC) | 0.1.0 by hand |
| Roc | the Roc packages | GitHub release | | not yet |
| Command line | `haus` (crate `haus-fmt-cli`): binaries, installers, Homebrew | GitHub release, tap `betalyra/homebrew-tap` | with the crate's release, [haus-fmt-cli-release.yml](.github/workflows/haus-fmt-cli-release.yml) (dist) | being set up |
| Editors | VS Code extension `betalyra.haus` | VS Code Marketplace | a version bump merged to main, [vscode-release.yml](.github/workflows/vscode-release.yml) | published, 0.2.0 (by the workflow) |

## npm

Six packages from the pnpm workspace in `typescript/`:

- `@haus-fmt/haus`, `@haus-fmt/effect` and `@haus-fmt/import` share one version
  (a `fixed` group in [typescript/.changeset/config.json](typescript/.changeset/config.json)).
- The schema packages `@haus-fmt/money`, `@haus-fmt/geo` and `@haus-fmt/uuid`
  have their own versions. The major version is part of their types' identity
  (`@haus-fmt/money@1#Money`), so it changes only for a change that breaks the
  schema, never because haus had a release: their peer ranges on haus are
  `>=0.1.0`, and changesets bumps a peer dependent only when it falls out of
  range.

### A release

1. A PR that changes a published package adds a changeset: `pnpm changeset` in
   `typescript/`, then pick the packages, the bump and a line for the changelog.
2. On main, [release.yml](.github/workflows/release.yml) runs the TypeScript
   tests and opens or updates the PR "Release: npm". It bumps the versions,
   writes the changelogs and copies each schema package's version into its
   `package.haus`, `Cargo.toml` and `python/pyproject.toml`
   ([sync-versions.mts](typescript/scripts/sync-versions.mts)).
3. Merging that PR publishes every package whose version isn't on npm yet,
   with provenance, and tags each one (`@haus-fmt/haus@0.2.0`).

A failed or partial publish: run the workflow again (Actions → Release → Run
workflow). Versions already on npm are skipped.

### A new package

npm sets up a trusted publisher only for a package that exists, so a new
package is published once by hand, from a clean main:

```sh
cd typescript
pnpm install --frozen-lockfile && pnpm build && pnpm --filter "../extensions/*" build && node scripts/license.mts
npm login
pnpm --filter @haus-fmt/<name> publish --access public --no-git-checks --otp <code>
```

`pnpm build` builds only `typescript/packages/*`, hence the extensions' build.
[license.mts](typescript/scripts/license.mts) copies the repository's LICENSE
into each published package (npm ships it only from the package's folder).
`--filter "@haus-fmt/*"` publishes them all; a run cut off by an expired code
can be repeated with a new one, published versions are skipped.

Then, on npmjs.com, in the package's settings:

- Trusted publisher: GitHub Actions, organization `betalyra`, repository
  `haus-fmt`, workflow `release.yml`. Renaming the workflow file means setting
  this again for every package.
- Publishing access: "Require two-factor authentication and disallow bypass
  2fa tokens". The package can then only be published by the workflow (OIDC
  isn't a token, so trusted publishing still works) or by hand with 2FA.

A new package also needs, in its `package.json`: `license`, `repository` with
its `directory` (npm checks it against the provenance), `publishConfig.access:
public`, and `files` listing what it ships.

## Zig and C

A tag `zig-vX.Y.Z`, where X.Y.Z is the version in `zig/build.zig.zon`, runs
[zig-release.yml](.github/workflows/zig-release.yml). It tests, then creates a
GitHub release with the Zig package (`zig/` alone, as a tarball, since Zig
can't fetch a package from a subdirectory of a repository), its hash for
`build.zig.zon`, and `libhaus` with `haus.h` for several targets, static and
shared. There is no Zig registry.

```sh
git tag -s zig-vX.Y.Z -m "Zig binding X.Y.Z" && git push origin zig-vX.Y.Z
```

## VS Code

The extension (`editors/vscode`, its own pnpm workspace) goes to the Visual
Studio Marketplace as `betalyra.haus`. A release is a PR that bumps the
version in `editors/vscode/package.json` and moves the CHANGELOG's
"Unreleased" under it. Merged, it runs
[vscode-release.yml](.github/workflows/vscode-release.yml): when that version
isn't on the Marketplace yet, it typechecks, packages the `.vsix`, publishes it
and makes a GitHub release with it, tagged `vscode-vX.Y.Z`. A failed release:
run the workflow by hand without "whoami".

No secret. The job signs in to Microsoft Entra with its GitHub OIDC token, as
an app that is a member of the Marketplace publisher. The setup, once:

1. Entra (Azure portal → Microsoft Entra ID → App registrations): an app
   `haus-vscode-publish`, single tenant. Under Certificates & secrets →
   Federated credentials, a credential "GitHub Actions deploying Azure
   resources": organization `betalyra`, repository `haus-fmt`, entity type
   Environment, `vscode-marketplace`, audience `api://AzureADTokenExchange`.
   The form asks for the numeric IDs too; GitHub's tokens for this repository
   name them (`repo:betalyra@<org id>/haus-fmt@<repo id>:environment:vscode-marketplace`),
   from `gh api orgs/betalyra` and `gh api repos/betalyra/haus-fmt`.
2. GitHub (Settings → Environments): the environment `vscode-marketplace`,
   deployments from the branch `main` only, with the variables `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` (the app's
   client ID and the directory's tenant ID; identifiers, not secrets).
3. Marketplace: run the workflow by hand with "whoami" (Actions → VS Code
   release → Run workflow). It prints the app's Marketplace user ID; add that
   ID as a Contributor on the publisher's Members page
   (marketplace.visualstudio.com/manage/publishers/betalyra).

## Rust

Seven crates from the Cargo workspace in `rust/`:

- `haus-fmt`, `haus-fmt-schema`, `haus-fmt-build` and `haus-fmt-cli` share the
  version in `rust/Cargo.toml` (`workspace.package.version`). Their
  dependencies on each other name it too (`version = "0.2.0"` next to
  `path`): bump those with it.
- The schema crates `haus-fmt-money`, `-geo` and `-uuid` (in `extensions/`)
  have the version of their npm package, which the npm release PR writes into
  their `Cargo.toml`. Their README on crates.io is `README.rust.md`.

A release is a PR that bumps a version. Merged, it runs
[rust-release.yml](.github/workflows/rust-release.yml): it checks crates.io for
each crate's version, and when one is new, runs the Rust tests and publishes
the new ones, each after the crates it depends on. Merging the npm release PR
that bumps a schema package publishes its crate the same way. A failed
release: run the workflow by hand (Actions → Rust release → Run workflow).

Before a PR: `cargo publish --workspace --dry-run` in `rust/` packages and
builds every crate as crates.io would, against the workspace's unpublished
versions.

### A new crate

crates.io sets up trusted publishing only for a crate that exists, so a new
crate is published once by hand, from a clean main, with a token from
crates.io (Account Settings → API Tokens, scope `publish-new`, short expiry):

```sh
cd rust
cargo login            # paste the token
cargo publish -p <crate>
cargo logout
```

Crates that depend on it go after it. The token needs `publish-update` too
when a crate it publishes exists already; a pattern `haus-fmt*` limits it to
ours. crates.io limits new crates per account (`429 Too Many Requests` after
about six in a row): wait for the time the error names, then publish the rest
with `cargo publish -p`. Then, on crates.io, in the crate's
settings → Trusted Publishing → Add: GitHub, owner `betalyra`, repository
`haus-fmt`, workflow `rust-release.yml`, environment `crates-io`. The GitHub
environment `crates-io` (Settings → Environments) allows deployments from the
branch `main` only. Add the new crate to `CRATES` in the workflow, in
dependency order.

## The command line

`haus` (`rust/haus-cli`, the crate `haus-fmt-cli`) is also released as
binaries, built by [dist](https://github.com/axodotdev/cargo-dist) from
[dist-workspace.toml](dist-workspace.toml): macOS, Linux (glibc and musl) and
Windows, on x86-64 and ARM, on a GitHub release tagged `haus-fmt-cli-vX.Y.Z`,
with checksums, attestations, shell and PowerShell installers, and the
formula `haus` in the tap `betalyra/homebrew-tap`:

```sh
brew install betalyra/tap/haus
curl --proto '=https' --tlsv1.2 -LsSf https://github.com/betalyra/haus-fmt/releases/latest/download/haus-fmt-cli-installer.sh | sh
```

When the Rust release publishes a new `haus-fmt-cli`, it starts
[haus-fmt-cli-release.yml](.github/workflows/haus-fmt-cli-release.yml), which
makes the tag and the release. By hand (a failed or the first release):
`gh workflow run haus-fmt-cli-release.yml -f tag=haus-fmt-cli-vX.Y.Z`.

The workflow is generated: after a change to `dist-workspace.toml` (or a new
dist), run `dist generate` and commit what it writes; it fails CI when it is
out of date. It is named after `tag-namespace`, so it doesn't touch the npm
`release.yml`.

The formula is pushed to the tap with `HOMEBREW_TAP_TOKEN`, a repository
secret: a fine-grained token that can write the contents of
`betalyra/homebrew-tap` only, kept in 1Password and renewed before it expires.

## Python

Four projects: `haus-fmt` (`python/`, built with uv) and the schema packages
`haus-fmt-money`, `-geo` and `-uuid` (`extensions/*/python/`, built with
hatchling, which copies the schema files into the module). The schema packages
have the version of their npm package, which the npm release PR writes into
their `pyproject.toml`.

A release is a PR that bumps a version. Merged, it runs
[python-release.yml](.github/workflows/python-release.yml): it checks PyPI for
each project's version, and for each new one runs its tests and builds it.
A second job, the only one with the OIDC permission, uploads what was built,
with attestations. A failed release: run the workflow by hand (Actions →
Python release → Run workflow).

### A new project

PyPI can set up trusted publishing before a project exists, as a *pending
publisher* (Account → Publishing): GitHub, owner `betalyra`, repository
`haus-fmt`, workflow `python-release.yml`, environment `pypi`. The first upload
by the workflow creates the project. But a pending publisher's configuration
must be unique: only one project at a time can be pending with the same
workflow and environment. For more at once, publish the others by hand once
and give them ordinary publishers (the project's settings → Publishing), which
may share a configuration:

```sh
cd extensions/<name>/python && uv build
read -rs "UV_PUBLISH_TOKEN?PyPI token: " && echo && UV_PUBLISH_TOKEN=$UV_PUBLISH_TOKEN uv publish dist/*; unset UV_PUBLISH_TOKEN
```

The token: pypi.org → Account settings → API tokens, scope "Entire account"
for a project that doesn't exist yet; delete it afterwards. uv may keep a
token from an earlier upload and then not ask; passing it as above avoids a
stale one. The GitHub environment `pypi` allows deployments from the branch
`main` only.

## Go

Nothing is uploaded: the module `github.com/betalyra/haus-fmt/go` is in a
subdirectory, so its versions are tags `go/vX.Y.Z`. The Go proxy fetches a
version the first time someone asks for it, and pkg.go.dev lists it then.

```sh
git tag -s go/vX.Y.Z -m "Go module X.Y.Z" && git push origin go/vX.Y.Z
GOPROXY=https://proxy.golang.org go list -m github.com/betalyra/haus-fmt/go@vX.Y.Z   # asks the proxy once
```

The module has no dependencies; a `replace` in `go/go.mod` would keep it from
being used as a dependency.

## Swift

Nothing is uploaded: SwiftPM depends on the repository and reads plain semver
tags at its root (`vX.Y.Z`), against the root `Package.swift` (the sources are
in `swift/`).

```sh
git tag -s vX.Y.Z -m "Swift package X.Y.Z" && git push origin vX.Y.Z
```

Tags of this form are the Swift package's only: other languages use prefixed
tags.

## Java and Kotlin

`org.haus-fmt:haus` and `org.haus-fmt:haus-kotlin`, from the Gradle build in
`jvm/`, go to Maven Central through the Central Portal (central.sonatype.com,
namespace `org.haus-fmt`, verified). Central has no trusted publishing: it
takes a user token and signed files. Both are kept in 1Password, and copied
into the GitHub environment `maven-central` (main only) as secrets for the
release workflow.

A release is a PR that bumps the version in `jvm/build.gradle.kts`. Merged,
it runs [jvm-release.yml](.github/workflows/jvm-release.yml): when that version
isn't on Maven Central yet, it tests, builds the libraries signed and uploads
them; the portal publishes them once they are valid, and the workflow waits
for that. A failed release: run the workflow by hand.

Once:

1. A user token from the portal (account → Generate User Token), saved as a
   1Password item `haus-sonatype-publishing` (username, password) in the vault `Employee`.
2. A signing key, made in a keyring that is thrown away afterwards, with a
   passphrase from 1Password, and saved in the same item as the passphrase:

   ```sh
   op item create --category password --title haus-signing-key --vault Employee --generate-password=40,letters,digits
   mkdir -m 700 /tmp/haus-gpg && export GNUPGHOME=/tmp/haus-gpg
   op read "op://Employee/haus-signing-key/password" |
     gpg --batch --pinentry-mode loopback --passphrase-fd 0 --quick-gen-key "haus-fmt releases" rsa4096 sign 2y
   FPR=$(gpg --list-keys --with-colons | awk -F: '/^fpr/ { print $10; exit }')
   op read "op://Employee/haus-signing-key/password" |
     gpg --batch --pinentry-mode loopback --passphrase-fd 0 --armor --export-secret-keys "$FPR" > /tmp/haus-gpg/signing-key.asc
   op item edit haus-signing-key --vault Employee "signing-key.asc[file]=/tmp/haus-gpg/signing-key.asc" "fingerprint[text]=$FPR"
   gpg --keyserver keyserver.ubuntu.com --send-keys "$FPR"
   gpgconf --kill gpg-agent; rm -rP /tmp/haus-gpg; unset GNUPGHOME FPR
   ```

   Central checks the signatures against the public key on the keyserver. In
   `op`'s assignments a dot separates section and field, so the key is the
   file `asc` in the section `signing-key`:
   `op://Employee/haus-signing-key/signing-key/asc`.
3. The four secrets of the environment `maven-central`, straight from
   1Password (again when the token is renewed: it expires):

   ```sh
   op read "op://Employee/haus-signing-key/signing-key/asc" | gh secret set SIGNING_KEY --env maven-central --repo betalyra/haus-fmt
   op read "op://Employee/haus-signing-key/password" | gh secret set SIGNING_PASSWORD --env maven-central --repo betalyra/haus-fmt
   op read "op://Employee/haus-sonatype-publishing/username" | gh secret set CENTRAL_USERNAME --env maven-central --repo betalyra/haus-fmt
   op read "op://Employee/haus-sonatype-publishing/password" | gh secret set CENTRAL_PASSWORD --env maven-central --repo betalyra/haus-fmt
   ```

By hand, without the workflow (e.g. when GitHub Actions is down), from `jvm/`:

```sh
SIGNING_KEY="$(op read 'op://Employee/haus-signing-key/signing-key/asc')" \
SIGNING_PASSWORD="op://Employee/haus-signing-key/password" \
CENTRAL_USERNAME="op://Employee/haus-sonatype-publishing/username" \
CENTRAL_PASSWORD="op://Employee/haus-sonatype-publishing/password" \
op run -- sh -c './gradlew clean test publishAllPublicationsToStagingRepository -Prelease && sh scripts/central-upload.sh'
```

`op run` resolves fields only, so the key, a file in the item, is read by
`op read`; both leave it in the environment of this one command. The build
signs every file in memory (`-Prelease`; without it nothing is signed,
to check the layout in `build/staging`). By hand, the script uploads the
bundle as a deployment to check: the portal validates it, and it goes to
Central when you press Publish (central.sonatype.com → Deployments); the
workflow sets `CENTRAL_PUBLISHING_TYPE=AUTOMATIC` instead. It is on Maven Central
within about 30 minutes; a version can't be changed or removed afterwards.

## Not published yet

- **Roc:** Roc packages are URLs of bundles (`.tar.br`), built with
  `roc build --bundle`, attached to a GitHub release.

Each language has its own version and releases on its own; the schema
packages have the version of their npm package in every language.

# Publishing

How each binding and package gets to its users. No secrets here: publishing
runs from GitHub Actions with trusted publishing (OIDC) where the registry
supports it, so no registry token is stored in the repository's secrets.

| Language | Packages | Where | How | Status |
|---|---|---|---|---|
| TypeScript | `@haus-fmt/haus`, `@haus-fmt/effect`, `@haus-fmt/import` | npm | changesets, [release.yml](.github/workflows/release.yml) | published, 0.1.0 |
| Schema packages | `@haus-fmt/money`, `@haus-fmt/geo`, `@haus-fmt/uuid` | npm | the same | published, 1.0.0 |
| Zig, C | the Zig package, `libhaus` | GitHub release | tag `zig-vX.Y.Z`, [zig-release.yml](.github/workflows/zig-release.yml) | ready, not released yet |
| Rust | `haus-fmt`, `haus-fmt-schema`, `haus-fmt-build`, `haus-fmt-cli`; `haus-fmt-money`, `-geo`, `-uuid` | crates.io | | not yet (the name `haus-fmt` is held) |
| Python | `haus-fmt`; `haus-fmt-money`, `-geo`, `-uuid` | PyPI | | not yet (the name `haus-fmt` is held) |
| Go | `github.com/betalyra/haus-fmt/go` | the Go proxy, from git tags | | not yet |
| Swift | `Haus` (root `Package.swift`) | SwiftPM, from git tags | | not yet |
| JVM | `org.haus-fmt:haus`, `haus-kotlin` | Maven Central | | not yet |
| Roc | the Roc packages | GitHub release | | not yet |
| Editors | VS Code extension `betalyra.haus` | VS Code Marketplace | a version bump merged to main, [vscode-release.yml](.github/workflows/vscode-release.yml) | 0.1.0 published by hand; the workflow is being set up |

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

## Not published yet

To be filled in as each one is set up. What's known:

- **Rust:** crates.io supports trusted publishing. The crates depend on each
  other, so they go out in order: `haus-fmt`, `haus-fmt-schema`,
  `haus-fmt-build`, `haus-fmt-cli`, then the schema crates.
- **Python:** PyPI supports trusted publishing.
- **Go:** a module in a subdirectory is versioned by tags `go/vX.Y.Z`; the Go
  proxy picks them up, nothing is uploaded.
- **Swift:** SwiftPM reads plain semver tags (`X.Y.Z` or `vX.Y.Z`) at the
  repository root, against the root `Package.swift`.
- **JVM:** Maven Central has no trusted publishing: it needs a token and a
  signing key as secrets, and the namespace `org.haus-fmt` verified through a
  DNS record on haus-fmt.org.

The plan is one version for all bindings, kept by changesets: the release PR
then also copies `@haus-fmt/haus`'s version into each binding's manifest.

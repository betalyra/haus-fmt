# Changesets

A change to a published npm package comes with a changeset: run `pnpm changeset`
in `typescript/`, pick the packages and the bump, and write one line for the
changelog. On main, the release workflow (`.github/workflows/release.yml`)
collects them into a release PR; merging it publishes.

- `@haus-fmt/haus`, `effect` and `import` share one version.
- The schema packages (`@haus-fmt/money`, `geo`, `uuid`) have their own. Their
  major is part of their types' identity (`@haus-fmt/money@1#Money`): a major
  bump is a new package version in the spec's sense, so only for a change that
  breaks its schema. `pnpm version-packages` copies their version into
  `package.haus`, `Cargo.toml` and `python/pyproject.toml`.

The whole process, for every language: [PUBLISHING.md](../../PUBLISHING.md).

# @haus-fmt/effect

## 0.2.0

### Minor Changes

- 1034c68: Every type of the prelude takes a codec, by its id (`Haus.prelude("Int")` for `prelude#Int`), not only `Decimal`: it applies to every value of the type, in packages' types too, and the declarations type each through `Haus.Lookup`.

### Patch Changes

- Updated dependencies [816f39f]
- Updated dependencies [1034c68]
  - @haus-fmt/haus@0.2.0

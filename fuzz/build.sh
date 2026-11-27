#!/bin/sh
# Build the parsers, std/time checkers, profile codecs, schema decoders, schema-file checkers, JSON converters and formatters under test (fuzz/README.md).
# Needs a JDK 17 or later (JAVA_HOME) for the JVM runner.
#
#   sh fuzz/build.sh              everything
#   sh fuzz/build.sh lean swift   only those parts (CI builds each part on its own runner)
#
# Parts: lean, rust, typescript, python, go, zig, swift, jvm, roc, ocaml.
set -e
cd "$(dirname "$0")/.."

lean() { (cd spec/lean && lake build haus-ref haus-rules); }

rust() {
  (cd rust && cargo build -q --release -p haus-fmt --example fuzz_runner --example time_runner)
  (cd fuzz/schema-rust && cargo build -q --release)
}

typescript() {
  (cd typescript && pnpm --filter ./packages/haus build >/dev/null && pnpm --filter ./packages/effect build >/dev/null && pnpm --filter ./packages/import build >/dev/null)
  (cd typescript && pnpm --filter ../extensions/money --filter ../extensions/geo --filter ../extensions/uuid build >/dev/null)
}

python() { (cd python && uv sync -q); }

go() {
  mkdir -p fuzz/.build
  (cd fuzz/go && command go build -o ../.build/go-runner .)
}

# The Zig runner (zig/test/fuzz_runner.zig): zig/zig-out/bin/zig-runner.
# For the baseline CPU, not the build machine's (Zig's default): in CI the
# fuzz jobs run on other machines, and a newer instruction there is SIGILL.
zig() { (cd zig && command zig build fuzz-runner -Doptimize=ReleaseSafe -Dcpu=baseline); }

swift() {
  mkdir -p fuzz/.build
  # On Linux the Swift runner links Swift's standard library in, so the fuzz jobs run it without Swift.
  swift_static=""; [ "$(uname)" = Linux ] && swift_static="--static-swift-stdlib"
  (cd fuzz/swift-runner && command swift build -q -c release $swift_static && cp "$(command swift build -c release --show-bin-path)/swift-runner" ../.build/swift-runner)
}

# The JVM runner (fuzz/jvm): Gradle installs it into fuzz/.build/jvm-runner.
jvm() { (cd jvm && ./gradlew -q --no-daemon :fuzz-runner:installDist); }

# The schema and JSON runners' modules are generated with haus-gen, so this part needs Rust (cargo) too.
roc() {
  mkdir -p fuzz/.build
  (cd roc/fuzz && command roc build --output=../../fuzz/.build/roc-runner runner.roc >/dev/null)
  (cd roc/fuzz && command roc build --output=../../fuzz/.build/roc-time-runner time_runner.roc >/dev/null)
  (cd fuzz/roc && command roc build --output=../.build/roc-profile-runner profile_runner.roc >/dev/null)
  node fuzz/roc/gen_schemas.ts >/dev/null
  (cd fuzz/roc && command roc build --output=../.build/roc-schema-runner schema_runner.roc >/dev/null)
  node fuzz/roc/gen_json_schemas.ts >/dev/null
  (cd fuzz/roc && command roc build --output=../.build/roc-json-runner json_runner.roc >/dev/null)
}

# The OCaml runner (ocaml/fuzz/runner.ml, a clean-room test implementation):
# ocaml/_build/default/fuzz/runner.exe. Needs OCaml 5 with dune and digestif.
ocaml() { (cd ocaml && command dune build fuzz/runner.exe); }

parts=${*:-lean rust typescript python go zig swift jvm roc ocaml}
for part in $parts; do
  case $part in
    lean | rust | typescript | python | go | zig | swift | jvm | roc | ocaml) $part ;;
    *) echo "fuzz/build.sh: unknown part '$part'" >&2; exit 2 ;;
  esac
done
echo "built: $parts"

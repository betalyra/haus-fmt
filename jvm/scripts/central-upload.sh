#!/bin/sh
# Uploads a release to Maven Central (PUBLISHING.md, "Java and Kotlin"):
#
#   ./gradlew clean test publishAllPublicationsToStagingRepository -Prelease
#   sh scripts/central-upload.sh
#
# from jvm/. It zips build/staging (the libraries, their POMs, checksums and
# signatures) and uploads the bundle to the Central Portal as a deployment to
# check: the portal validates it, and it is published only when you press
# Publish there (central.sonatype.com → Deployments).
#
# The portal's user token comes from CENTRAL_USERNAME and CENTRAL_PASSWORD
# (given by `op run`, PUBLISHING.md), else from ~/.gradle/gradle.properties
# (centralUsername, centralPassword), so it never appears in the shell's
# history or in this repository.
set -eu

cd "$(dirname "$0")/.."
staging=build/staging
[ -d "$staging/org" ] || { echo "no release in $staging: run the Gradle publish first" >&2; exit 1; }
if ! find "$staging" -name '*.jar.asc' | grep -q .; then
  echo "the files in $staging aren't signed: publish with -Prelease" >&2
  exit 1
fi

props="$HOME/.gradle/gradle.properties"
prop() { [ -f "$props" ] && sed -n "s/^$1=//p" "$props" | head -n 1; }
user=${CENTRAL_USERNAME:-$(prop centralUsername)}
pass=${CENTRAL_PASSWORD:-$(prop centralPassword)}
[ -n "$user" ] && [ -n "$pass" ] || { echo "no token: set CENTRAL_USERNAME and CENTRAL_PASSWORD, or centralUsername and centralPassword in $props" >&2; exit 1; }

version=$(sed -n 's/^    version = "\(.*\)"$/\1/p' build.gradle.kts)
bundle=build/central-bundle-$version.zip
# The repository's metadata files aren't part of a release: Central makes its own.
(cd "$staging" && zip -qr "../$(basename "$bundle")" org -x '*/maven-metadata.xml*')
echo "uploading $bundle"

# The token goes to curl on stdin, not on its command line.
printf 'header = "Authorization: Bearer %s"\n' "$(printf '%s:%s' "$user" "$pass" | base64)" |
  curl --fail-with-body -sS --config - \
    --form "bundle=@$bundle" \
    "https://central.sonatype.com/api/v1/publisher/upload?name=haus-jvm-$version&publishingType=USER_MANAGED"
echo
echo "uploaded: check and publish it at https://central.sonatype.com/publishing/deployments"

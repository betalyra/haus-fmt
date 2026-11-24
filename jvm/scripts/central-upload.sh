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

# USER_MANAGED (by hand): published when you press Publish in the portal.
# AUTOMATIC (the release workflow): published once it is valid; the script
# waits until Central says so.
type=${CENTRAL_PUBLISHING_TYPE:-USER_MANAGED}
api=https://central.sonatype.com/api/v1/publisher
# The token goes to curl on stdin, not on its command line (base64 -w0 isn't
# portable: GNU base64 wraps long lines, hence tr).
auth=$(printf '%s:%s' "$user" "$pass" | base64 | tr -d '\n')
central() { printf 'header = "Authorization: Bearer %s"\n' "$auth" | curl --fail-with-body -sS --config - "$@"; }

id=$(central --form "bundle=@$bundle" "$api/upload?name=haus-jvm-$version&publishingType=$type")
echo "deployment $id"
if [ "$type" = USER_MANAGED ]; then
  echo "uploaded: check and publish it at https://central.sonatype.com/publishing/deployments"
  exit 0
fi

# Validation takes minutes, publishing up to half an hour; PUBLISHING means
# it was accepted and will be on Central.
for _ in $(seq 1 120); do
  status=$(central -X POST "$api/status?id=$id")
  state=$(printf '%s' "$status" | sed -n 's/.*"deploymentState" *: *"\([A-Z]*\)".*/\1/p')
  echo "state: $state"
  case "$state" in
    PUBLISHING | PUBLISHED) exit 0 ;;
    FAILED) echo "$status" >&2; exit 1 ;;
  esac
  sleep 15
done
echo "deployment $id isn't validated after 30 minutes" >&2
exit 1

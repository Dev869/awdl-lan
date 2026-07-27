#!/bin/bash
# Builds a release-ready mod jar and drops it in dist/.
#
# Runs both test suites first, then verifies the packaged jar rather than trusting
# that Gradle copied the right things. The Swift binary is the part most likely to
# go stale or missing, so it is checked byte-for-byte against the one just built.
set -euo pipefail
cd "$(dirname "$0")"

export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home}
export PATH="$JAVA_HOME/bin:$PATH"

VERSION=$(grep '^mod_version=' mod/gradle.properties | cut -d= -f2)
MC_RANGE=$(python3 -c "import json;print(json.load(open('mod/src/main/resources/fabric.mod.json'))['depends']['minecraft'])")
HELPER=helper/.build/release/mcdirect-helper
JAR=mod/build/libs/lan-over-direct-$VERSION.jar

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

step "Building the helper (Swift)"
( cd helper && swift build -c release )

step "Helper relay test"
helper/test.sh

step "Transport self-check (no Minecraft classpath)"
mod/test.sh

step "Building the mod"
( cd mod && gradle build -q )

step "Verifying the packaged jar"
[ -f "$JAR" ] || { echo "FAIL: $JAR not produced"; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
unzip -qo "$JAR" -d "$work"

for required in native/mcdirect-helper fabric.mod.json lan-over-direct.mixins.json \
                assets/lan-over-direct/icon.png assets/lan-over-direct/lang/en_us.json; do
    [ -e "$work/$required" ] || { echo "FAIL: jar is missing $required"; exit 1; }
done

# A stale embedded binary would ship silently and fail only on a user's machine.
if ! cmp -s "$HELPER" "$work/native/mcdirect-helper"; then
    echo "FAIL: embedded helper differs from helper/.build/release"; exit 1
fi

# It must still be a valid signed arm64 Mach-O after the round trip.
chmod +x "$work/native/mcdirect-helper"
codesign -v "$work/native/mcdirect-helper" 2>/dev/null || { echo "FAIL: embedded helper signature invalid"; exit 1; }
"$work/native/mcdirect-helper" >/dev/null 2>&1 && { echo "FAIL: helper should exit 2 with no args"; exit 1; }

mkdir -p dist
cp "$JAR" dist/
SIZE=$(du -h "dist/lan-over-direct-$VERSION.jar" | cut -f1)
SHA=$(shasum -a 512 "dist/lan-over-direct-$VERSION.jar" | cut -c1-16)

cat <<EOF

$(printf '\033[1;32m✓ dist/lan-over-direct-%s.jar\033[0m' "$VERSION")  ($SIZE, sha512 ${SHA}...)

Upload that one file to Modrinth. Settings to select:

  Version number     $VERSION
  Loaders            Fabric
  Game versions      $MC_RANGE  (tick 26.1, 26.1.2, 26.2)
  Environment        Client required, server unsupported
  Dependencies       Fabric API — required

Field-by-field text for the project page is in MODRINTH.md.
EOF

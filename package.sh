#!/bin/bash
# Builds the release-ready mod jars and drops them in dist/.
#
# One jar per Minecraft line, from the TARGETS map in mod/build.gradle. Runs both test
# suites first, then verifies each packaged jar rather than trusting that Gradle copied
# the right things. The Swift binary is the part most likely to go stale or missing, so
# it is checked byte-for-byte against the one just built, and for both architectures.
set -euo pipefail
cd "$(dirname "$0")"

export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home}
export PATH="$JAVA_HOME/bin:$PATH"

VERSION=$(grep '^mod_version=' mod/gradle.properties | cut -d= -f2)
HELPER=helper/.build/apple/Products/Release/awdl-lan-helper

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
STARTED=$(date +%s)

# "<id>|<version-suffix>|<minecraft range>" per line, straight from build.gradle so
# this script never carries a second, drifting copy of the target list.
TARGETS=$( cd mod && gradle -q targets )

step "Building the helper (Swift, arm64 + x86_64)"
helper/build.sh
lipo -archs "$HELPER" | grep -q x86_64 && lipo -archs "$HELPER" | grep -q arm64 \
    || { echo "FAIL: helper is not universal: $(lipo -archs "$HELPER")"; exit 1; }


step "Helper relay test"
helper/test.sh

step "Transport self-check (no Minecraft classpath)"
mod/test.sh

while IFS="|" read -r id _ range; do
    step "Building the mod (Minecraft $range)"
    ( cd mod && gradle build -q -Pmc="$id" )
done <<< "$TARGETS"

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# Each jar gets the same treatment; nothing here is specific to a Minecraft line.
verify_jar() {
    local jar=$1 range=$2
    step "Verifying $(basename "$jar")"
    [ -f "$jar" ] || { echo "FAIL: $jar not produced"; exit 1; }
    rm -rf "$work"/*
    unzip -qo "$jar" -d "$work"

    for required in native/awdl-lan-helper fabric.mod.json awdl-lan.mixins.json \
                    assets/awdl-lan/icon.png assets/awdl-lan/lang/en_us.json; do
        [ -e "$work/$required" ] || { echo "FAIL: jar is missing $required"; exit 1; }
    done

    # A stale embedded binary would ship silently and fail only on a user's machine.
    if ! cmp -s "$HELPER" "$work/native/awdl-lan-helper"; then
        echo "FAIL: embedded helper differs from $HELPER"; exit 1
    fi

    # It must still be a valid signed universal Mach-O after the round trip. Shipping
    # an arm64-only slice is how Intel Macs get silently locked out.
    chmod +x "$work/native/awdl-lan-helper"
    archs=$(lipo -archs "$work/native/awdl-lan-helper")
    [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "FAIL: embedded helper is $archs, not universal"; exit 1; }
    codesign -v "$work/native/awdl-lan-helper" 2>/dev/null || { echo "FAIL: embedded helper signature invalid"; exit 1; }
    "$work/native/awdl-lan-helper" >/dev/null 2>&1 && { echo "FAIL: helper should exit 2 with no args"; exit 1; }

    # The native slice is the one that gets run here; the other one is the whole point
    # of shipping universal, so run it too rather than trusting that lipo put it there.
    if arch -x86_64 /usr/bin/true 2>/dev/null; then
        # Exit 2 is success here, so capture the status rather than letting `set -e`
        # treat the usage exit as a failure and kill the script.
        rc=0; arch -x86_64 "$work/native/awdl-lan-helper" >/dev/null 2>&1 || rc=$?
        [ "$rc" -eq 2 ] || { echo "FAIL: embedded helper does not run under x86_64 (exit $rc)"; exit 1; }
    else
        echo "  note: Rosetta absent, x86_64 slice not executed"
    fi

    # The three per-target fields are template-expanded, and a jar that claims the
    # wrong Minecraft range or Java level fails at load on a player's machine, not here.
    grep -q "\"minecraft\": \"$range\"" "$work/fabric.mod.json" \
        || { echo "FAIL: jar claims $(grep -o '"minecraft": "[^"]*"' "$work/fabric.mod.json"), expected $range"; exit 1; }
    for f in "$work/fabric.mod.json" "$work/awdl-lan.mixins.json"; do
        grep -q '\${' "$f" || continue
        echo "FAIL: unexpanded template in $(basename "$f")"; exit 1
    done

    step "Checking jar references resolve"
    # Mixin targets, entrypoints, and lang keys are resolved by name at load time, so a
    # typo or a moved class survives compilation and fails only when a player opens the
    # screen. Check them against the packaged jar.
    JARDIR="$work" python3 - <<'PY'
import json, os, pathlib, re, sys

root = pathlib.Path(os.environ["JARDIR"])
fm = json.loads((root / "fabric.mod.json").read_text())
problems = []

for entry in fm.get("mixins", []):
    cfg = entry["config"] if isinstance(entry, dict) else entry
    path = root / cfg
    if not path.exists():
        problems.append(f"mixin config missing: {cfg}")
        continue
    mx = json.loads(path.read_text())
    pkg = mx["package"].replace(".", "/")
    for name in mx.get("mixins", []) + mx.get("client", []) + mx.get("server", []):
        if not (root / pkg / (name.replace(".", "/") + ".class")).exists():
            problems.append(f"mixin class missing: {mx['package']}.{name}")

for kind, classes in fm.get("entrypoints", {}).items():
    for cls in classes:
        target = cls["value"] if isinstance(cls, dict) else cls
        if not (root / (target.replace(".", "/") + ".class")).exists():
            problems.append(f"entrypoint class missing ({kind}): {target}")

if "icon" in fm and not (root / fm["icon"]).exists():
    problems.append(f"icon missing: {fm['icon']}")

lang_path = root / "assets/awdl-lan/lang/en_us.json"
if not lang_path.exists():
    problems.append("en_us.json missing")
else:
    lang = json.loads(lang_path.read_text())
    used = set()
    for java in pathlib.Path("mod/src").rglob("*.java"):
        used |= set(re.findall(r'translatable\(\s*"([^"]+)"', java.read_text()))
    for key in sorted(k for k in used if k.startswith("awdl-lan")):
        if key not in lang:
            problems.append(f"translation key used but not defined: {key}")

if problems:
    print("\n".join("FAIL: " + p for p in problems))
    sys.exit(1)
print("mixin targets, entrypoints, icon and translation keys all resolve")
PY
}

while IFS="|" read -r id suffix range; do
    jar="mod/build/libs/awdl-lan-$VERSION$suffix.jar"
    # build/libs is never cleaned, so a jar older than this run is one Gradle did not
    # just produce — a rename or a failed target would otherwise ship the last release.
    [ -f "$jar" ] && [ "$(stat -f %m "$jar")" -ge "$STARTED" ] \
        || { echo "FAIL: $jar was not produced by this run"; exit 1; }
    verify_jar "$jar" "$range"
done <<< "$TARGETS"

# Only now is it safe to replace the last release's jars.
mkdir -p dist
rm -f dist/*.jar
while IFS="|" read -r id suffix range; do
    cp "mod/build/libs/awdl-lan-$VERSION$suffix.jar" dist/
done <<< "$TARGETS"

step "Release summary"
while IFS="|" read -r id suffix range; do
    jar="dist/awdl-lan-$VERSION$suffix.jar"
    printf '  %-32s %s  %s  (sha512 %s...)\n' "$(basename "$jar")" \
        "$(du -h "$jar" | cut -f1)" "$range" "$(shasum -a 512 "$jar" | cut -c1-12)"
done <<< "$TARGETS"

cat <<EOF

Every jar above goes up to Modrinth as its own version of $VERSION, with the game
versions its range covers ticked. Loaders: Fabric. Environment: client-side only
(+ works in singleplayer). Dependencies: Fabric API — required.

Each jar is built against the newest Minecraft in its range and runs on the rest:
the intermediary names it compiles against are identical across the range.

Field-by-field text for the project page is in MODRINTH.md.
EOF

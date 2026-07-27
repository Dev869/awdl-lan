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
HELPER=helper/.build/release/awdl-lan-helper
JAR=mod/build/libs/awdl-lan-$VERSION.jar

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

for required in native/awdl-lan-helper fabric.mod.json awdl-lan.mixins.json \
                assets/awdl-lan/icon.png assets/awdl-lan/lang/en_us.json; do
    [ -e "$work/$required" ] || { echo "FAIL: jar is missing $required"; exit 1; }
done

# A stale embedded binary would ship silently and fail only on a user's machine.
if ! cmp -s "$HELPER" "$work/native/awdl-lan-helper"; then
    echo "FAIL: embedded helper differs from helper/.build/release"; exit 1
fi

# It must still be a valid signed arm64 Mach-O after the round trip.
chmod +x "$work/native/awdl-lan-helper"
codesign -v "$work/native/awdl-lan-helper" 2>/dev/null || { echo "FAIL: embedded helper signature invalid"; exit 1; }
"$work/native/awdl-lan-helper" >/dev/null 2>&1 && { echo "FAIL: helper should exit 2 with no args"; exit 1; }

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
    for java in pathlib.Path("mod/src/main/java").rglob("*.java"):
        used |= set(re.findall(r'translatable\(\s*"([^"]+)"', java.read_text()))
    for key in sorted(k for k in used if k.startswith("awdl-lan")):
        if key not in lang:
            problems.append(f"translation key used but not defined: {key}")

if problems:
    print("\n".join("FAIL: " + p for p in problems))
    sys.exit(1)
print("mixin targets, entrypoints, icon and translation keys all resolve")
PY

mkdir -p dist
cp "$JAR" dist/
SIZE=$(du -h "dist/awdl-lan-$VERSION.jar" | cut -f1)
SHA=$(shasum -a 512 "dist/awdl-lan-$VERSION.jar" | cut -c1-16)

cat <<EOF

$(printf '\033[1;32m✓ dist/awdl-lan-%s.jar\033[0m' "$VERSION")  ($SIZE, sha512 ${SHA}...)

Upload that one file to Modrinth. Settings to select:

  Version number     $VERSION
  Loaders            Fabric
  Game versions      $MC_RANGE  (tick 26.1, 26.1.2, 26.2)
  Environment        Client-side only (+ works in singleplayer)
  Dependencies       Fabric API — required

Field-by-field text for the project page is in MODRINTH.md.
EOF

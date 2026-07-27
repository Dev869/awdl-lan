#!/bin/bash
# Compiles and runs the HelperProcess self-check. No Gradle, no Minecraft, no network.
#
# Only the transport-layer classes are built here. That is the point: they must stay
# free of Minecraft and Fabric imports so this check runs in seconds against plain
# javac. The guard below enforces it, because the property rots silently otherwise
# (it already did once, the moment the mod entrypoint was added).
set -e
cd "$(dirname "$0")"

PORTABLE=(
    src/main/java/dev/lanoverdirect/HelperProcess.java
    src/main/java/dev/lanoverdirect/HelperBinary.java
    src/test/java/dev/lanoverdirect/HelperProcessSelfCheck.java
)

if grep -lE '^import (net\.minecraft|net\.fabricmc)' "${PORTABLE[@]}"; then
    echo "FAIL: the files listed above import Minecraft or Fabric."
    echo "      They are the layer that must stay testable without a game classpath."
    exit 1
fi

export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home}
export PATH="$JAVA_HOME/bin:$PATH"

rm -rf out
javac -d out "${PORTABLE[@]}"
java -ea -cp out dev.lanoverdirect.HelperProcessSelfCheck

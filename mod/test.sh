#!/bin/bash
# Compiles and runs the HelperProcess self-check. No Gradle, no Minecraft, no network.
set -e
cd "$(dirname "$0")"
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}
export PATH="$JAVA_HOME/bin:$PATH"
rm -rf out
javac -d out $(find src -name '*.java')
java -ea -cp out dev.lanoverdirect.HelperProcessSelfCheck

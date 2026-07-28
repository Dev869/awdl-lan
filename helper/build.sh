#!/bin/bash
# Builds the helper as a universal binary and signs it.
#
# Both steps matter. Plenty of Macs that can do AWDL are Intel, and lipo's merge into
# a fat binary leaves the result unsigned as far as codesign is concerned — the
# per-slice signatures the linker applies do not survive it. macOS will not run an
# unsigned arm64 executable, so the merged file has to be re-signed, ad-hoc, the way
# a single-slice build already was.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64
codesign -s - -f .build/apple/Products/Release/awdl-lan-helper

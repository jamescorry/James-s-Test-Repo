#!/usr/bin/env bash
# Build Watch Key for one device, or package it for the store.
#
# Needs the Connect IQ SDK on PATH. See README for how to get it - the SDK
# itself is a plain download, but the device files it compiles against come
# from Garmin's authenticated API, so a Garmin account is required.
#
#   scripts/build.sh                  # build a .prg for fenix7
#   scripts/build.sh fenix7           # build a .prg for a named device
#   scripts/build.sh --package        # build a store-ready .iq for all devices
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v monkeyc >/dev/null 2>&1; then
    echo "monkeyc not found on PATH." >&2
    echo "Install the Connect IQ SDK and add its bin directory to PATH - see README." >&2
    exit 1
fi

scripts/dev-key.sh . >/dev/null
mkdir -p bin

if [[ "${1:-}" == "--package" ]]; then
    # -e produces the .iq bundle the store accepts, covering every product
    # listed in manifest.xml. -r optimises resources, -w shows warnings.
    echo "packaging for the store..."
    monkeyc -f monkey.jungle -o bin/watchkey.iq -y developer_key.der -e -r -w
    echo "wrote bin/watchkey.iq"
else
    DEVICE="${1:-fenix7}"
    echo "building for $DEVICE..."
    monkeyc -f monkey.jungle -o "bin/watchkey-$DEVICE.prg" -y developer_key.der -d "$DEVICE" -w
    echo "wrote bin/watchkey-$DEVICE.prg"
fi

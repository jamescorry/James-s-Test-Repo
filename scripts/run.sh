#!/usr/bin/env bash
# Build and run Watch Key in the Connect IQ simulator.
#
# Note what the simulator can and cannot show you. The UI, the state machine
# and the error paths all work. The Bluetooth link does not: there is no car
# to talk to, so scanning simply times out. Confirming that the watch actually
# unlocks a Tesla needs a physical watch and a physical car.
set -euo pipefail

cd "$(dirname "$0")/.."
DEVICE="${1:-fenix7}"

scripts/build.sh "$DEVICE"

# The simulator has to be running before monkeydo can side-load into it.
if ! pgrep -f "connectiq|simulator" >/dev/null 2>&1; then
    echo "starting simulator..."
    connectiq &
    sleep 5
fi

monkeydo "bin/watchkey-$DEVICE.prg" "$DEVICE"

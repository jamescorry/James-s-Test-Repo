#!/usr/bin/env bash
# Generate the developer key every Connect IQ build must be signed with.
#
# The key identifies you as the publisher. Keep it: the store ties an app to
# the key that signed it, and losing it means you cannot publish updates to
# the same listing. It is gitignored for that reason - never commit it.
set -euo pipefail

KEY_DIR="${1:-.}"
DER="$KEY_DIR/developer_key.der"

if [[ -f "$DER" ]]; then
    echo "developer key already exists at $DER"
    exit 0
fi

PEM="$(mktemp)"
trap 'rm -f "$PEM"' EXIT

openssl genrsa -out "$PEM" 4096 2>/dev/null
openssl pkcs8 -topk8 -inform PEM -outform DER -in "$PEM" -out "$DER" -nocrypt

echo "wrote $DER"

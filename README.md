# Watch Key

A direct Bluetooth key for Tesla vehicles, running on the watch. No phone, no
internet: the watch talks to the car's Vehicle Security (VCSEC) domain over BLE
and signs its own commands.

Lock, unlock, trunk and frunk.

## Status

**Not yet verified against a vehicle.** The protocol layer is implemented, its
byte-level logic is checked against Tesla's published test vectors, and every
source file parses. It has not been compiled with the Connect IQ SDK or run
against a real car - compiling needs device files from Garmin's authenticated
API. See [What still needs doing](#what-still-needs-doing).

## How it works

```
watch                                        car (VCSEC)
  |-- scan for local name S<sha1(VIN)[:8]>C ---->|
  |-- connect, enable notifications ------------>|
  |-- RoutableMessage{session_info_request} ---->|
  |<-- SessionInfo{publicKey, epoch, counter} ---|   authenticated with
  |                                              |   HMAC-SHA256
  |   K  = SHA1(ECDH(c, V).x)[:16]               |
  |   K' = HMAC-SHA256(K, "authenticated command")
  |                                              |
  |-- RoutableMessage{VCSEC.RKEAction, HMAC} --->|
  |<-- FromVCSECMessage{CommandStatus} ----------|
```

The design decision that makes this possible on Connect IQ is authenticating
with **HMAC-SHA256 instead of AES-GCM**. Tesla's own client uses AES-GCM over
BLE, and Connect IQ does not appear to expose a GCM cipher mode - but vehicles
accept both methods, and every primitive HMAC-SHA256 needs is native to
`Toybox.Cryptography`. See [docs/PROTOCOL-NOTES.md](docs/PROTOCOL-NOTES.md).

## Layout

| Path | Purpose |
| --- | --- |
| `source/protocol/Protobuf.mc` | Minimal proto3 wire codec |
| `source/protocol/Metadata.mc` | Tesla's metadata TLV serialisation |
| `source/protocol/CryptoUtils.mc` | Key storage, ECDH, key derivation |
| `source/protocol/UniversalMessage.mc` | `RoutableMessage` envelope |
| `source/protocol/Vcsec.mc` | VCSEC payloads and reply parsing |
| `source/protocol/Session.mc` | Handshake verification, command signing |
| `source/ble/BleTransport.mc` | Scan, connect, framing, chunked writes |
| `source/CommandManager.mc` | State machine from button press to reply |
| `source/views/` | Screens and input handling |
| `tools/verify_vectors.py` | Checks the wire logic against Tesla's vectors |

Rather than shipping generated protobuf bindings - Tesla's definitions come to
several thousand lines, which a watch cannot afford to keep resident - the
codec works directly on the wire format and messages are built field by field.

## Building

### What you need, and why it is not one download

The Connect IQ SDK is a plain unauthenticated download, listed at
`https://developer.garmin.com/downloads/connect-iq/sdks/sdks.json`. Since SDK
3.2, though, the **device files** are separate, and they come from Garmin's
authenticated API (`api.gcs.garmin.com`). So compiling for any device needs a
Garmin account, whether you use the GUI SDK Manager or automate it.

The easiest headless route is
[connect-iq-sdk-manager-cli](https://github.com/lindell/connect-iq-sdk-manager-cli):

```bash
curl -s https://raw.githubusercontent.com/lindell/connect-iq-sdk-manager-cli/master/install.sh | sh

connect-iq-sdk-manager agreement view      # read it, note the hash
connect-iq-sdk-manager agreement accept
connect-iq-sdk-manager login               # Garmin account
connect-iq-sdk-manager sdk set latest
export PATH="$(connect-iq-sdk-manager sdk current-path --bin):$PATH"
connect-iq-sdk-manager device download --manifest=manifest.xml
```

Or install the GUI SDK Manager from
[developer.garmin.com/connect-iq/sdk](https://developer.garmin.com/connect-iq/sdk/)
and add its `bin` directory to `PATH`.

### Build and run

```bash
scripts/build.sh              # .prg for fenix7
scripts/build.sh venu3        # .prg for another device
scripts/build.sh --package    # store-ready .iq for every product in the manifest
scripts/run.sh                # build, then side-load into the simulator
```

`scripts/build.sh` generates a signing key on first run if one is missing.
That key is your publisher identity - it is gitignored, and losing it means
you cannot ship updates to the same store listing.

**What the simulator can tell you:** the UI, the state machine and the error
paths. Not the Bluetooth link - there is no car to talk to, so scanning just
times out. Confirming the watch actually unlocks a Tesla needs a physical
watch and a physical car.

### Checks that need no SDK and no account

Both of these run in CI on every push, and locally:

```bash
npm install && npm run check     # parse every .mc file for syntax errors
python3 tools/verify_vectors.py  # check the wire logic against Tesla's vectors
```

The syntax check uses the open-source Monkey C parser behind
[@markw65/prettier-plugin-monkeyc](https://github.com/markw65/prettier-plugin-monkeyc).
It parses only - it will not catch type errors or unknown API calls, which
need the real compiler.

### CI

`.github/workflows/ci.yml` always runs the two checks above. It also has a
compile job that does a real `monkeyc` build, which runs only once these
repository secrets are set:

| Secret | Value |
| --- | --- |
| `GARMIN_USERNAME` | Garmin account email |
| `GARMIN_PASSWORD` | Garmin account password |
| `GARMIN_AGREEMENT_HASH` | Hash printed by `connect-iq-sdk-manager agreement view` |

Optional repository variables: `CONNECT_IQ_SDK_VERSION` (default `latest`) and
`CONNECT_IQ_DEVICE` (default `fenix7`).

## Setup on the watch

1. Enter the car's VIN in app settings, from Garmin Connect on the phone. This
   is the only step that needs a phone, and it happens once - the VIN is used
   to recognise the car's BLE advertisement and to personalise signatures. No
   network access is used at any point.
2. Open the app, press menu, and select pair.
3. Tap the key card on the centre console when the car asks.

## What still needs doing

Before this can go to the store:

- [ ] **Compile it.** Syntax is checked by the parser, but type errors and
      wrong API signatures need the real compiler. Set the Garmin secrets to
      turn on the CI compile job, or build locally.
- [ ] **Confirm the public key encoding.** Whether Connect IQ returns 65-byte
      `0x04 || X || Y` or bare 64-byte `X || Y` could not be settled from
      documentation. The code handles both, but this is the first thing to
      check against a car.
- [ ] **Verify the product list** in `manifest.xml`. Every entry must support
      BLE, and an invalid product id fails the build.
- [ ] **Test against a vehicle**, including the three-connection limit and
      behaviour when the car is asleep.
- [ ] **Memory profile.** Widgets and apps have tight budgets on older devices.
- [ ] **Replace the placeholder launcher icon.**
- [ ] **Name and branding.** Apache 2.0 grants no trademark rights, so the
      store listing cannot lean on Tesla's marks. See `NOTICE`.

## Known limitations

**Passive entry is not possible.** Connect IQ does not permit BLE in the
background, so the app must be open and on screen for the watch to talk to the
car. Every Connect IQ Tesla key has this constraint. It is the single most
important thing to be clear about in a store listing, because buyers expect
phone-key behaviour and will ask for refunds when they do not get it.

Other constraints:

- VCSEC supports three simultaneous BLE connections, shared with key fobs and
  phone keys.
- Vehicles: Model 3, Model Y, Model S (2021+), Model X (2021+), Cybertruck.
- Losing the app's stored private key means re-pairing with the key card.

## Licence

MIT. See `NOTICE` for third-party attributions.

Not affiliated with, endorsed by, or supported by Tesla, Inc. or Garmin Ltd.

# Watch Key

A direct Bluetooth key for Tesla vehicles, running on the watch. No phone, no
internet: the watch talks to the car's Vehicle Security (VCSEC) domain over BLE
and signs its own commands.

Lock, unlock, trunk and frunk.

## Status

**Runs in the simulator; not yet run against a vehicle.** The protocol layer is
implemented, its byte-level logic is checked against Tesla's published test
vectors, and it builds clean for `fenix8pro47mm` with Connect IQ SDK 9.2.0 - no
errors, no warnings.

In the simulator it launches, reads the VIN, renders, starts a BLE scan and
times out to "Car not found", which is the correct outcome with no car in
range. That exercises the state machine and the error path but not the
cryptography: scanning never derives a key. Pairing is the first action that
generates the key pair, so it is the next thing to run. Nothing has talked to a
car yet. See [What still needs doing](#what-still-needs-doing).

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

### On Windows

Use the GUI, not the CLI above. The
[SDK Manager](https://developer.garmin.com/connect-iq/sdk/) handles the Garmin
sign-in and the device downloads together, which is the awkward part.

1. Install the SDK Manager, sign in, and install an SDK plus the devices you
   target.
2. Install [VS Code](https://code.visualstudio.com/) and Garmin's **Monkey C**
   extension.
3. Command palette → **Monkey C: Generate a Developer Key**, then **Monkey C:
   Build Current Project**.

The extension does everything the scripts here do, including running the
simulator. If you would rather build from a terminal, `scripts\build.ps1` is
the PowerShell equivalent of `build.sh`:

```powershell
scripts\build.ps1                  # .prg for fenix7
scripts\build.ps1 -Device venu3    # another device
scripts\build.ps1 -Package         # store-ready .iq
```

The bash scripts also work under Git Bash. Note that
`connect-iq-sdk-manager`'s installer puts the binary in Git Bash's
`/usr/local/bin`, which is inside the Git for Windows tree and not on
cmd.exe's `PATH` - run it from Git Bash if you use it at all.

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

## Testing without a phone

The VIN is normally entered from Garmin Connect, which is awkward for a
sideloaded build and impossible in the simulator if the settings editor will
not open. Either way there is a shortcut: `Properties.getValue` returns the
default declared in `resources/settings/properties.xml`, so a VIN put there is
built into the app.

```xml
<property id="Vin" type="string">5YJ30123456789ABC</property>
```

Rebuild and the app skips straight past the "set your VIN" screen. Do not
commit a real VIN - it identifies a specific car and this repository is public.

In the simulator, the settings editor is **Settings > Trigger App Settings**.
It greys out when no app is running, so open it with the app on screen.

## Setup on the watch

1. Enter the car's VIN in app settings, from Garmin Connect on the phone. This
   is the only step that needs a phone, and it happens once - the VIN is used
   to recognise the car's BLE advertisement and to personalise signatures. No
   network access is used at any point.
2. Open the app, press menu, and select pair.
3. Tap the key card on the centre console. The car shows nothing until you
   do; once it reads the card it asks you to confirm the new key on screen.
4. The watch says "Paired", then hand-shakes. "Connected" on the main screen
   is the proof the key is on the whitelist.

## Debugging on the watch

The version shows at the bottom of the main screen, in the Pair and Log
titles, and as the first log line. Bump it in both `manifest.xml` and
`source/Version.mc` before each sideload; `npm run check` fails if the two
disagree.

There is no console, so the app keeps its own event log. From the main
screen, scroll to **Log** and press select: every BLE callback, state change,
message sent and message received is there with a timestamp, newest at the
bottom, up/down to scroll. Lines starting with `!` ended an attempt; `rx` and
`car:` lines are the car talking. The pairing screen shows the last three
lines and the byte counters (`tx`, `rx`, `msg`) live, so an attempt can be
read as it happens. **Diagnose** lists the advertisements the scan can see.

## What still needs doing

Before this can go to the store:

- [x] **Compile it.** Builds clean for `fenix8pro47mm` on SDK 9.2.0. Other
      devices in the manifest have not been built yet.
- [ ] **Confirm the public key encoding.** Whether Connect IQ returns 65-byte
      `0x04 || X || Y` or bare 64-byte `X || Y` could not be settled from
      documentation. The code handles both, but this is the first thing to
      check against a car.
- [ ] **Confirm BLE support per device.** All 14 product ids in `manifest.xml`
      are verified as real, and `fenix8pro47mm` builds - which also proves that
      device supports the BluetoothLowEnergy permission, since the compiler
      rejects a device that cannot provide one. The other 13 are unbuilt;
      `scripts/build.sh --package` covers them all at once.
- [ ] **Test against a vehicle.** Next step: pair with the key card, then
      lock/unlock. Also the three-connection limit and behaviour when the car
      is asleep.
- [ ] **Memory profile.** Widgets and apps have tight budgets on older devices.
- [ ] **Replace the placeholder launcher icon.** It is 65x65, sized for
      `fenix8pro47mm`; other devices ask for other sizes and will scale it.
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

# Watch Key

A direct Bluetooth key for Tesla vehicles, running on the watch. No phone, no
internet: the watch talks to the car's Vehicle Security (VCSEC) domain over BLE
and signs its own commands.

Lock, unlock, trunk and frunk.

## Status

**Not yet verified against a vehicle.** The protocol layer is implemented and
its byte-level logic is checked against Tesla's published test vectors, but the
app has not been compiled with the Connect IQ SDK or run against a real car.
See [What still needs doing](#what-still-needs-doing).

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

Requires the [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) and
the Monkey C extension for VS Code.

```
monkeyc -f monkey.jungle -o bin/watchkey.prg -y developer_key.der -d fenix7
```

To check the protocol logic without any of that:

```
python3 tools/verify_vectors.py
```

## Setup on the watch

1. Enter the car's VIN in app settings, from Garmin Connect on the phone. This
   is the only step that needs a phone, and it happens once - the VIN is used
   to recognise the car's BLE advertisement and to personalise signatures. No
   network access is used at any point.
2. Open the app, press menu, and select pair.
3. Tap the key card on the centre console when the car asks.

## What still needs doing

Before this can go to the store:

- [ ] **Compile it.** Written without an SDK to hand, so expect syntax and API
      fixes on the first build.
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

# Protocol notes

Working notes on implementing Tesla's BLE protocol on Connect IQ. The
authoritative reference is Tesla's
[protocol.md](https://github.com/teslamotors/vehicle-command/blob/main/pkg/protocol/protocol.md);
this file records the decisions that are specific to running it on a watch.

## Why HMAC-SHA256 rather than AES-GCM

Vehicles accept two authentication methods. Tesla's own Go client uses AES-GCM
over BLE, but AES-GCM does not appear among the cipher modes Connect IQ
exposes: Garmin's own samples use `MODE_ECB` and `MODE_CBC`, and there is no
`MODE_GCM` in the documented `Toybox.Cryptography.Cipher` surface.

HMAC-SHA256 authentication avoids the problem entirely. Commands are sent in
plaintext with an HMAC tag, and every primitive needed is native:

| Protocol requirement | Connect IQ API |
| --- | --- |
| ECDH on NIST P-256 | `Cryptography.KeyAgreement` with `KEY_AGREEMENT_ECDH` |
| `K = SHA1(Sx)[:16]` | `Cryptography.Hash` with `HASH_SHA1` |
| `K' = HMAC-SHA256(K, ...)` | `Cryptography.HashBasedMessageAuthenticationCode` |
| Random nonces | `Cryptography.randomBytes` |

The one consequence: `FLAG_ENCRYPT_RESPONSE` must stay unset. Setting it makes
firmware 2024.38+ encrypt replies with AES-GCM, which this client could not
read. Vehicles ignore the unset flag and reply in plaintext.

## Public key encoding

Tesla encodes public keys uncompressed as `0x04 || X || Y` (65 bytes). Garmin's
BluetoothMeshBarrel passes the output of `getPublicKey().getBytes()` straight
into a Bluetooth Mesh public key PDU, which carries the bare `X || Y` form (64
bytes), and feeds the same form back into `Cryptography.createPublicKey`.

`CryptoUtils.encodePublic` and `decodePublic` translate between the two, and
accept either length, so the app behaves correctly whichever representation
the SDK actually returns. This is the one interop detail that could not be
confirmed from documentation and should be checked first when bringing the app
up against a real vehicle.

## Pairing is unauthenticated

A new key cannot be signed into the whitelist, because no shared secret exists
until the vehicle already trusts the key. The pairing request is therefore sent
as an unsigned `RoutableMessage` carrying a `WhitelistOperation`, and the car
authorises it by asking for a key card tap on the centre console. VCSEC replies
`OPERATIONSTATUS_WAIT` while it waits for that tap.

## VCSEC quirks worth remembering

- **Up to three replies per request.** Only some carry a `CommandStatus`; the
  rest are progress or status updates. `Vcsec.commandStatusOf` returns null for
  those rather than treating them as completion.
- **`OPERATIONSTATUS_OK` is 0**, which proto3 omits from the wire. An absent
  field inside a present `CommandStatus` means success, not "missing".
- **`RKE_ACTION_UNLOCK` is also 0**, so it must be written unconditionally -
  hence `Protobuf.uintAlways` alongside `Protobuf.uint`.
- **Counter order matters.** VCSEC rejects out-of-order commands, unlike
  Infotainment which keeps a sliding window.
- **Three BLE connections maximum**, shared with key fobs and phone keys. A
  car with several paired phones nearby may refuse the watch.
- **Simultaneous requests are unsafe.** VCSEC is memory constrained and often
  omits `request_uuid` from replies, so this client keeps one command in flight
  at a time.

## Framing

Every BLE message is preceded by its length as two big-endian bytes. Connect IQ
writes at most 20 bytes per characteristic write and allows one outstanding
write, so `BleTransport` splits outbound messages into 20-byte chunks and sends
the next only when `onCharacteristicWrite` reports the previous one done.

## Verifying the byte-level logic

`tools/verify_vectors.py` mirrors the metadata TLV encoding, the protobuf
decoder and the key-derivation chain in Python and checks them against the test
vectors in Tesla's spec. It needs no watch, SDK or car:

```
python3 tools/verify_vectors.py
```

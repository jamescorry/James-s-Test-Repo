#!/usr/bin/env python3
"""Check the wire-format logic in source/protocol against Tesla's published
test vectors.

The Monkey C in this repo cannot be unit tested without the Connect IQ SDK and
a simulator. What *can* be checked anywhere is the byte-level logic it
implements: the metadata TLV encoding, the key derivation chain and the
protobuf codec. This script mirrors those algorithms and compares them against
the vectors in Tesla's protocol.md, so a misreading of the spec shows up here
rather than against a real car.

Vectors: https://github.com/teslamotors/vehicle-command/blob/main/pkg/protocol/protocol.md
Run: python3 tools/verify_vectors.py
"""

import hashlib
import hmac
import subprocess
import sys
import tempfile
import os

failures = []


def check(name, actual, expected):
    ok = actual == expected
    print(f"{'PASS' if ok else 'FAIL'}  {name}")
    if not ok:
        print(f"      expected {expected}")
        print(f"      actual   {actual}")
        failures.append(name)


# --- mirrors Metadata.mc ---

TAG_SIGNATURE_TYPE, TAG_DOMAIN, TAG_PERSONALIZATION = 0, 1, 2
TAG_EPOCH, TAG_EXPIRES_AT, TAG_COUNTER, TAG_CHALLENGE = 3, 4, 5, 6
TAG_END = 255

SIGNATURE_TYPE_HMAC = 6
SIGNATURE_TYPE_HMAC_PERSONALIZED = 8


def serialize_metadata(items):
    out = b""
    for tag, value in sorted(items, key=lambda item: item[0]):
        out += bytes([tag, len(value)]) + value
    return out + bytes([TAG_END])


def be32(value):
    return value.to_bytes(4, "big")


# --- mirrors Protobuf.mc decode() ---

def decode(data):
    fields, i = {}, 0
    while i < len(data):
        header, i = read_varint(data, i)
        field, wire = header >> 3, header & 0x07
        if wire == 0:
            fields[field], i = read_varint(data, i)
        elif wire == 2:
            length, i = read_varint(data, i)
            fields[field] = data[i:i + length]
            i += length
        elif wire == 5:
            fields[field] = int.from_bytes(data[i:i + 4], "little")
            i += 4
        else:
            raise ValueError(f"unsupported wire type {wire}")
    return fields


def read_varint(data, offset):
    result, shift, i = 0, 0, offset
    while True:
        b = data[i]
        result |= (b & 0x7F) << shift
        i += 1
        if not b & 0x80:
            return result, i
        shift += 7


# --- vectors ---

VIN = "5YJ30123456789ABC"
CHALLENGE = bytes.fromhex("1588d5a30eabc6f8fc9a951b11f6fd11")
SESSION_INFO = bytes.fromhex(
    "0806124104c7a1f47138486aa4729971494878d33b1a24e39571f748a6e16c5955b3"
    "d877d3a6aaa0e955166474af5d32c410f439a2234137ad1bb085fd4e8813c958f11d"
    "971a104c463f9cc0d3d26906e982ed224adde6255a0a0000"
)

CLIENT_KEY_PEM = """-----BEGIN EC PRIVATE KEY-----
MHcCAQEEICU4zcKal8GcHpmmN9bPT4yXDBGLVu3h5jI+bRYsSzDboAoGCCqGSM49
AwEHoUQDQgAEsra8aMLaBmXOZWgVWUmWxiOU7di+qQX+eBp1T+aoRacUMwkC8iXp
Jp1GbgWzSZgf2p2FzCPG+0RKpztikQXcbg==
-----END EC PRIVATE KEY-----
"""

VEHICLE_PUB_PEM = """-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEx6H0cThIaqRymXFJSHjTOxok45Vx
90im4WxZVbPYd9OmqqDpVRZkdK9dMsQQ9DmiI0E3rRuwhf1OiBPJWPEdlw==
-----END PUBLIC KEY-----
"""

print("Metadata serialisation (protocol.md 'Metadata serialization')")
check(
    "TLV example {COUNTER: 100, VIN: 'abc'}",
    serialize_metadata([
        (TAG_PERSONALIZATION, b"abc"),
        (TAG_COUNTER, be32(100)),
    ]).hex(),
    "0203616263050400000064ff",
)

handshake_metadata = serialize_metadata([
    (TAG_SIGNATURE_TYPE, bytes([SIGNATURE_TYPE_HMAC])),
    (TAG_PERSONALIZATION, VIN.encode()),
    (TAG_CHALLENGE, CHALLENGE),
])
check(
    "handshake metadata string",
    handshake_metadata.hex(),
    "000106021135594a333031323334353637383941424306101588d5a30eabc6f8fc9a951b11f6fd11ff",
)

print("\nProtobuf decoding (SessionInfo)")
session = decode(SESSION_INFO)
check("SessionInfo.counter", session[1], 6)
check("SessionInfo.epoch", session[3].hex(), "4c463f9cc0d3d26906e982ed224adde6")
check("SessionInfo.clock_time", session[4], 2650)
check(
    "SessionInfo.publicKey is an uncompressed point",
    (len(session[2]), session[2][0]),
    (65, 0x04),
)

print("\nKey derivation (ECDH -> K -> subkeys)")
with tempfile.TemporaryDirectory() as tmp:
    client = os.path.join(tmp, "client.key")
    vehicle = os.path.join(tmp, "vehicle.pem")
    open(client, "w").write(CLIENT_KEY_PEM)
    open(vehicle, "w").write(VEHICLE_PUB_PEM)
    try:
        shared = subprocess.run(
            ["openssl", "pkeyutl", "-derive", "-inkey", client, "-peerkey", vehicle],
            capture_output=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        print("SKIP  openssl unavailable, cannot derive K:", exc)
        shared = None

if shared is not None:
    # K = SHA1(BIG_ENDIAN(Sx, 32))[:16]
    k = hashlib.sha1(shared).digest()[:16]
    check("shared secret is the 32-byte x-coordinate", len(shared), 32)
    check("K", k.hex(), "1b2fce19967b79db696f909cff89ea9a")

    session_info_key = hmac.new(k, b"session info", hashlib.sha256).digest()
    check(
        "SESSION_INFO_KEY",
        session_info_key.hex(),
        "fceb679ee7bca756fcd441bf238bf2f338629b41d9eb9c67be1b32c9672ce300",
    )

    check(
        "session info tag over metadata || session_info",
        hmac.new(session_info_key, handshake_metadata + SESSION_INFO, hashlib.sha256).digest().hex(),
        "996c1fe38331be138f8039c194b14db2198846ed7d8251e6749284d7b32ea002",
    )

# --- mirrors Vcsec.addKeyRequest + presentKeyEnvelope ---
#
# No published vector exists for the pairing request, so this pins the field
# layout to vcsec.proto and to SendAddKeyRequestWithRole in Tesla's Go client,
# which sends a bare ToVCSECMessage rather than a RoutableMessage.

def varint(value):
    out = b""
    while True:
        byte = value & 0x7F
        value >>= 7
        out += bytes([byte | 0x80 if value else byte])
        if not value:
            return out


def pb_bytes(field, value):
    return varint((field << 3) | 2) + varint(len(value)) + value


def pb_uint(field, value):
    return varint((field << 3) | 0) + varint(value)


print("\nPairing request framing")
public_key = bytes([0x04]) + bytes(range(64))
permission_change = pb_bytes(1, pb_bytes(1, public_key)) + pb_uint(4, 3)          # key, ROLE_DRIVER
operation = pb_bytes(5, permission_change) + pb_bytes(6, pb_uint(1, 7))           # add+perms, ANDROID_DEVICE
unsigned = pb_bytes(16, operation)                                                 # UnsignedMessage.WhitelistOperation
envelope = pb_bytes(1, pb_bytes(2, unsigned) + pb_uint(3, 2))                      # ToVCSECMessage.signedMessage{bytes, PRESENT_KEY}

check("envelope starts with signedMessage tag", envelope[0], 0x0A)
check("signedMessage carries protobufMessageAsBytes (field 2)", envelope[2], 0x12)
check("signatureType is PRESENT_KEY (2)", envelope[-2:], bytes([0x18, 0x02]))
check("UnsignedMessage uses WhitelistOperation field 16 (two-byte tag)", unsigned[:2].hex(), "8201")
decoded = decode(envelope)
check("envelope decodes to a single field 1", sorted(decoded), [1])
inner = decode(decoded[1])
check("inner fields are 2 and 3", sorted(inner), [2, 3])
check("inner field 3 value", inner[3], 2)

# --- Connect IQ key byte order ---
#
# Garmin's BluetoothMeshBarrel (connectiq-apps, source/Tests/TestUtil.mc)
# records a private key and the public key bytes Toybox.Cryptography produced
# for it. Recomputing the point on P-256 shows those bytes are big-endian
# X || Y - the same form Tesla uses - so CryptoUtils must not reverse them.

P256_P = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff
P256_A = P256_P - 3
P256_G = (
    0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296,
    0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5,
)


def p256_add(P, Q):
    if P is None:
        return Q
    if Q is None:
        return P
    (x1, y1), (x2, y2) = P, Q
    if x1 == x2 and (y1 + y2) % P256_P == 0:
        return None
    if P == Q:
        slope = (3 * x1 * x1 + P256_A) * pow(2 * y1, P256_P - 2, P256_P) % P256_P
    else:
        slope = (y2 - y1) * pow(x2 - x1, P256_P - 2, P256_P) % P256_P
    x3 = (slope * slope - x1 - x2) % P256_P
    return (x3, (slope * (x1 - x3) - y1) % P256_P)


def p256_mul(k, P):
    R = None
    while k:
        if k & 1:
            R = p256_add(R, P)
        P = p256_add(P, P)
        k >>= 1
    return R


GARMIN_PRIVATE = bytes.fromhex("1d415f232daf511be07c885efe1bd2ade089c0fe05ff931e4ca69ef97913bab0")
GARMIN_PUBLIC = bytes.fromhex(
    "31e68e389de5ad1501d1ac531af2a715f90ec86d466d697394b05079a002f2a8"
    "15860c926436ae4f424063ef9c12c4850723b21bbd6ad74e2d53f1aa867e3abe"
)

print("\nConnect IQ public key byte order (Garmin BluetoothMeshBarrel vector)")
gx, gy = p256_mul(int.from_bytes(GARMIN_PRIVATE, "big"), P256_G)
check("Toybox.Cryptography emits big-endian X || Y",
      (gx.to_bytes(32, "big") + gy.to_bytes(32, "big")).hex(), GARMIN_PUBLIC.hex())
check("and not little-endian",
      (gx.to_bytes(32, "little") + gy.to_bytes(32, "little")) == GARMIN_PUBLIC, False)

print("\nBLE advertisement name")
digest = hashlib.sha1(b"5YJS0000000000000").digest()[:8]
check("local name for VIN 5YJS0000000000000", "S" + digest.hex() + "C", "S1a87a5a75f3df858C")

print()
if failures:
    print(f"{len(failures)} check(s) failed: {', '.join(failures)}")
    sys.exit(1)
print("All checks passed.")

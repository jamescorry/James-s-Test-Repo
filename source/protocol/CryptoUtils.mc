import Toybox.Lang;
import Toybox.Application.Storage;
import Toybox.Cryptography;

//! Key management and Tesla's key-derivation chain.
//!
//! Every primitive Tesla's protocol needs is available natively on Connect IQ,
//! provided commands are authenticated with HMAC-SHA256 rather than AES-GCM.
//! Tesla's own Go client uses AES-GCM over BLE, but vehicles accept both, and
//! HMAC-SHA256 keeps the whole client inside Toybox.Cryptography.
//!
//! The API shapes below follow Garmin's own BluetoothMeshBarrel, which performs
//! the same SECP256R1 ECDH exchange.
module CryptoUtils {
    const STORAGE_PRIVATE_KEY = "clientPrivateKey";

    //! The client key pair. Generated once on first run and then persisted -
    //! the vehicle whitelists the matching public key, so losing it means
    //! re-pairing.
    function keyPair() as Cryptography.KeyPair {
        var stored = Storage.getValue(STORAGE_PRIVATE_KEY);
        if (stored instanceof ByteArray) {
            return new Cryptography.KeyPair({
                :algorithm => Cryptography.KEY_PAIR_ELLIPTIC_CURVE_SECP256R1,
                :privateKey => stored
            });
        }
        var pair = new Cryptography.KeyPair({
            :algorithm => Cryptography.KEY_PAIR_ELLIPTIC_CURVE_SECP256R1
        });
        Storage.setValue(STORAGE_PRIVATE_KEY, pair.getPrivateKey().getBytes());
        return pair;
    }

    //! This client's public key in the form Tesla expects on the wire.
    function publicKey() as ByteArray {
        return encodePublic(keyPair().getPublicKey().getBytes());
    }

    //! Tesla encodes public keys as 0x04 || BIG_ENDIAN(X) || BIG_ENDIAN(Y).
    //! Connect IQ's Cryptography API emits the same big-endian X || Y without
    //! the prefix, so the only change at this boundary is the 0x04 byte.
    //!
    //! No byte reversal. A test vector in Garmin's own BluetoothMeshBarrel
    //! (TestUtil.mc) gives a private key and the public key bytes the API
    //! produced for it; recomputing that point on P-256 matches Garmin's
    //! bytes only when read big-endian, and the barrel puts those bytes on
    //! the wire unchanged where the Mesh spec requires big-endian. Reversing
    //! them here would make the car reject the key as an invalid point.
    //! tools/verify_vectors.py pins this.
    function encodePublic(raw as ByteArray) as ByteArray {
        if (raw.size() == 65) {
            return raw;
        }
        var out = [0x04]b;
        out.addAll(raw);
        return out;
    }

    //! The inverse: strip the uncompressed-point prefix before handing a peer
    //! key back to Connect IQ.
    function decodePublic(encoded as ByteArray) as ByteArray {
        if (encoded.size() == 65 && encoded[0] == 0x04) {
            return encoded.slice(1, null);
        }
        return encoded;
    }

    //! The shared session key: K = SHA1(BIG_ENDIAN(Sx, 32))[:16].
    //!
    //! Type checking is off for this one function because the SDK declares
    //! Cryptography.createPublicKey's first parameter as HashAlgorithm, while
    //! the value it requires is a KeyPairAlgorithm - Garmin's own
    //! BluetoothMeshBarrel passes KEY_PAIR_ELLIPTIC_CURVE_SECP256R1 here too.
    //! The call is correct; only the annotation is wrong.
    (:typecheck(false))
    function sessionKey(vehiclePublicKey as ByteArray) as ByteArray {
        var agreement = new Cryptography.KeyAgreement({
            :protocol => Cryptography.KEY_AGREEMENT_ECDH,
            :privateKey => keyPair().getPrivateKey()
        });
        agreement.addKey(Cryptography.createPublicKey(
            Cryptography.KEY_PAIR_ELLIPTIC_CURVE_SECP256R1,
            decodePublic(vehiclePublicKey)
        ));
        // generateSecret yields the shared x-coordinate big-endian, which is
        // the form Tesla hashes; Garmin's mesh barrel feeds the same bytes
        // unchanged into a spec-defined big-endian derivation.
        return sha1(agreement.generateSecret()).slice(0, 16);
    }

    //! K' = HMAC-SHA256(K, "authenticated command"), used to sign commands.
    function commandKey(k as ByteArray) as ByteArray {
        return hmacSha256(k, utf8("authenticated command"));
    }

    //! SESSION_INFO_KEY = HMAC-SHA256(K, "session info"), used to authenticate
    //! the handshake response.
    function sessionInfoKey(k as ByteArray) as ByteArray {
        return hmacSha256(k, utf8("session info"));
    }

    //! VCSEC identifies a whitelisted key by the first four bytes of the SHA1
    //! digest of its encoded public key.
    function keyId(encodedPublicKey as ByteArray) as ByteArray {
        return sha1(encodedPublicKey).slice(0, 4);
    }

    //! The BLE advertisement local name of a vehicle is "S" + the first eight
    //! bytes of SHA1(VIN), lower-case hex, + "C".
    function bleLocalName(vin as String) as String {
        var digest = sha1(utf8(vin)).slice(0, 8);
        var name = "S";
        for (var i = 0; i < digest.size(); i++) {
            name += hexByte(digest[i]);
        }
        return name + "C";
    }

    function sha1(data as ByteArray) as ByteArray {
        var hash = new Cryptography.Hash({:algorithm => Cryptography.HASH_SHA1});
        hash.update(data);
        return hash.digest();
    }

    function sha256(data as ByteArray) as ByteArray {
        var hash = new Cryptography.Hash({:algorithm => Cryptography.HASH_SHA256});
        hash.update(data);
        return hash.digest();
    }

    function hmacSha256(key as ByteArray, data as ByteArray) as ByteArray {
        var mac = new Cryptography.HashBasedMessageAuthenticationCode({
            :algorithm => Cryptography.HASH_SHA256,
            :key => key
        });
        mac.update(data);
        return mac.digest();
    }

    function randomBytes(count as Number) as ByteArray {
        return Cryptography.randomBytes(count);
    }

    //! Compare two tags without leaking where they first differ.
    function constantTimeEquals(a as ByteArray?, b as ByteArray?) as Boolean {
        if (a == null || b == null || a.size() != b.size()) {
            return false;
        }
        var difference = 0;
        for (var i = 0; i < a.size(); i++) {
            difference = difference | (a[i] ^ b[i]);
        }
        return difference == 0;
    }

    function utf8(text as String) as ByteArray {
        var out = []b;
        out.addAll(text.toUtf8Array());
        return out;
    }

    function hexByte(value as Number) as String {
        var digits = "0123456789abcdef";
        return digits.substring((value >> 4) & 0x0F, ((value >> 4) & 0x0F) + 1) +
               digits.substring(value & 0x0F, (value & 0x0F) + 1);
    }
}

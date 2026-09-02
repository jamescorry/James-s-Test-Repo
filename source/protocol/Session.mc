import Toybox.Lang;
import Toybox.Time;

//! Session state for one vehicle domain.
//!
//! A session is the shared key K plus the vehicle's notion of time (an epoch
//! id and a clock) and an anti-replay counter. VCSEC requires commands to
//! arrive in counter order and to carry an expiry expressed in the vehicle's
//! own clock, so the offset between that clock and the watch's is tracked here.
class Session {
    //! Commands expire this many seconds after they are signed. Long enough to
    //! survive a slow BLE write, short enough that the vehicle will not reject
    //! it as a replay window that is too wide.
    private const COMMAND_TTL = 10;

    private var _vin as String;
    private var _domain as Number;
    private var _key as ByteArray?;
    private var _commandKey as ByteArray?;
    private var _epoch as ByteArray = []b;
    private var _counter as Number = 0;
    private var _clockOffset as Number = 0;
    private var _established as Boolean = false;

    function initialize(vin as String, domain as Number) {
        _vin = vin;
        _domain = domain;
    }

    function isEstablished() as Boolean {
        return _established;
    }

    //! Derive K from the vehicle's public key. Done once per vehicle - the
    //! result stays valid across epochs, so only the counter and clock need
    //! refreshing after that.
    function deriveKey(vehiclePublicKey as ByteArray) as Void {
        _key = CryptoUtils.sessionKey(vehiclePublicKey);
        _commandKey = CryptoUtils.commandKey(_key);
    }

    //! Verify and absorb a session info response.
    //!
    //! The tag proves the response was not tampered with in flight; a client
    //! that skips this check can be walked into accepting an attacker's expiry
    //! window. Returns false if the response fails authentication, in which
    //! case it must be discarded.
    function absorbSessionInfo(sessionInfo as ByteArray, challenge as ByteArray, tag as ByteArray?) as Boolean {
        var fields = Protobuf.decode(sessionInfo);

        var vehiclePublicKey = fields.get(UniversalMessage.FIELD_SESSION_PUBLIC_KEY);
        if (!(vehiclePublicKey instanceof ByteArray)) {
            return false;
        }
        deriveKey(vehiclePublicKey);

        var metadata = Metadata.serialize([
            [Metadata.TAG_SIGNATURE_TYPE, Metadata.byte(UniversalMessage.SIGNATURE_TYPE_HMAC)],
            [Metadata.TAG_PERSONALIZATION, CryptoUtils.utf8(_vin)],
            [Metadata.TAG_CHALLENGE, challenge]
        ]);

        var signed = []b;
        signed.addAll(metadata);
        signed.addAll(sessionInfo);
        var expected = CryptoUtils.hmacSha256(CryptoUtils.sessionInfoKey(_key), signed);
        if (!CryptoUtils.constantTimeEquals(expected, tag)) {
            return false;
        }

        var epoch = fields.get(UniversalMessage.FIELD_SESSION_EPOCH);
        if (epoch instanceof ByteArray) {
            _epoch = epoch;
        }

        var counter = fields.get(UniversalMessage.FIELD_SESSION_COUNTER);
        _counter = (counter == null) ? 0 : counter.toNumber();

        var clockTime = fields.get(UniversalMessage.FIELD_SESSION_CLOCK_TIME);
        if (clockTime != null) {
            _clockOffset = clockTime.toNumber() - localSeconds();
        }

        _established = true;
        return true;
    }

    //! Wrap a payload in a signed RoutableMessage ready for transmission.
    function signCommand(payload as ByteArray, routingAddress as ByteArray, uuid as ByteArray) as ByteArray {
        // The counter must strictly increase within an epoch, and VCSEC
        // requires commands to arrive in order, so it advances before use.
        _counter += 1;
        var expiresAt = localSeconds() + _clockOffset + COMMAND_TTL;

        // Flags are omitted entirely when zero. FLAG_ENCRYPT_RESPONSE is
        // deliberately left unset: it would make the vehicle reply with an
        // AES-GCM encrypted payload, and this client authenticates with
        // HMAC-SHA256 precisely to stay clear of GCM.
        var metadata = Metadata.serialize([
            [Metadata.TAG_SIGNATURE_TYPE, Metadata.byte(UniversalMessage.SIGNATURE_TYPE_HMAC_PERSONALIZED)],
            [Metadata.TAG_DOMAIN, Metadata.byte(_domain)],
            [Metadata.TAG_PERSONALIZATION, CryptoUtils.utf8(_vin)],
            [Metadata.TAG_EPOCH, _epoch],
            [Metadata.TAG_EXPIRES_AT, Metadata.be32(expiresAt)],
            [Metadata.TAG_COUNTER, Metadata.be32(_counter)]
        ]);

        var signed = []b;
        signed.addAll(metadata);
        signed.addAll(payload);
        var tag = CryptoUtils.hmacSha256(_commandKey, signed);

        return UniversalMessage.signedCommand(
            _domain,
            routingAddress,
            payload,
            uuid,
            CryptoUtils.publicKey(),
            _epoch,
            _counter,
            expiresAt,
            tag
        );
    }

    //! Drop the derived timing state so the next command triggers a fresh
    //! handshake. K survives - it only depends on the two key pairs.
    function invalidate() as Void {
        _established = false;
        _epoch = null;
        _counter = 0;
    }

    private function localSeconds() as Number {
        return Time.now().value();
    }
}

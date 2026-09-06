import Toybox.Lang;

//! RoutableMessage - the envelope every message to or from the vehicle uses.
//! Field numbers come from Tesla's universal_message.proto and signatures.proto.
module UniversalMessage {
    // Domain
    const DOMAIN_BROADCAST = 0;
    const DOMAIN_VEHICLE_SECURITY = 2;
    const DOMAIN_INFOTAINMENT = 3;

    // RoutableMessage fields
    const FIELD_TO_DESTINATION = 6;
    const FIELD_FROM_DESTINATION = 7;
    const FIELD_PAYLOAD = 10;
    const FIELD_STATUS = 12;
    const FIELD_SIGNATURE_DATA = 13;
    const FIELD_SESSION_INFO_REQUEST = 14;
    const FIELD_SESSION_INFO = 15;
    const FIELD_REQUEST_UUID = 50;
    const FIELD_UUID = 51;
    const FIELD_FLAGS = 52;

    // Destination fields
    const FIELD_DOMAIN = 1;
    const FIELD_ROUTING_ADDRESS = 2;

    // MessageStatus fields
    const FIELD_OPERATION_STATUS = 1;
    const FIELD_SIGNED_MESSAGE_FAULT = 2;

    // SignatureData fields
    const FIELD_SIGNER_IDENTITY = 1;
    const FIELD_SESSION_INFO_TAG = 6;
    const FIELD_HMAC_PERSONALIZED_DATA = 8;

    // HMAC_Personalized_Signature_Data fields
    const FIELD_HMAC_EPOCH = 1;
    const FIELD_HMAC_COUNTER = 2;
    const FIELD_HMAC_EXPIRES_AT = 3;
    const FIELD_HMAC_TAG = 4;

    // SessionInfo fields
    const FIELD_SESSION_COUNTER = 1;
    const FIELD_SESSION_PUBLIC_KEY = 2;
    const FIELD_SESSION_EPOCH = 3;
    const FIELD_SESSION_CLOCK_TIME = 4;
    const FIELD_SESSION_STATUS = 5;

    const SIGNATURE_TYPE_HMAC = 6;
    const SIGNATURE_TYPE_HMAC_PERSONALIZED = 8;

    const OPERATIONSTATUS_OK = 0;
    const OPERATIONSTATUS_WAIT = 1;
    const OPERATIONSTATUS_ERROR = 2;

    //! A Destination addressing a vehicle subsystem.
    function domainDestination(domain as Number) as ByteArray {
        // DOMAIN_BROADCAST is 0 but is never a command target, so the
        // default-value omission in Protobuf.uint is harmless here.
        return Protobuf.uint(FIELD_DOMAIN, domain);
    }

    //! A Destination identifying this client for the duration of a connection.
    function addressDestination(routingAddress as ByteArray) as ByteArray {
        return Protobuf.bytes(FIELD_ROUTING_ADDRESS, routingAddress);
    }

    //! The handshake request: asks a domain for its session state and public key.
    function sessionInfoRequest(
        domain as Number,
        routingAddress as ByteArray,
        publicKey as ByteArray,
        uuid as ByteArray
    ) as ByteArray {
        var request = Protobuf.bytes(1, publicKey);

        var message = []b;
        message.addAll(Protobuf.bytes(FIELD_TO_DESTINATION, domainDestination(domain)));
        message.addAll(Protobuf.bytes(FIELD_FROM_DESTINATION, addressDestination(routingAddress)));
        message.addAll(Protobuf.bytes(FIELD_SESSION_INFO_REQUEST, request));
        message.addAll(Protobuf.bytes(FIELD_UUID, uuid));
        return message;
    }

    //! An unauthenticated command. Only the initial pairing request may be sent
    //! this way - everything else the vehicle will reject without a signature.
    function unsignedCommand(
        domain as Number,
        routingAddress as ByteArray,
        payload as ByteArray,
        uuid as ByteArray
    ) as ByteArray {
        var message = []b;
        message.addAll(Protobuf.bytes(FIELD_TO_DESTINATION, domainDestination(domain)));
        message.addAll(Protobuf.bytes(FIELD_FROM_DESTINATION, addressDestination(routingAddress)));
        message.addAll(Protobuf.bytes(FIELD_PAYLOAD, payload));
        message.addAll(Protobuf.bytes(FIELD_UUID, uuid));
        return message;
    }

    //! A command carrying HMAC-SHA256 personalised authentication. The payload
    //! travels in plaintext; the tag binds it to the metadata in `signature`.
    function signedCommand(
        domain as Number,
        routingAddress as ByteArray,
        payload as ByteArray,
        uuid as ByteArray,
        publicKey as ByteArray,
        epoch as ByteArray,
        counter as Number,
        expiresAt as Number,
        tag as ByteArray
    ) as ByteArray {
        var hmacData = []b;
        hmacData.addAll(Protobuf.bytes(FIELD_HMAC_EPOCH, epoch));
        hmacData.addAll(Protobuf.uint(FIELD_HMAC_COUNTER, counter));
        hmacData.addAll(Protobuf.fixed32(FIELD_HMAC_EXPIRES_AT, expiresAt));
        hmacData.addAll(Protobuf.bytes(FIELD_HMAC_TAG, tag));

        var identity = Protobuf.bytes(1, publicKey);

        var signatureData = []b;
        signatureData.addAll(Protobuf.bytes(FIELD_SIGNER_IDENTITY, identity));
        signatureData.addAll(Protobuf.bytes(FIELD_HMAC_PERSONALIZED_DATA, hmacData));

        var message = []b;
        message.addAll(Protobuf.bytes(FIELD_TO_DESTINATION, domainDestination(domain)));
        message.addAll(Protobuf.bytes(FIELD_FROM_DESTINATION, addressDestination(routingAddress)));
        message.addAll(Protobuf.bytes(FIELD_PAYLOAD, payload));
        message.addAll(Protobuf.bytes(FIELD_SIGNATURE_DATA, signatureData));
        message.addAll(Protobuf.bytes(FIELD_UUID, uuid));
        return message;
    }

    //! The protocol-layer fault code from a response, or 0 when the vehicle
    //! reported no error.
    function faultOf(message as Dictionary) as Number {
        var status = Protobuf.submessage(message, FIELD_STATUS);
        return Protobuf.numberOf(status, FIELD_SIGNED_MESSAGE_FAULT, 0);
    }

    //! Human-readable text for the fault codes a key app can actually hit.
    function faultText(fault as Number) as String {
        if (fault == 3) {
            return "Key not paired";
        } else if (fault == 4) {
            return "Key disabled";
        } else if (fault == 5 || fault == 6 || fault == 15 || fault == 26) {
            return "Session expired";
        } else if (fault == 7) {
            return "Not permitted";
        } else if (fault == 12) {
            return "Wrong vehicle";
        } else if (fault == 17) {
            return "Command expired";
        } else if (fault == 1 || fault == 2 || fault == 11) {
            return "Car busy";
        }
        return "Error " + fault.toString();
    }

    //! True when the fault means the cached session is stale and the client
    //! should hand-shake again rather than give up.
    function faultNeedsNewSession(fault as Number) as Boolean {
        return fault == 5 || fault == 6 || fault == 15 || fault == 17 || fault == 26;
    }
}

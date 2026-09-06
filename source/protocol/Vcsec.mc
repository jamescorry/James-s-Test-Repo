import Toybox.Lang;

//! VCSEC payloads - the vehicle security domain that owns locks, closures and
//! the key whitelist. Field numbers come from Tesla's vcsec.proto.
//!
//! VCSEC is reachable over BLE even when the infotainment computer is asleep,
//! which is what makes a watch key practical.
module Vcsec {
    // ToVCSECMessage / SignedMessage fields. This is the framing that predates
    // RoutableMessage, and the whitelist request still uses it.
    const FIELD_SIGNED_MESSAGE = 1;
    const FIELD_PROTOBUF_MESSAGE_AS_BYTES = 2;
    const FIELD_SIGNATURE_TYPE = 3;
    const SIGNATURE_TYPE_PRESENT_KEY = 2;

    // UnsignedMessage fields
    const FIELD_INFORMATION_REQUEST = 1;
    const FIELD_RKE_ACTION = 2;
    const FIELD_CLOSURE_MOVE_REQUEST = 4;
    const FIELD_WHITELIST_OPERATION = 16;

    // RKEAction_E
    const RKE_ACTION_UNLOCK = 0;
    const RKE_ACTION_LOCK = 1;
    const RKE_ACTION_WAKE_VEHICLE = 30;

    // ClosureMoveType_E
    const CLOSURE_MOVE_TYPE_NONE = 0;
    const CLOSURE_MOVE_TYPE_MOVE = 1;
    const CLOSURE_MOVE_TYPE_OPEN = 3;

    // ClosureMoveRequest fields
    const FIELD_REAR_TRUNK = 5;
    const FIELD_FRONT_TRUNK = 6;

    // InformationRequestType
    const INFORMATION_REQUEST_TYPE_GET_STATUS = 0;

    // WhitelistOperation fields
    const FIELD_ADD_KEY_AND_PERMISSIONS = 5;
    const FIELD_METADATA_FOR_KEY = 6;

    // PermissionChange fields
    const FIELD_PERMISSION_KEY = 1;
    const FIELD_PERMISSION_ROLE = 4;

    // Keys.Role
    const ROLE_OWNER = 2;
    const ROLE_DRIVER = 3;

    // KeyMetadata / KeyFormFactor. There is no watch form factor in the enum;
    // Tesla's own client uses the Android value for generic clients.
    const FIELD_KEY_FORM_FACTOR = 1;
    const KEY_FORM_FACTOR_ANDROID_DEVICE = 7;

    // FromVCSECMessage fields
    const FIELD_VEHICLE_STATUS = 1;
    const FIELD_COMMAND_STATUS = 4;

    // VehicleStatus fields
    const FIELD_CLOSURE_STATUSES = 1;
    const FIELD_VEHICLE_LOCK_STATE = 2;

    // CommandStatus fields
    const FIELD_OPERATION_STATUS = 1;
    const FIELD_WHITELIST_OPERATION_STATUS = 3;

    // WhitelistOperation_status fields
    const FIELD_WHITELIST_INFORMATION = 1;

    // OperationStatus_E
    const OPERATIONSTATUS_OK = 0;
    const OPERATIONSTATUS_WAIT = 1;
    const OPERATIONSTATUS_ERROR = 2;

    // VehicleLockState_E
    const VEHICLELOCKSTATE_UNLOCKED = 0;
    const VEHICLELOCKSTATE_LOCKED = 1;

    //! Lock or unlock the car.
    function rkeAction(action as Number) as ByteArray {
        // RKE_ACTION_UNLOCK is 0, which proto3 would normally omit, so this
        // field must be written unconditionally.
        return Protobuf.uintAlways(FIELD_RKE_ACTION, action);
    }

    //! Open the rear trunk.
    function openTrunk() as ByteArray {
        var request = Protobuf.uintAlways(FIELD_REAR_TRUNK, CLOSURE_MOVE_TYPE_OPEN);
        return Protobuf.bytes(FIELD_CLOSURE_MOVE_REQUEST, request);
    }

    //! Open the front trunk. The frunk has no powered close, so OPEN is the
    //! only meaningful move.
    function openFrunk() as ByteArray {
        var request = Protobuf.uintAlways(FIELD_FRONT_TRUNK, CLOSURE_MOVE_TYPE_OPEN);
        return Protobuf.bytes(FIELD_CLOSURE_MOVE_REQUEST, request);
    }

    //! Ask VCSEC for the current lock and closure state.
    function statusRequest() as ByteArray {
        var request = Protobuf.uintAlways(1, INFORMATION_REQUEST_TYPE_GET_STATUS);
        return Protobuf.bytes(FIELD_INFORMATION_REQUEST, request);
    }

    //! Request that this watch's public key be added to the vehicle whitelist.
    //!
    //! The car authorises it with a key card tap on the centre console, which
    //! is the only trust anchor available before a shared secret exists. Wrap
    //! the result in presentKeyEnvelope before sending.
    function addKeyRequest(publicKey as ByteArray, role as Number) as ByteArray {
        var key = Protobuf.bytes(1, publicKey);

        var permissionChange = []b;
        permissionChange.addAll(Protobuf.bytes(FIELD_PERMISSION_KEY, key));
        permissionChange.addAll(Protobuf.uint(FIELD_PERMISSION_ROLE, role));

        var metadata = Protobuf.uint(FIELD_KEY_FORM_FACTOR, KEY_FORM_FACTOR_ANDROID_DEVICE);

        var operation = []b;
        operation.addAll(Protobuf.bytes(FIELD_ADD_KEY_AND_PERMISSIONS, permissionChange));
        operation.addAll(Protobuf.bytes(FIELD_METADATA_FOR_KEY, metadata));

        return Protobuf.bytes(FIELD_WHITELIST_OPERATION, operation);
    }

    //! Wrap an UnsignedMessage in a ToVCSECMessage claiming key-card presence.
    //!
    //! Tesla's reference client sends the whitelist request this way - as a
    //! bare ToVCSECMessage written straight to the characteristic, not inside
    //! a RoutableMessage. The car ignores the request in any other framing,
    //! and its replies to this one come back as bare FromVCSECMessages.
    function presentKeyEnvelope(unsigned as ByteArray) as ByteArray {
        var signed = []b;
        signed.addAll(Protobuf.bytes(FIELD_PROTOBUF_MESSAGE_AS_BYTES, unsigned));
        signed.addAll(Protobuf.uint(FIELD_SIGNATURE_TYPE, SIGNATURE_TYPE_PRESENT_KEY));
        return Protobuf.bytes(FIELD_SIGNED_MESSAGE, signed);
    }

    //! The whitelist-specific reason code in a command status, or 0 when the
    //! car gave none. Non-zero explains why a pairing was refused.
    function whitelistInformationOf(payload as ByteArray) as Number {
        var message = Protobuf.decode(payload);
        var status = Protobuf.submessage(message, FIELD_COMMAND_STATUS);
        var whitelist = Protobuf.submessage(status, FIELD_WHITELIST_OPERATION_STATUS);
        return Protobuf.numberOf(whitelist, FIELD_WHITELIST_INFORMATION, 0);
    }

    //! Short text for the whitelist reason codes a watch can plausibly hit.
    function whitelistInformationText(code as Number) as String {
        if (code == 3 || code == 4) {
            return "Key list full";
        } else if (code == 5 || code == 8) {
            return "Not permitted";
        } else if (code == 6) {
            return "Bad key";
        } else if (code == 13) {
            return "Already paired";
        } else if (code == 14) {
            return "Tap card first";
        } else if (code == 19 || code == 20) {
            return "Bad role";
        }
        return "Pair error " + code.toString();
    }

    //! Pull the lock state out of a FromVCSECMessage, or null if the message
    //! carries something else. VCSEC emits up to three replies per request, so
    //! most of them will not be a status.
    function lockStateOf(payload as ByteArray) as Number? {
        var message = Protobuf.decode(payload);
        if (!message.hasKey(FIELD_VEHICLE_STATUS)) {
            return null;
        }
        // VEHICLELOCKSTATE_UNLOCKED is 0, which proto3 omits, so an absent
        // field inside a present VehicleStatus means unlocked - not missing.
        var status = Protobuf.submessage(message, FIELD_VEHICLE_STATUS);
        return Protobuf.numberOf(status, FIELD_VEHICLE_LOCK_STATE, VEHICLELOCKSTATE_UNLOCKED);
    }

    //! The operationStatus of a command reply, or null when the message is not
    //! a command status. VCSEC emits up to three replies per request, so most
    //! of them are not. OPERATIONSTATUS_WAIT means VCSEC is busy and the client
    //! should retry shortly.
    //!
    //! OPERATIONSTATUS_OK is 0, which proto3 omits from the wire, so an absent
    //! field inside a present CommandStatus means success.
    function commandStatusOf(payload as ByteArray) as Number? {
        var message = Protobuf.decode(payload);
        if (!message.hasKey(FIELD_COMMAND_STATUS)) {
            return null;
        }
        var status = Protobuf.submessage(message, FIELD_COMMAND_STATUS);
        return Protobuf.numberOf(status, FIELD_OPERATION_STATUS, OPERATIONSTATUS_OK);
    }
}

import Toybox.Lang;

//! VCSEC payloads - the vehicle security domain that owns locks, closures and
//! the key whitelist. Field numbers come from Tesla's vcsec.proto.
//!
//! VCSEC is reachable over BLE even when the infotainment computer is asleep,
//! which is what makes a watch key practical.
module Vcsec {
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
    //! Sent unsigned: the car authorises it by asking for a key card tap on the
    //! centre console, which is the only trust anchor available before a shared
    //! secret exists.
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

    //! Pull the lock state out of a FromVCSECMessage, or null if the message
    //! carries something else. VCSEC emits up to three replies per request, so
    //! most of them will not be a status.
    function lockStateOf(payload as ByteArray) as Number? {
        var message = Protobuf.decode(payload);
        var status = Protobuf.submessage(message, FIELD_VEHICLE_STATUS);
        var lockState = status.get(FIELD_VEHICLE_LOCK_STATE);
        if (lockState == null) {
            return null;
        }
        return lockState.toNumber();
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
        var operationStatus = status.get(FIELD_OPERATION_STATUS);
        if (operationStatus == null) {
            return OPERATIONSTATUS_OK;
        }
        return operationStatus.toNumber();
    }
}
